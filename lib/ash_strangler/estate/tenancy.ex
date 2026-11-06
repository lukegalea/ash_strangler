# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Tenancy do
  @moduledoc """
  Check E5: tenant closure, over the unions and derived views of an estate.

  A union or derived view that declares a `tenant` column is tenant-scoped.
  Every row it can show must say which tenant it belongs to, derived from the
  legacy row itself, so that no join hides a row of one tenant behind another:

    * every legacy branch of a union, and every source of a derived view, answers
      the tenant column with `tenant_of`, a packed key of a registry kind
      declared `tenant?: true`. A `map`, an expression, a `constant` or an
      `unmapped` answer is refused: none of them is a derivation a tenant key
      can be checked against;
    * the `tenant_of` kind exists in its registry (compile-time verifiers
      cannot see another module's registry, so it is checked here);
    * the tenant column is declared `null?: false`, so an owned row cannot
      lack a tenant.

  Every problem names the module, the branch or source and the column, and
  carries `check: :tenant`.
  """

  alias AshStrangler.{Derived, KeyKinds, Migration}
  alias AshStrangler.Estate.Report
  alias AshStrangler.Union
  alias AshStrangler.Union.TenantKey

  @doc "The E5 problems of the `modules` of an estate."
  @spec problems([module()]) :: [Report.problem()]
  def problems(modules), do: Enum.flat_map(modules, &module_problems/1)

  defp module_problems(module) do
    cond do
      not Code.ensure_loaded?(module) -> []
      Migration.union?(module) -> scoped(module, Union.Info, Union.Info.branches(module), "branch")
      Migration.derived?(module) -> scoped(module, Derived.Info, Derived.Info.sources(module), "source")
      true -> []
    end
  end

  defp scoped(module, info, units, noun) do
    case info.tenant(module) do
      nil ->
        []

      column ->
        nullable(module, info, column) ++
          for unit <- units, message <- unit_problems(unit, column), do: problem(module, unit, noun, column, message)
    end
  end

  defp nullable(module, info, column) do
    case Enum.find(info.columns(module), &(&1.name == column)) do
      nil -> [problem(module, column, "column", column, "the tenant column is not a declared column")]
      %{null?: false} -> []
      _ -> [problem(module, column, "column", column, "the tenant column must be `null?: false`")]
    end
  end

  defp unit_problems(unit, column) do
    case answer(unit.mappings, column) do
      %TenantKey{kind: {registry, kind}} ->
        cond do
          not KeyKinds.registry?(registry) -> ["#{inspect(registry)} is not a key-kind registry"]
          KeyKinds.kind(registry, kind) == nil -> ["#{inspect(registry)} declares no kind #{inspect(kind)}"]
          KeyKinds.tenant_kind?(registry, kind) -> []
          true -> ["kind #{inspect(kind)} of #{inspect(registry)} is not declared `tenant?: true`"]
        end

      nil ->
        ["does not answer the tenant column"]

      other ->
        ["answers the tenant column with #{describe(other)}, not `tenant_of` a tenant key kind"]
    end
  end

  defp answer(mappings, column) do
    Enum.find(mappings, fn
      %{attribute: ^column} -> true
      %{attributes: attributes} -> column in attributes
      _ -> false
    end)
  end

  defp describe(%Union.Map{}), do: "a `map`"
  defp describe(%Union.Constant{}), do: "a `constant`"
  defp describe(%Union.Unmapped{}), do: "`unmapped`"

  defp problem(module, %{name: name}, noun, column, message),
    do: build(module, "#{noun} #{inspect(name)}", column, message)

  defp problem(module, _unit, noun, column, message), do: build(module, noun, column, message)

  defp build(module, who, column, message) do
    %{
      check: :tenant,
      subject: "#{inspect(module)}.#{column}",
      message: "#{inspect(module)} #{who}: #{message} (tenant column #{inspect(column)}); estate check E5"
    }
  end
end
