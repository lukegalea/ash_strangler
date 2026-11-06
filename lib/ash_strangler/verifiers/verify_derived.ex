# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyDerived do
  @moduledoc """
  Compile-time checks on an `AshStrangler.Derived`.

    * a `view`, a twin, a registry that declares the `logical` kind, and `from`
      columns the twin has;
    * at least one source; source and column names are unique, and no column is
      named like the key or `__source`;
    * a source answers every column exactly once (`map`, `constant`,
      `unmapped`; an `element` answers its `value` and `ordinal` by itself) and
      reads only columns of the twin;
    * an `element` names a `from` column of the twin, a `value` column, and an
      `ordinal` column different from it; a `slot` or `synthesized` row sets
      none of those.

  Every refusal names the source and the column.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Expr, KeyKinds, Twin}
  alias AshStrangler.Derived.Info
  alias AshStrangler.Union.{Constant, TenantKey, Unmapped}
  alias AshStrangler.Union.Map, as: MapEntry
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case problems(dsl) do
      [] -> :ok
      [first | _] = all -> {:error, error(dsl, first, all)}
    end
  end

  @doc false
  def problems(dsl) do
    twin = Info.twin(dsl)
    sources = Info.sources(dsl)
    columns = Enum.map(Info.columns(dsl), & &1.name)

    if is_atom(twin) and Code.ensure_compiled(twin) == {:module, twin} and Twin.twin?(twin) do
      structure(dsl, sources, columns) ++
        key(dsl, twin) ++
        reads(twin, Info.filter(dsl), "the shared `filter`") ++
        Enum.flat_map(sources, &source_problems(&1, twin, columns))
    else
      ["#{inspect(twin)} is not a twin module"]
    end
  end

  defp structure(dsl, sources, columns) do
    key = Info.key(dsl)

    List.flatten([
      if(is_nil(Info.view(dsl)), do: ["declare the canonical `view`"], else: []),
      if(sources == [], do: ["declare at least one `slot`, `synthesized` or `element`"], else: []),
      dups(columns, "column"),
      dups(Enum.map(sources, & &1.name), "source"),
      if(key in columns or key == :__source,
        do: ["the key column #{inspect(key)} is also declared as a column"],
        else: []
      ),
      if(:__source in columns, do: ["`__source` is reserved for the source name"], else: [])
    ])
  end

  defp key(dsl, twin) do
    registry = Info.registry(dsl)
    kind = Info.kind(dsl)

    kind_problems =
      cond do
        not KeyKinds.registry?(registry) ->
          ["#{inspect(registry)} is not an `AshStrangler.KeyKinds` registry"]

        not Enum.any?(KeyKinds.logical_kinds(registry), &(&1.name == kind)) ->
          ["#{inspect(registry)} declares no `logical` kind #{inspect(kind)}"]

        true ->
          []
      end

    kind_problems ++
      if(Info.from(dsl) == [], do: ["`from` names no column"], else: []) ++
      missing(twin, Info.from(dsl), "`from`")
  end

  defp source_problems(source, twin, columns) do
    at = "#{source.kind} #{inspect(source.name)}: "

    Enum.map(
      shape(source, columns) ++ answers(source, columns) ++ source_reads(source, twin),
      &(at <> &1)
    )
  end

  defp shape(%{kind: :element} = s, columns) do
    List.flatten([
      if(is_nil(s.from), do: ["declare `from`, the jsonb column"], else: []),
      if(s.value in columns, do: [], else: ["`value` #{inspect(s.value)} is not a declared column"]),
      if(is_nil(s.ordinal) or s.ordinal in columns,
        do: [],
        else: ["`ordinal` #{inspect(s.ordinal)} is not a declared column"]
      ),
      if(s.ordinal != nil and s.ordinal == s.value,
        do: ["`value` and `ordinal` name one column"],
        else: []
      )
    ])
  end

  defp shape(s, _columns) do
    for {field, set?} <- [from: s.from, path: s.path != [], type: s.type, value: s.value, ordinal: s.ordinal],
        set? not in [nil, false],
        do: "`#{field}` belongs to an `element`"
  end

  defp answers(source, columns) do
    owned = if source.kind == :element, do: Enum.reject([source.value, source.ordinal], &is_nil/1), else: []

    answered =
      Enum.flat_map(source.mappings, fn
        %MapEntry{attribute: a} -> [a]
        %Constant{attribute: a} -> [a]
        %TenantKey{attribute: a} -> [a]
        %Unmapped{attributes: as} -> as
      end)

    List.flatten([
      for(a <- answered -- columns, do: "#{inspect(a)} is not a declared column"),
      for(a <- answered, a in owned, do: "#{inspect(a)} is the element's own column"),
      for(
        c <- (columns -- answered) -- owned,
        do: "column #{inspect(c)} is not answered: `map`, `constant` or `unmapped` it"
      ),
      dups(answered, "mapping for column")
    ])
  end

  defp source_reads(source, twin) do
    mapped =
      Enum.flat_map(source.mappings, fn
        %MapEntry{from: from} when is_atom(from) -> missing(twin, [from], "`map`")
        %MapEntry{from: from} -> reads(twin, from, "`map`")
        %TenantKey{} = key -> missing(twin, TenantKey.columns(key), "`tenant_of`")
        _ -> []
      end)

    jsonb = if source.kind == :element and source.from, do: missing(twin, [source.from], "`from`"), else: []
    mapped ++ jsonb ++ reads(twin, source.filter, "`filter`")
  end

  defp reads(_twin, nil, _what), do: []

  defp reads(twin, expression, what),
    do: missing(twin, for({[], c} <- Expr.refs(expression), do: c), what)

  defp missing(twin, columns, what) do
    attrs = Twin.columns(twin)

    for column <- columns,
        column not in attrs,
        do: "#{what} reads #{inspect(column)}, which #{inspect(twin)} does not have"
  end

  defp dups(names, what) do
    for {name, n} <- Enum.frequencies(names),
        n > 1,
        do: "#{what} #{inspect(name)} is declared #{n} times"
  end

  defp error(dsl, first, all) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:derived],
      message: """
      #{first}

      All problems:
      #{Enum.map_join(all, "\n", &"  * #{&1}")}
      """
    )
  end
end
