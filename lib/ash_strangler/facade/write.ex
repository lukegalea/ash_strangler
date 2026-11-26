# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Write do
  @moduledoc """
  The implementation behind each facade `write`: one generic action that runs
  ONE named source action, as the caller.

  The order is deliberate, and the checks before the source action are not
  conveniences:

  0. A source with a tenant strategy refuses a write that carries no tenant.
  1. `as_of` on a facade write is refused **before anything runs**. A facade
     write takes effect now; there is no version of "change the past through
     this vocabulary" (ADR 0083 decision 5; ADR 0049 invariant 7).
  2. The source row is read as the caller, by primary key. No row, no write:
     a row the caller cannot read is a row that is not there.
  3. The source action's input is put through the lens's reverse direction —
     for `sets:` the declared value, for `accepts:` the argument. A lens with
     no reverse refuses with its `because:` text, before the source action.
     Only the `accepts:` arguments the caller supplied are sent: one omitted
     is not sent at all, and the column it feeds keeps its stored value,
     while an argument supplied as `nil` is written as a `nil`. The write is
     an update of the row step 2 read, so the reverse sees that row as
     `:prior`: a collapse state whose `set:` omits a column holds the
     column's stored value, and falls back only where there is no row.
  4. The source update action runs with the source row, that input, and the
     caller's `actor`, `tenant` and `authorize?`. The source's own validation
     and guard errors are returned as the source raised them — a facade is not
     a place where a rule is restated.
  5. The updated source row goes back through the forward lens, exactly as a
     read does: the same mapping (`AshStrangler.Facade.Record`), with the
     source calculations and aggregates the lenses read loaded first. No
     second source action runs to produce the return value.
  """

  use Ash.Resource.Actions.Implementation

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Query.NotFound
  alias AshStrangler.{Eval, Facade.Info, Facade.Record}

  @impl true
  def run(input, _opts, context) do
    if input.as_of do
      {:error,
       InvalidAttribute.exception(
         field: :as_of,
         message:
           "a facade write takes effect now: `as_of` is refused, never forwarded and never " <>
             "dropped. Write the change as of now, or read as of the past."
       )}
    else
      facade = input.resource
      source = Info.source(facade)
      lenses = Info.lenses(facade)

      with :ok <- tenant_required(facade, source, context),
           {:ok, source_row} <- source_row(facade, source, input, context),
           {:ok, source_input} <- source_input(facade, source, input, source_row) do
        source_row
        |> Ash.Changeset.for_update(via(input), source_input, source_opts(context))
        # The record the write returns is the one a read returns, so the
        # update loads the same source calculations and aggregates the lenses
        # read (`AshStrangler.Facade.Record`).
        |> Ash.Changeset.load(Record.load_fields(lenses, source))
        |> Ash.update()
        |> case do
          {:ok, updated} -> {:ok, Record.record(updated, facade, lenses, source)}
          {:error, error} -> {:error, error}
        end
      end
    end
  end

  # A `global? true` attribute-tenant source reads and updates with no tenant;
  # a facade write is refused without one, as its read is, so a caller with no
  # tenant never reaches a row across tenants.
  defp tenant_required(facade, source, context) do
    if Ash.Resource.Info.multitenancy_strategy(source) && is_nil(context.tenant) do
      {:error, Ash.Error.Invalid.TenantRequired.exception(resource: facade)}
    else
      :ok
    end
  end

  # The caller's options, mirrored — see `AshStrangler.Facade.Read`: passing
  # `actor:` even as nil turns authorization on.
  defp source_opts(context) do
    authorize? = context.authorize?

    [tenant: context.tenant] ++
      if(authorize? != nil || context.actor, do: [actor: context.actor], else: []) ++
      if(authorize? != nil, do: [authorize?: authorize?], else: [])
  end

  defp via(input) do
    input.resource
    |> Info.writes()
    |> Enum.find(&(&1.name == input.action.name))
    |> Map.fetch!(:via)
  end

  # The row is found through the primary key lens's reverse direction: the
  # facade's id is a value in the facade's vocabulary, and the source row is
  # named in the source's.
  defp source_row(facade, source, input, context) do
    primary_key = Ash.Resource.Info.primary_key(facade)
    lens = Info.lenses(facade) |> Map.fetch!(hd(primary_key))

    with {:ok, columns_and_values} <-
           Eval.put(lens, %{lens.attribute => input.arguments[hd(primary_key)]}) do
      source
      |> Ash.Query.for_read(Info.read_action(facade), %{}, source_opts(context))
      |> Ash.Query.do_filter(Map.new(columns_and_values))
      |> load_fields(facade, source)
      |> Ash.read(source_opts(context))
      |> case do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:error, NotFound.exception(resource: facade, primary_key: nil)}
        {:error, error} -> {:error, error}
      end
    end
  end

  # The prior the lens's reverse reads is built from this row, so the row
  # carries the same source calculations and aggregates a read loads.
  defp load_fields(query, facade, source) do
    Enum.reduce(Record.load_fields(Info.lenses(facade), source), query, &Ash.Query.load(&2, &1))
  end

  defp source_input(facade, source, input, source_row) do
    write =
      facade
      |> Info.writes()
      |> Enum.find(&(&1.name == input.action.name))

    lenses = Info.lenses(facade)

    accepted = accepted_input(write, input)

    action = Ash.Resource.Info.action(source, write.via)

    with {:ok, accepted} <- through_lens(accepted, lenses, prior(source_row, facade, lenses)) do
      {:ok, Map.new(accepted, fn {column, value} -> {input_name(action, column), value} end)}
    end
  end

  # The write is an update of a row the facade has just read as the caller, so
  # the lens's reverse sees that row as `:prior`: a column a state's `set:`
  # omits holds its stored value (`strangler_hold`) instead of falling back as
  # on an insert, and a `touch()` compares against what the caller wrote.
  defp prior(source_row, facade, lenses) do
    values = Map.from_struct(source_row)
    %{attributes: Record.facade_values(values, facade, lenses), columns: values}
  end

  # A column the action takes as an argument (`set_attribute(column, arg(name))`)
  # is written through that argument; any other is an accepted attribute.
  defp input_name(action, column), do: Info.argument_for(action, column) || column

  # Only the accepted attributes the caller supplied are written: an argument
  # the caller omitted is not sent to the source action at all, so the column
  # it feeds keeps its stored value. Ash leaves an unsupplied argument out of
  # `input.arguments` and keeps one supplied as `nil` in it, so an explicit
  # `nil` is still written as a `nil`.
  defp accepted_input(write, input) do
    write.accepts
    |> Enum.filter(&Map.has_key?(input.arguments, &1))
    |> Enum.map(fn attribute -> {attribute, input.arguments[attribute]} end)
  end

  # One facade attribute and value → the source columns the lens's reverse
  # writes. A read-only lens is refused here with its declared reason, before
  # the source action runs; `VerifyWrites` refuses the declaration at compile
  # time with the same text. `sets:` values are deliberately NOT part of this
  # input: the source action's own change makes the change, after its guards
  # have seen the row as it is — a facade that pre-wrote the value would be
  # telling the source what its guard is allowed to see.
  defp through_lens(entries, lenses, prior) do
    Enum.reduce_while(entries, {:ok, []}, fn {attribute, value}, {:ok, acc} ->
      case Eval.put(Map.fetch!(lenses, attribute), %{attribute => value}, prior: prior) do
        {:ok, columns_and_values} ->
          {:cont, {:ok, acc ++ columns_and_values}}

        {:error, {:read_only, because}} ->
          {:halt,
           {:error,
            InvalidAttribute.exception(
              field: attribute,
              message: because || "#{inspect(attribute)} has no reverse to write through."
            )}}
      end
    end)
  end
end
