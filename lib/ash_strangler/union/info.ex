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
    * `:extension`: a column stored in the union's extension table;
    * `:owned`: every column of the owned branch.

  `twin_derived?/1` is true for `:column` and `:expression`.
  """

  alias AshStrangler.Union.{
    Column,
    Constant,
    Extension,
    InsertThrough,
    Legacy,
    NotWrittenBack,
    Owned,
    RefuseDelete,
    TenantKey,
    Unmapped
  }

  alias AshStrangler.Union.Map, as: MapEntry

  @type kind :: :column | :expression | :constant | :null | :extension | :owned

  @spec schema(module() | Spark.Dsl.t()) :: String.t()
  def schema(union), do: Spark.Dsl.Extension.get_opt(union, [:union], :schema, "public")

  @spec view(module() | Spark.Dsl.t()) :: String.t() | nil
  def view(union), do: Spark.Dsl.Extension.get_opt(union, [:union], :view, nil)

  @doc "The tenant column (estate check E5), or `nil`."
  @spec tenant(module() | Spark.Dsl.t()) :: atom() | nil
  def tenant(union), do: Spark.Dsl.Extension.get_opt(union, [:union], :tenant, nil)

  @doc """
  The hidden view columns that carry the tenant key's integer parts, one per part, or `[]` when the
  union declares no tenant. They are the last columns of the view; `AshStrangler.Inversion` filters
  on them.
  """
  @spec tenant_part_columns(module() | Spark.Dsl.t()) :: [String.t()]
  def tenant_part_columns(union) do
    case tenant(union) do
      nil ->
        []

      tenant ->
        count =
          union
          |> branches()
          |> Enum.map(&tenant_key(&1, tenant))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&length(TenantKey.columns(&1)))
          |> Enum.max(fn -> 0 end)

        Enum.map(0..(count - 1)//1, &"__tenant_p#{&1}")
    end
  end

  @doc "The `tenant_of` entry of `branch` for the tenant column `attribute`, or `nil`."
  @spec tenant_key(Legacy.t(), atom() | nil) :: TenantKey.t() | nil
  def tenant_key(%Legacy{mappings: mappings}, attribute),
    do: Enum.find(mappings, &match?(%TenantKey{attribute: ^attribute}, &1))

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

  @doc "The columns a branch's `:dual_write` update does not write back."
  @spec not_written_back(Legacy.t()) :: [atom()]
  def not_written_back(%Legacy{write_rules: rules}),
    do: for(%NotWrittenBack{attributes: attributes} <- rules, a <- attributes, do: a)

  @doc "The columns a branch keeps in the extension table."
  @spec extension_columns(Legacy.t()) :: [atom()]
  def extension_columns(%Legacy{mappings: mappings}),
    do: for(%Extension{attributes: attributes} <- mappings, a <- attributes, do: a)

  @doc "The reason a branch refuses deletes at `:dual_write`, or `nil`."
  @spec refuse_delete(Legacy.t()) :: String.t() | nil
  def refuse_delete(%Legacy{write_rules: rules}),
    do:
      Enum.find_value(rules, fn
        %RefuseDelete{because: b} -> b
        _ -> nil
      end)

  @doc "A branch's `insert_through` declaration, or `nil`."
  @spec insert_through(Legacy.t()) :: InsertThrough.t() | nil
  def insert_through(%Legacy{write_rules: rules}),
    do: Enum.find(rules, &match?(%InsertThrough{}, &1))

  @doc "Whether the union renders its trigger functions `SECURITY DEFINER`."
  @spec security_definer?(module() | Spark.Dsl.t()) :: boolean()
  def security_definer?(union),
    do: Spark.Dsl.Extension.get_opt(union, [:union], :security_definer, false)

  @doc "The union's extension table, schema-qualified and quoted."
  @spec extension_table(module() | Spark.Dsl.t()) :: String.t()
  def extension_table(union),
    do: AshStrangler.Sql.Extension.relation_named(schema(union), "#{view(union)}")

  @doc "Whether any live branch keeps columns in the extension table."
  @spec extension?(module() | Spark.Dsl.t()) :: boolean()
  def extension?(union), do: Enum.any?(live_branches(union), &(extension_columns(&1) != []))

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

  defp put_kind(%TenantKey{attribute: attribute}, acc), do: Map.put(acc, attribute, :expression)

  defp put_kind(%Constant{attribute: attribute}, acc), do: Map.put(acc, attribute, :constant)

  defp put_kind(%Extension{attributes: attributes}, acc),
    do: Enum.reduce(attributes, acc, &Map.put(&2, &1, :extension))

  defp put_kind(%Unmapped{attributes: attributes}, acc),
    do: Enum.reduce(attributes, acc, &Map.put(&2, &1, :null))

  defp entities(union, struct) do
    union |> Spark.Dsl.Extension.get_entities([:union]) |> Enum.filter(&is_struct(&1, struct))
  end
end
