# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Union.Info do
  @moduledoc """
  Introspection of an `AshStrangler.Union`. Works on a compiled module or a
  `Spark.Dsl` state, so verifiers can use it.

  The lens kinds are what a host verifier reads to decide where a column comes
  from on each branch:

    * `:column`: a bare column of the branch's twin;
    * `:expression`: an expression over the twin's columns;
    * `:constant`: a literal;
    * `:null`: an unmapped column;
    * `:owned`: every column of the owned branch.

  `twin_derived?/1` is true for `:column` and `:expression`.
  """

  alias AshStrangler.Union.{Column, Constant, Legacy, Owned, Unmapped}
  alias AshStrangler.Union.Map, as: MapEntry

  @type kind :: :column | :expression | :constant | :null | :owned

  @spec schema(module() | Spark.Dsl.t()) :: String.t()
  def schema(union), do: Spark.Dsl.Extension.get_opt(union, [:union], :schema, "public")

  @spec view(module() | Spark.Dsl.t()) :: String.t() | nil
  def view(union), do: Spark.Dsl.Extension.get_opt(union, [:union], :view, nil)

  @doc "The canonical key column."
  @spec key(module() | Spark.Dsl.t()) :: atom()
  def key(union), do: Spark.Dsl.Extension.get_opt(union, [:union], :key, :id)

  @doc "The schema-qualified, quoted name of the view."
  @spec view_name(module() | Spark.Dsl.t()) :: String.t()
  def view_name(union), do: ~s("#{schema(union)}"."#{view(union)}")

  @spec columns(module() | Spark.Dsl.t()) :: [Column.t()]
  def columns(union), do: entities(union, Column)

  @doc "Every legacy branch, in declaration order."
  @spec branches(module() | Spark.Dsl.t()) :: [Legacy.t()]
  def branches(union), do: entities(union, Legacy)

  @spec branch(module() | Spark.Dsl.t(), atom()) :: Legacy.t() | nil
  def branch(union, name), do: Enum.find(branches(union), &(&1.name == name))

  @doc "The owned branch."
  @spec owned(module() | Spark.Dsl.t()) :: Owned.t() | nil
  def owned(union), do: union |> entities(Owned) |> List.first()

  @doc "The owned table, schema-qualified and quoted."
  @spec owned_table(module() | Spark.Dsl.t()) :: String.t()
  def owned_table(union) do
    table = (owned(union) && owned(union).table) || "#{view(union)}_owned"
    ~s("#{schema(union)}"."#{table}")
  end

  @doc "A branch's phase."
  @spec phase(module() | Spark.Dsl.t(), atom()) :: atom() | nil
  def phase(union, name), do: with(%Legacy{phase: phase} <- branch(union, name), do: phase)

  @doc """
  The phase of the union as a whole: its least advanced legacy branch, or
  `:decommissioned` when no legacy branch is left.
  """
  @spec resource_phase(module() | Spark.Dsl.t()) :: atom()
  def resource_phase(union) do
    order = AshStrangler.Union.Dsl.phases()

    union
    |> branches()
    |> Enum.map(& &1.phase)
    |> Enum.min_by(&Enum.find_index(order, fn p -> p == &1 end), fn -> :decommissioned end)
  end

  @doc "The legacy branches still in the view (`:read_from_legacy` and `:dual_write`)."
  @spec live_branches(module() | Spark.Dsl.t()) :: [Legacy.t()]
  def live_branches(union),
    do: Enum.filter(branches(union), &(&1.phase in [:read_from_legacy, :dual_write]))

  @doc "The lens of each column on a legacy branch: `%{column => kind}`. The key is `:key`."
  @spec lens_kinds(module() | Spark.Dsl.t(), atom()) :: %{atom() => kind() | :key}
  def lens_kinds(union, name) do
    case branch(union, name) do
      %Legacy{mappings: mappings} ->
        Enum.reduce(mappings, %{key(union) => :key}, &put_kind/2)

      nil ->
        if match?(%Owned{name: ^name}, owned(union)),
          do: Map.new([key(union) | Enum.map(columns(union), & &1.name)], &{&1, :owned}),
          else: raise(ArgumentError, "#{inspect(name)} is not a branch of #{inspect(union)}")
    end
  end

  @doc "Whether a lens kind reads the branch's twin."
  @spec twin_derived?(kind() | :key) :: boolean()
  def twin_derived?(kind), do: kind in [:column, :expression, :key]

  defp put_kind(%MapEntry{attribute: attribute, from: from}, acc) when is_atom(from),
    do: Map.put(acc, attribute, :column)

  defp put_kind(%MapEntry{attribute: attribute, from: from}, acc) do
    kind =
      if match?({:ok, _}, AshStrangler.Expr.simple_reference(from)),
        do: :column,
        else: :expression

    Map.put(acc, attribute, kind)
  end

  defp put_kind(%Constant{attribute: attribute}, acc), do: Map.put(acc, attribute, :constant)

  defp put_kind(%Unmapped{attributes: attributes}, acc),
    do: Enum.reduce(attributes, acc, &Map.put(&2, &1, :null))

  defp entities(union, struct) do
    union |> Spark.Dsl.Extension.get_entities([:union]) |> Enum.filter(&is_struct(&1, struct))
  end
end
