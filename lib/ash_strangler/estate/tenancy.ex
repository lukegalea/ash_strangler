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
    * the `tenant_of` columns are the kind's own home columns, or have a validated
      foreign key onto them in the estate's catalog: packing any other column
      would put rows under a tenant that does not exist (tenant closure);
    * a `tenant_of` with `through:` (opt-in: the tenant is reached from the row,
      not on it) packs the end of a declared chain instead. The kind has one part
      and `from` is one column; every hop's relation and columns are in the
      catalog; every hop follows a validated foreign key from the value so far
      (either direction, or both onto the same column); and every chain's last
      column is the home or has a validated foreign key onto it, and fits the
      part. A chain is never inferred: a column that is not the home and declares
      no `through:` is refused as above;
    * the tenant column is declared `null?: false`, so an owned row cannot
      lack a tenant.

  Every problem names the module, the branch or source and the column, and
  carries `check: :tenant`.
  """

  alias AshStrangler.{Derived, KeyKind, KeyKinds, Migration}
  alias AshStrangler.Estate.Report
  alias AshStrangler.Union
  alias AshStrangler.Union.TenantKey
  alias AshStrangler.Verifiers.KeyCatalog

  @doc "The E5 problems of the `modules` of an estate, closure read from its `catalog`."
  @spec problems([module()], map()) :: [Report.problem()]
  def problems(modules, catalog),
    do: Enum.flat_map(modules, &module_problems(&1, catalog["relations"] || %{}))

  defp module_problems(module, relations) do
    cond do
      not Code.ensure_loaded?(module) ->
        []

      Migration.union?(module) ->
        scoped(module, Union.Info, Union.Info.branches(module), "branch", relations, & &1.twin)

      Migration.derived?(module) ->
        twin = Derived.Info.twin(module)

        scoped(module, Derived.Info, Derived.Info.sources(module), "source", relations, fn _ ->
          twin
        end)

      true ->
        []
    end
  end

  defp scoped(module, info, units, noun, relations, twin_of) do
    case info.tenant(module) do
      nil ->
        []

      column ->
        nullable(module, info, column) ++
          for unit <- units,
              message <- unit_problems(unit, column, twin_of.(unit), relations),
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

  defp unit_problems(unit, column, twin, relations) do
    case answer(unit.mappings, column) do
      %TenantKey{kind: {registry, kind}} = key ->
        cond do
          not KeyKinds.registry?(registry) ->
            ["#{inspect(registry)} is not a key-kind registry"]

          KeyKinds.kind(registry, kind) == nil ->
            ["#{inspect(registry)} declares no kind #{inspect(kind)}"]

          KeyKinds.tenant_kind?(registry, kind) and TenantKey.chained?(key) ->
            chain_closure(key, KeyKinds.kind(registry, kind), twin, relations)

          KeyKinds.tenant_kind?(registry, kind) ->
            closure(key, KeyKinds.kind(registry, kind), twin, relations)

          true ->
            ["kind #{inspect(kind)} of #{inspect(registry)} is not declared `tenant?: true`"]
        end

      nil ->
        ["does not answer the tenant column"]

      other ->
        ["answers the tenant column with #{describe(other)}, not `tenant_of` a tenant key kind"]
    end
  end

  # The packed columns must be the tenant's own, or have a validated foreign key onto it.
  defp closure(key, kind, twin, relations) do
    name = KeyCatalog.relation_name(twin)
    from = TenantKey.columns(key)
    home = Enum.map_join(KeyKind.columns(kind), ", ", fn {rel, col} -> "#{rel}.#{col}" end)

    with {:ok, columns} <- KeyCatalog.columns(twin, from),
         relation when is_map(relation) <- relations[name] do
      if length(columns) == length(kind.parts) and
           KeyCatalog.closed?(name, relation, columns, kind),
         do: [],
         else: [
           "`tenant_of` packs #{Enum.map_join(columns, ", ", &"#{name}.#{&1}")}, which is not #{home} " <>
             "and has no validated foreign key onto it, so a row may be shown under a tenant that does not exist"
         ]
    else
      {:error, attribute} ->
        ["`tenant_of` reads #{inspect(attribute)}, which #{inspect(twin)} does not have"]

      nil ->
        ["the estate catalog has no relation `#{name}`, so tenant closure cannot be shown"]
    end
  end

  # A declared chain: one part, one starting column, every hop on a validated foreign key, and
  # every chain ending on the kind's home (or a validated foreign key onto it).
  defp chain_closure(key, kind, twin, relations) do
    name = KeyCatalog.relation_name(twin)

    with :ok <- one_part(kind, key),
         {:ok, [from]} <- KeyCatalog.columns(twin, TenantKey.columns(key)),
         relation when is_map(relation) <- relations[name] do
      for {chain, index} <- Enum.with_index(TenantKey.chains(key), 1),
          message <- chain_problems(chain, {name, from}, kind, relations),
          do: "`through:` chain #{index}: #{message}"
    else
      {:error, attribute} when is_atom(attribute) ->
        ["`tenant_of` reads #{inspect(attribute)}, which #{inspect(twin)} does not have"]

      {:error, message} ->
        [message]

      nil ->
        ["the estate catalog has no relation `#{name}`, so tenant closure cannot be shown"]
    end
  end

  defp one_part(kind, key) do
    if length(kind.parts) == 1 and length(TenantKey.columns(key)) == 1,
      do: :ok,
      else:
        {:error,
         "`through:` packs one value, so the kind must have one part and `from` one column"}
  end

  defp chain_problems([], _start, _kind, _relations), do: ["declares no hop"]

  defp chain_problems(chain, start, kind, relations) do
    {problems, last} =
      Enum.reduce(chain, {[], start}, fn
        _hop, {problems, nil} ->
          {problems, nil}

        hop, {problems, {prev_rel, prev_col} = prev} ->
          hop_step(hop, prev_rel, prev_col, prev, problems, relations)
      end)

    problems ++ last_problems(last, kind, relations)
  end

  defp hop_step(hop, prev_rel, prev_col, prev, problems, relations) do
    relation = relations[hop.name]

    cond do
      is_nil(relation) ->
        {problems ++ ["the estate catalog has no relation `#{hop.name}`"], nil}

      missing = Enum.find([hop.match, hop.take], &is_nil(KeyCatalog.column(relation, &1))) ->
        {problems ++ ["`#{hop.name}` has no column `#{missing}`"], nil}

      linked?(relations, prev, {hop.name, hop.match}) ->
        {problems, {hop.name, hop.take}}

      true ->
        {problems ++
           [
             "#{prev_rel}.#{prev_col} reaches #{hop.name}.#{hop.match} by no validated foreign key"
           ], nil}
    end
  end

  # The value so far and the hop's match column are joined by a validated foreign key: one onto
  # the other, or both onto the same column.
  defp linked?(relations, from, to) do
    onto = fn {rel, col} -> validated_fks(relations[rel], col) end

    to in onto.(from) or from in onto.(to) or Enum.any?(onto.(from), &(&1 in onto.(to)))
  end

  defp validated_fks(nil, _column), do: []

  defp validated_fks(relation, column) do
    for fk <- relation["foreign_keys"] || [],
        fk["validated"],
        fk["columns"] == [column],
        do: {fk["references"]["relation"], hd(fk["references"]["columns"])}
  end

  defp last_problems(nil, _kind, _relations), do: []

  defp last_problems({name, column}, kind, relations) do
    relation = relations[name]
    home = Enum.map_join(KeyKind.columns(kind), ", ", fn {rel, col} -> "#{rel}.#{col}" end)

    if KeyCatalog.closed?(name, relation, [column], kind),
      do: KeyCatalog.width_problems(relation, [column], kind, false),
      else: [
        "ends on #{name}.#{column}, which is not #{home} and has no validated foreign key onto it, " <>
          "so a row may be shown under a tenant that does not exist"
      ]
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
      message:
        "#{inspect(module)} #{who}: #{message} (tenant column #{inspect(column)}); estate check E5"
    }
  end
end
