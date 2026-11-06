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
    * the `from` columns are the kind's own home columns on the kind's own
      relation, or a **validated** foreign key of the twin's relation in the
      estate's catalog maps them onto the home, column for column. Otherwise any
      integer column could be packed as a tenant and a row put under another
      tenant;
    * the tenant column is declared `null?: false`, so an owned row cannot
      lack a tenant.

  Every problem names the module, the branch or source and the column, and
  carries `check: :tenant`.
  """

  alias AshStrangler.{Derived, KeyKind, KeyKinds, Migration}
  alias AshStrangler.Estate.Report
  alias AshStrangler.Union
  alias AshStrangler.Union.TenantKey

  @doc "The E5 problems of the `modules` of an estate."
  @spec problems([module()], map()) :: [Report.problem()]
  def problems(modules, catalog), do: Enum.flat_map(modules, &module_problems(&1, catalog))

  defp module_problems(module, catalog) do
    cond do
      not Code.ensure_loaded?(module) ->
        []

      Migration.union?(module) ->
        scoped(module, Union.Info, Union.Info.branches(module), "branch", catalog)

      Migration.derived?(module) ->
        scoped(module, Derived.Info, Derived.Info.sources(module), "source", catalog)

      true ->
        []
    end
  end

  defp scoped(module, info, units, noun, catalog) do
    case info.tenant(module) do
      nil ->
        []

      column ->
        nullable(module, info, column) ++
          for unit <- units,
              message <- unit_problems(unit, column, twin(module, info, unit), catalog),
              do: problem(module, unit, noun, column, message)
    end
  end

  defp nullable(module, info, column) do
    case Enum.find(info.columns(module), &(&1.name == column)) do
      nil ->
        [problem(module, column, "column", column, "the tenant column is not a declared column")]

      %{null?: false} ->
        []

      _ ->
        [problem(module, column, "column", column, "the tenant column must be `null?: false`")]
    end
  end

  defp twin(module, Derived.Info, _unit), do: Derived.Info.twin(module)
  defp twin(_module, _info, unit), do: unit.twin

  defp unit_problems(unit, column, twin, catalog) do
    case answer(unit.mappings, column) do
      %TenantKey{kind: {registry, kind}} = key ->
        cond do
          not KeyKinds.registry?(registry) ->
            ["#{inspect(registry)} is not a key-kind registry"]

          KeyKinds.kind(registry, kind) == nil ->
            ["#{inspect(registry)} declares no kind #{inspect(kind)}"]

          KeyKinds.tenant_kind?(registry, kind) ->
            closure(key, KeyKinds.kind(registry, kind), twin, catalog)

          true ->
            ["kind #{inspect(kind)} of #{inspect(registry)} is not declared `tenant?: true`"]
        end

      nil ->
        ["does not answer the tenant column"]

      other ->
        ["answers the tenant column with #{describe(other)}, not `tenant_of` a tenant key kind"]
    end
  end

  # The `from` columns must be the kind's home part, or backed by a validated foreign key
  # to it, as a `reference` is (V-REF).
  defp closure(key, kind, twin, catalog) do
    relation =
      "#{AshPostgres.DataLayer.Info.schema(twin) || "public"}.#{AshPostgres.DataLayer.Info.table(twin)}"

    columns = Enum.map(TenantKey.columns(key), &source_name(twin, &1))
    home = KeyKind.columns(kind)

    if home == Enum.map(columns, &{relation, &1}) or backed?(catalog, relation, columns, home) do
      []
    else
      [
        "#{Enum.join(columns, ", ")} of #{relation} is not #{format_home(home)} and no validated " <>
          "foreign key in the catalog maps it onto it, so a row may be shown under a tenant it " <>
          "does not belong to"
      ]
    end
  end

  defp source_name(twin, attribute) do
    case Ash.Resource.Info.attribute(twin, attribute) do
      nil -> to_string(attribute)
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp backed?(catalog, relation, columns, home) do
    foreign_keys = get_in(catalog, ["relations", relation, "foreign_keys"]) || []

    Enum.any?(foreign_keys, fn fk ->
      mapping = Enum.zip(fk["columns"], fk["references"]["columns"]) |> Map.new()

      fk["validated"] == true and MapSet.new(fk["columns"]) == MapSet.new(columns) and
        Enum.map(columns, &{fk["references"]["relation"], mapping[&1]}) == home
    end)
  end

  defp format_home(home), do: Enum.map_join(home, ", ", fn {rel, col} -> "#{rel}.#{col}" end)

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
      message:
        "#{inspect(module)} #{who}: #{message} (tenant column #{inspect(column)}); estate check E5"
    }
  end
end
