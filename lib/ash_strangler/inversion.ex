# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Inversion do
  @moduledoc """
  Predicate inversion: a tenant predicate that uses the legacy table's own index.

  A union's `tenant` column is a packed key computed from legacy integers. A predicate
  `tenant = $1` therefore evaluates the packing expression for every row of every branch, and a
  database that cannot add an expression index to the legacy tables (the usual case in front of a
  system you do not own) reads them in full.

  The packing is a bijection, so the predicate has an equivalent form on the integers: decode `$1`
  here, once, and compare the legacy columns. The union view carries those columns, uncast, as
  `"__tenant_p0"`, `"__tenant_p1"`, ... (`AshStrangler.Union.Info.tenant_part_columns/1`). A
  predicate on them is pushed into each branch of the `UNION ALL` and meets whatever index the
  legacy table already has on those columns.

      (__branch = 'north' AND __tenant_p0 = 7)
      OR (__branch = 'south' AND __tenant_p0 = 7)
      OR (__branch = 'native' AND tenant = '<uuid>')

  Each arm names its branch with a constant, so the planner drops the arms of the other branches
  from every subquery. The owned branch keeps the original predicate: its rows have no legacy
  integers, and its table is yours to index. A branch whose kind does not decode `$1` contributes
  no arm, which is exactly right: no row of that branch can have that tenant.

  Only a union is inverted. A derived view of `element` sources puts a `DISTINCT ON` between the
  predicate and the table, which the planner will not push through.

  The branches of one union should give a tenant part the same integer type. If they differ, the
  union view widens the column and the branch with the narrower type is cast, which hides its index.
  """

  alias Ash.Query.{BooleanExpression, Operator, Ref}
  alias AshStrangler.KeyKinds
  alias AshStrangler.Sql.Printer
  alias AshStrangler.Union.{Info, TenantKey}

  @typedoc "One arm: the branch it belongs to, and the integers to compare, or `:original` for the owned branch."
  @type arm :: {branch :: atom(), [integer()] | :original}

  @doc """
  The arms of the inverted predicate `tenant = tenant_id`, one per branch that can hold the tenant.

  The owned branch is always present, with `:original`.
  """
  @spec arms(module(), String.t()) :: [arm()]
  def arms(union, tenant_id) when is_binary(tenant_id) do
    tenant = Info.tenant(union) || raise ArgumentError, "#{inspect(union)} declares no `tenant`"

    legacy =
      for branch <- Info.live_branches(union),
          %TenantKey{kind: {registry, kind}} <- [Info.tenant_key(branch, tenant)],
          {:ok, parts} <- [KeyKinds.decode(registry, kind, tenant_id)],
          do: {branch.name, parts}

    legacy ++ [{Info.owned(union).name, :original}]
  end

  @doc """
  The inverted predicate as a SQL condition over the union's view. Equivalent to
  `"tenant" = tenant_id`, and the form that can use the legacy indexes.
  """
  @spec where_sql(module(), String.t()) :: String.t()
  def where_sql(union, tenant_id) do
    tenant = Info.tenant(union)
    columns = Info.tenant_part_columns(union)

    union
    |> arms(tenant_id)
    |> Enum.map_join(" OR ", fn
      {branch, :original} ->
        ~s[("__branch" = #{Printer.literal(to_string(branch))} AND "#{tenant}" = #{Printer.literal(tenant_id)})]

      {branch, parts} ->
        compares =
          columns
          |> Enum.zip(parts)
          |> Enum.map_join(" AND ", fn {column, part} -> ~s["#{column}" = #{part}] end)

        ~s[("__branch" = #{Printer.literal(to_string(branch))} AND #{compares})]
    end)
    |> then(&"(#{&1})")
  end

  @doc """
  The same predicate as an `Ash.Filter` expression over `resource`, which must have the view's
  `__branch` and `__tenant_p<i>` columns as attributes, besides the tenant column.

      Ash.Query.filter(query, ^AshStrangler.Inversion.filter(Visits, Visit, tenant_id))
  """
  @spec filter(module(), Ash.Resource.t(), String.t()) :: term()
  def filter(union, resource, tenant_id) do
    tenant = Info.tenant(union)
    columns = Info.tenant_part_columns(union)

    union
    |> arms(tenant_id)
    |> Enum.map(fn
      {branch, :original} ->
        all([eq(resource, :__branch, to_string(branch)), eq(resource, tenant, tenant_id)])

      {branch, parts} ->
        all([
          eq(resource, :__branch, to_string(branch))
          | columns
            |> Enum.zip(parts)
            |> Enum.map(fn {column, part} -> eq(resource, column, part) end)
        ])
    end)
    |> Enum.reduce(&BooleanExpression.optimized_new(:or, &2, &1))
  end

  defp all(operators), do: Enum.reduce(operators, &BooleanExpression.optimized_new(:and, &2, &1))

  defp eq(resource, name, value) do
    attribute =
      Ash.Resource.Info.attribute(resource, name) ||
        raise ArgumentError, "#{inspect(resource)} has no attribute #{inspect(name)}"

    ref = %Ref{relationship_path: [], resource: resource, attribute: attribute}

    {:ok, operator} = Operator.new(Operator.Eq, ref, value)
    operator
  end
end
