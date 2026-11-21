# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifyWrites do
  @moduledoc """
  Every `write` names a real source update that really makes the change.

  One write is one source action, and the declaration is checked against that
  action rather than trusted:

    * `via:` names an update action of the source — a missing action is
      refused naming both, and a non-update is refused: a facade write is an
      update of one existing row, never a create or a destroy;
    * the write names at least one of `sets:` and `accepts:` — a write that
      would run a source action to change nothing is a bug waiting to run;
    * `sets:` and `accepts:` name facade attributes whose lens has a reverse;
      a read-only lens is refused with its `because:` text, the same text the
      runtime will quote;
    * every `sets:` value is put through the lens at compile time, and the
      source action must really set that source attribute to that value — via
      `Ash.Resource.Change.SetAttribute`, or a state machine's
      `transition_state` (which sets the machine's state attribute to its
      target), possibly wrapped by `AshEvents.Events.ReplayChangeWrapper` when
      the source carries events;
    * every `accepts:` attribute's source column must reach the action as an
      input — in its `accept`, or as an argument the action copies into that
      column with `set_attribute(column, arg(name))` — so the write is refused
      before it can silently do nothing.

  The facade's primary key is exactly one attribute, since the generated
  action takes it as one `id` argument.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Eval, Facade.Info}
  alias Spark.Dsl.Verifier

  # Matched as an atom rather than a module reference: ash_state_machine is not
  # a dependency of this package, and matching a name is not a dependency on it.
  @transition_state :"Elixir.AshStateMachine.BuiltinChanges.TransitionState"

  @impl true
  def verify(dsl) do
    facade = Verifier.get_persisted(dsl, :module)
    source = Info.source(dsl)
    lenses = safe_lenses(dsl)

    primary_key =
      facade
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)

    cond do
      lenses == :unbuilt ->
        # VerifySource refuses the lens first.
        :ok

      length(primary_key) != 1 ->
        {:error,
         Spark.Error.DslError.exception(
           module: facade,
           path: [:facade],
           message:
             "A facade's primary key is one attribute, because each `write` takes it as " <>
               "one `id` argument. Declared: #{inspect(primary_key)}."
         )}

      true ->
        dsl
        |> Info.writes()
        |> Enum.flat_map(&problems(&1, source, lenses))
        |> case do
          [] ->
            :ok

          problems ->
            {:error,
             Spark.Error.DslError.exception(
               module: facade,
               path: [:facade],
               message:
                 "The facade's writes do not agree with their source actions.\n\n" <>
                   Enum.map_join(problems, "\n", &"  * #{&1}")
             )}
        end
    end
  end

  defp safe_lenses(dsl) do
    Info.lenses(dsl)
  rescue
    ArgumentError -> :unbuilt
  end

  defp problems(write, source, lenses) do
    action = Ash.Resource.Info.action(source, write.via)

    Enum.concat([
      via_problems(action, write, source),
      empty_problems(write),
      lens_problems(write, lenses),
      sets_problems(write, action, source, lenses),
      accepts_problems(write, action, source, lenses)
    ])
  end

  defp via_problems(nil, write, source) do
    [
      "`via: #{inspect(write.via)}` names no action of #{inspect(source)}. One write is " <>
        "one source action, so the action has to exist."
    ]
  end

  defp via_problems(%{type: :update}, _write, _source), do: []

  defp via_problems(action, write, source) do
    [
      "`via: #{inspect(write.via)}` on #{inspect(source)} is a #{action.type} action. A " <>
        "facade write updates one row of the source, so `via:` names an update action."
    ]
  end

  defp empty_problems(write) do
    if write.sets == [] and write.accepts == [] do
      [
        "`write #{inspect(write.name)}` names no `sets:` and no `accepts:`. It would run a " <>
          "source action to change nothing. Name what it writes."
      ]
    else
      []
    end
  end

  defp lens_problems(write, lenses) do
    Enum.flat_map(write.sets ++ Enum.map(write.accepts, &{&1, nil}), fn {attribute, _} ->
      case Map.get(lenses, attribute) do
        nil ->
          [
            "`write #{inspect(write.name)}` names #{inspect(attribute)}, which no lens " <>
              "produces."
          ]

        lens when lens.writes == [] ->
          [
            "`write #{inspect(write.name)}` writes through #{inspect(attribute)}, whose " <>
              "lens is read-only. #{lens.because || "The lens declares no reverse."}"
          ]

        _lens ->
          []
      end
    end)
  end

  defp sets_problems(_write, action, _source, _lenses)
       when not is_struct(action) or action.type != :update,
       do: []

  defp sets_problems(write, action, source, lenses) do
    Enum.flat_map(write.sets, fn {attribute, value} ->
      lens = Map.fetch!(lenses, attribute)

      case Eval.put(lens, %{attribute => value}) do
        {:error, {:read_only, because}} ->
          [
            "`sets: [#{inspect(attribute)}: #{inspect(value)}]` cannot be put through the " <>
              "lens. #{because || "The lens declares no reverse."}"
          ]

        {:ok, columns_and_values} ->
          for {column, column_value} <- columns_and_values,
              !sets?(action, source, column, column_value) do
            "`via: #{inspect(action.name)}` does not set #{inspect(column)} to " <>
              "#{inspect(column_value)} (from `sets: [#{inspect(attribute)}: " <>
              "#{inspect(value)}]`). It sets: #{inspect(action_sets(action, source))}. A write's " <>
              "declaration must be what the source action actually does."
          end
      end
    end)
  end

  defp accepts_problems(_write, action, _source, _lenses)
       when not is_struct(action) or action.type != :update,
       do: []

  defp accepts_problems(write, action, source, lenses) do
    accept = action_accept(action, source)

    Enum.flat_map(write.accepts, fn attribute ->
      lens = Map.fetch!(lenses, attribute)
      columns = Enum.map(lens.writes, &elem(&1, 0))

      for column <- columns, !input?(action, accept, column) do
        "`accepts: [#{inspect(attribute)}]` writes #{inspect(column)}, which " <>
          "`via: #{inspect(action.name)}` neither accepts (it accepts #{inspect(accept)}) " <>
          "nor copies from an argument with `set_attribute(#{inspect(column)}, arg(...))`. " <>
          "The source would drop the value and report success."
      end
    end)
  end

  defp input?(action, accept, column),
    do: column in accept or Info.argument_for(action, column) != nil

  # What the source action sets, as {attribute, value} pairs: its
  # `set_attribute` changes (`Info.set_attributes/1`) and a state machine's
  # `transition_state`, whose target is the machine's state attribute's value.
  defp action_sets(action, source) do
    Info.set_attributes(action) ++
      for {@transition_state, opts} <- Info.changes(action),
          is_list(opts),
          target = opts[:target],
          is_atom(target) and not is_nil(target) do
        {state_attribute(source), target}
      end
  end

  # The machine's state attribute: its `state_machine` option, `:state` unless
  # the source says otherwise.
  defp state_attribute(source),
    do: Spark.Dsl.Extension.get_opt(source, [:state_machine], :state_attribute, :state)

  defp sets?(action, source, column, value) do
    {column, value} in action_sets(action, source)
  end

  # An action with no declared `accept` takes every writable attribute.
  defp action_accept(action, source) do
    action.accept ||
      source
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.writable?)
      |> Enum.map(& &1.name)
  end
end
