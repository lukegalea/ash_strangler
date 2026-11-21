# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Transformers.AddReadAndWrites do
  @moduledoc """
  Adds the actions a facade needs and may not write by hand.

  A manual read `:read`, primary, running `AshStrangler.Facade.Read` — the one
  read action a facade is allowed to declare — when the facade declares none.
  And one generic action per `write`, taking the facade primary key plus one
  argument per accepted attribute, returning the facade record. The generic
  actions are declared here rather than left to the user because they are
  derived from the `write` entities, like everything else on a facade: nothing
  is kept in sync by hand.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Actions.{Action, Argument}
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    facade = Transformer.get_persisted(dsl, :module)

    dsl =
      if any_read?(dsl) do
        dsl
      else
        Transformer.add_entity(dsl, [:actions], read_action(), type: :append)
      end

    AshStrangler.Facade.Info.writes(dsl)
    |> Enum.reduce(dsl, fn write, dsl ->
      Transformer.add_entity(dsl, [:actions], generic_action(write, facade, dsl), type: :append)
    end)
    |> then(&{:ok, &1})
  end

  # Any read at all suppresses the generated one; `VerifyOwnShape` refuses a
  # read that is not the facade's manual read, so the only way through is to
  # declare it with `manual AshStrangler.Facade.Read` yourself.
  defp any_read?(dsl) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.any?(&(&1.type == :read))
  end

  defp read_action do
    %Ash.Resource.Actions.Read{
      name: :read,
      primary?: true,
      # A tuple, as the DSL's own `manual` transform normalises to.
      manual: {AshStrangler.Facade.Read, []},
      # The DSL's own default: the facade has no multitenancy of its own, but
      # an unset value breaks Ash's multitenancy dispatch.
      multitenancy: :enforce,
      # Offset pagination only: a manual read hands rows back, and Ash reports
      # no count for one. Keyset cursors are not translated, so they are not
      # offered here either.
      pagination: %Ash.Resource.Actions.Read.Pagination{
        offset?: true,
        keyset?: false,
        countable: false
      }
    }
  end

  defp generic_action(write, facade, dsl) do
    %Action{
      name: write.name,
      returns: Ash.Type.Struct,
      constraints: [instance_of: facade],
      run: {AshStrangler.Facade.Write, []},
      arguments: arguments(write, dsl)
    }
  end

  # The `id` argument is the facade primary key — a facade with a composite key
  # is refused by `VerifyWrites`, so there is exactly one — and one argument per
  # `accepts:` attribute, typed as that attribute is. A facade with no primary
  # key gets no arguments and lets the verifier name the problem, rather than
  # crashing here with an argument the declaration cannot read. Everything is
  # read off the `dsl` state, never off the half-compiled module: the module's
  # config is exactly what this transformer is in the middle of writing.
  defp arguments(write, dsl) do
    attributes =
      dsl
      |> Ash.Resource.Info.attributes()
      |> Map.new(&{&1.name, &1})

    primary_key =
      attributes
      |> Map.values()
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)

    id_argument(attributes, primary_key) ++
      Enum.map(write.accepts, fn name ->
        attribute = Map.fetch!(attributes, name)

        %Argument{
          name: attribute.name,
          type: attribute.type,
          constraints: attribute.constraints,
          allow_nil?: attribute.allow_nil?,
          sensitive?: attribute.sensitive?
        }
      end)
  end

  defp id_argument(_attributes, []), do: []

  defp id_argument(attributes, [attribute_name]) do
    attribute = Map.fetch!(attributes, attribute_name)

    [%Argument{name: attribute.name, type: attribute.type, allow_nil?: false}]
  end

  # A composite primary key is refused later; taking the first attribute here
  # keeps the transformer total so the refusal is the only error reported.
  defp id_argument(attributes, [attribute_name | _]),
    do: id_argument(attributes, [attribute_name])
end
