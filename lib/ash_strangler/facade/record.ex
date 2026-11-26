# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Record do
  @moduledoc false
  # One mapping from a source row to a facade record, used by both
  # `AshStrangler.Facade.Read` and `AshStrangler.Facade.Write`, so the two
  # cannot drift: a write returns what a read of the same row returns.

  alias AshStrangler.{Eval, Facade.Info}

  @doc false
  @spec record(
          Ash.Resource.record(),
          Ash.Resource.t(),
          %{atom() => AshStrangler.Lens.t()},
          Ash.Resource.t()
        ) ::
          Ash.Resource.record()
  def record(source_row, facade, lenses, source) do
    values = Map.from_struct(source_row)

    facade
    |> struct(facade_values(values, facade, lenses))
    |> Ash.Resource.put_metadata(:source, primary_key(source, values))
  end

  @doc false
  @spec facade_values(map(), Ash.Resource.t(), %{atom() => AshStrangler.Lens.t()}) :: map()
  def facade_values(values, facade, lenses) do
    Map.new(Ash.Resource.Info.attributes(facade), fn attribute ->
      {attribute.name, Eval.forward(Map.fetch!(lenses, attribute.name), values, [])}
    end)
  end

  @doc false
  @spec primary_key(Ash.Resource.t(), map()) :: map()
  def primary_key(source, values) do
    source
    |> Ash.Resource.Info.primary_key()
    |> Map.new(&{&1, Map.fetch!(values, &1)})
  end

  @doc false
  @spec load_fields(%{atom() => AshStrangler.Lens.t()}, Ash.Resource.t()) :: [atom()]
  def load_fields(lenses, source) do
    # Attributes come with the read and with the update; a calculation or
    # aggregate a lens reads has to be asked for, or the row has no value to
    # put through the lens.
    lenses
    |> Map.values()
    |> Info.source_attributes()
    |> Enum.filter(fn name ->
      case Ash.Resource.Info.field(source, name) do
        %Ash.Resource.Calculation{} -> true
        %Ash.Resource.Aggregate{} -> true
        _ -> false
      end
    end)
  end
end
