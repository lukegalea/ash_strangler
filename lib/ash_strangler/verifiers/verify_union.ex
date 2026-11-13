# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyUnion do
  @moduledoc """
  Compile-time checks on an `AshStrangler.Union`.

    * one `view`, at least one legacy branch and exactly one owned branch;
    * column, branch and key names are unique, and no column is named like the
      key or `__branch`;
    * a branch's twin is a twin, and everything a branch reads is a column of it;
    * a branch has exactly one `key`, a supported strategy over twin columns,
      and answers every column exactly once (`map`, `constant` or `unmapped`);
    * on a `:dual_write` branch no two columns map from one legacy column;
    * two branches share a key namespace (their ids could collide) only when
      each names the other in `shares_key_with`; a declaration names another
      legacy branch of the union whose key is in the same namespace.

  Every refusal names the branch and the column.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Expr, Twin}

  alias AshStrangler.Union.{
    Constant,
    Extension,
    Info,
    InsertThrough,
    NotWrittenBack,
    RefuseDelete,
    TenantKey,
    Unmapped
  }

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
    branches = Info.branches(dsl)
    columns = Enum.map(Info.columns(dsl), & &1.name)
    key = Info.key(dsl)

    structure(dsl, branches, columns, key) ++
      Enum.flat_map(branches, &branch_problems(&1, columns, key, Info.security_definer?(dsl))) ++
      key_collisions(branches)
  end

  defp structure(dsl, branches, columns, key) do
    owned =
      Spark.Dsl.Extension.get_entities(dsl, [:union])
      |> Enum.count(&is_struct(&1, AshStrangler.Union.Owned))

    List.flatten([
      if(is_nil(Info.view(dsl)), do: ["declare the canonical `view`"], else: []),
      if(branches == [], do: ["declare at least one `legacy` branch"], else: []),
      if(owned != 1, do: ["declare exactly one `owned` branch (found #{owned})"], else: []),
      dups(columns, "column"),
      dups(Enum.map(branches, & &1.name), "branch"),
      if(key in columns or key == :__branch,
        do: ["the key column #{inspect(key)} is also declared as a column"],
        else: []
      ),
      for(
        %NotWrittenBack{attributes: attributes} <- owned_rules(dsl),
        do:
          "the owned branch takes no `not_written_back` (#{Enum.map_join(attributes, ", ", &inspect/1)}): " <>
            "its columns are all stored"
      ),
      for(
        %InsertThrough{because: because} <- owned_rules(dsl),
        do:
          "the owned branch takes no `insert_through` (because: #{inspect(because)}): " <>
            "an insert naming no branch already lands in its own table"
      ),
      if(:__branch in columns, do: ["`__branch` is reserved for the branch name"], else: []),
      if(
        Enum.any?(branches, &(&1.name == :owned)) and owned == 1 and
          Info.owned(dsl).name == :owned,
        do: ["a legacy branch is named like the owned branch"],
        else: []
      )
    ])
  end

  defp owned_rules(dsl) do
    case Info.owned(dsl) do
      nil -> []
      owned -> owned.write_rules
    end
  end

  defp dups(names, what) do
    for {name, n} <- Enum.frequencies(names),
        n > 1,
        do: "#{what} #{inspect(name)} is declared #{n} times"
  end

  defp branch_problems(branch, columns, key, definer?) do
    at = "branch #{inspect(branch.name)}: "

    if Code.ensure_compiled(branch.twin) == {:module, branch.twin} and Twin.twin?(branch.twin) do
      Enum.map(
        key_problems(branch, key) ++
          mapping_problems(branch, columns) ++
          write_rule_problems(branch, columns) ++
          insert_through_problems(branch, columns, key) ++
          shared_source_problems(branch) ++ definer_problems(branch, definer?),
        &(at <> &1)
      ) ++
        if(String.trim(branch.refused_because) == "",
          do: [at <> "`refused_because` is empty"],
          else: []
        )
    else
      [at <> "#{inspect(branch.twin)} is not a twin module"]
    end
  end

  defp key_problems(branch, key) do
    case branch.keys do
      [%{from: from, strategy: strategy}] ->
        missing(branch.twin, List.wrap(from), "key") ++ strategy_problems(strategy, key)

      keys ->
        ["declare exactly one `key` (found #{length(keys)})"]
    end
  end

  defp strategy_problems({:uuid_v5, [namespace: ns]}, _key) when is_binary(ns), do: []
  defp strategy_problems({:uuid_v5, namespace: ns}, _key) when is_binary(ns), do: []

  defp strategy_problems({:uuid_v8, registry, kind}, _key)
       when is_atom(registry) and is_atom(kind),
       do: []

  defp strategy_problems(:identity, _key), do: []
  defp strategy_problems(other, _key), do: ["unsupported key strategy #{inspect(other)}"]

  defp mapping_problems(branch, columns) do
    answered =
      Enum.flat_map(branch.mappings, fn
        %MapEntry{attribute: a} -> [a]
        %Constant{attribute: a} -> [a]
        %TenantKey{attribute: a} -> [a]
        %Unmapped{attributes: as} -> as
        %Extension{attributes: as} -> as
      end)

    reads =
      Enum.flat_map(branch.mappings, fn
        %MapEntry{from: from} when is_atom(from) ->
          missing(branch.twin, [from], "map")

        %MapEntry{from: from} ->
          missing(branch.twin, for({[], c} <- Expr.refs(from), do: c), "map")

        %TenantKey{} = key ->
          missing(branch.twin, TenantKey.columns(key), "tenant_of")

        _ ->
          []
      end)

    filter =
      case branch.filter do
        nil -> []
        expression -> missing(branch.twin, for({[], c} <- Expr.refs(expression), do: c), "filter")
      end

    List.flatten([
      filter,
      for(a <- answered -- columns, do: "#{inspect(a)} is not a declared column"),
      for(
        c <- columns -- answered,
        do: "column #{inspect(c)} is not answered: `map`, `constant` or `unmapped` it"
      ),
      dups(answered, "mapping for column"),
      reads
    ])
  end

  defp write_rule_problems(branch, columns) do
    extension = Info.extension_columns(branch)
    refusals = for %RefuseDelete{} = r <- branch.write_rules, do: r

    List.flatten([
      for(
        %NotWrittenBack{attributes: attributes, because: because} <- branch.write_rules,
        a <- attributes,
        do:
          cond do
            a not in columns ->
              "`not_written_back` names #{inspect(a)}, which is not a declared column"

            a in extension ->
              "`not_written_back` names #{inspect(a)}, which is stored in the extension table"

            String.trim(because) == "" ->
              "`not_written_back` for #{inspect(a)} has an empty `because`"

            true ->
              []
          end
      ),
      for(
        r <- refusals,
        String.trim(r.because) == "",
        do: "`refuse_delete` has an empty `because`"
      ),
      if(length(refusals) > 1, do: ["declare at most one `refuse_delete`"], else: [])
    ])
  end

  defp insert_through_problems(branch, columns, key) do
    case Info.insert_through(branch) do
      nil ->
        []

      it ->
        key_sources = Enum.flat_map(branch.keys, &List.wrap(&1.from))
        extension = Info.extension_columns(branch)
        skipped = Info.not_written_back(branch)
        set_columns = Keyword.keys(it.set)

        List.flatten([
          if(
            branch.phase != :dual_write,
            do: [
              "`insert_through` needs the branch at `:dual_write`, and branch #{inspect(branch.name)} is at #{inspect(branch.phase)}"
            ],
            else: []
          ),
          if(String.trim(it.because) == "",
            do: ["`insert_through` has an empty `because`"],
            else: []
          ),
          dups(it.columns, "insert_through column"),
          for(
            a <- it.columns,
            do:
              insert_column_problem(
                branch,
                columns,
                key,
                a,
                key_sources,
                extension,
                skipped,
                set_columns
              )
          ),
          for(
            {column, value} <- it.set,
            do: set_constant_problem(branch, column, value, key_sources)
          )
        ])
    end
  end

  # A column of `insert_through`'s write list must be one the insert can write:
  # the same set a `:dual_write` update writes, narrowed by the declaration.
  defp insert_column_problem(
         branch,
         columns,
         key,
         a,
         key_sources,
         extension,
         skipped,
         set_columns
       ) do
    source = mapping_source(branch, a)

    cond do
      a == key ->
        "`insert_through` names #{inspect(a)}, which is the key: the legacy table allocates the key itself"

      a not in columns ->
        "`insert_through` names #{inspect(a)}, which is not a declared column"

      a in extension ->
        "`insert_through` names #{inspect(a)}, which is stored in the extension table"

      a in skipped ->
        "`insert_through` names #{inspect(a)}, which is `not_written_back`"

      source in key_sources ->
        "`insert_through` names #{inspect(a)}, which is read from a legacy column that forms the row's key"

      source in set_columns ->
        "`insert_through` names #{inspect(a)}, which `set:` gives a constant on every insert"

      is_nil(source) ->
        "`insert_through` names #{inspect(a)}, which has no legacy column to write"

      true ->
        []
    end
  end

  defp set_constant_problem(branch, column, value, key_sources) do
    twin = branch.twin

    cond do
      column not in Twin.columns(twin) ->
        "`insert_through` sets #{inspect(column)}, which #{inspect(twin)} does not have"

      column in key_sources ->
        "`insert_through` sets #{inspect(column)}, which forms the row's key: the legacy table allocates the key itself"

      problem = constant_type_problem(twin, column, value) ->
        problem

      true ->
        []
    end
  end

  # The value a `set:` constant renders must fit the twin column's type, where
  # the check is cheap: a literal's Elixir shape against the primitive the type
  # resolves to. Types this does not resolve are left to PostgreSQL, which sees
  # the literal's own type in the INSERT.
  defp constant_type_problem(twin, column, value) do
    declared = Twin.type!(twin, column)
    kind = literal_kind(declared)

    if kind && value != nil && not kind.(value) do
      "`insert_through` sets #{inspect(column)} to #{inspect(value)}, which the twin types as #{inspect(declared)}"
    else
      nil
    end
  end

  defp literal_kind({:array, inner}) do
    case literal_kind(inner) do
      nil -> &is_list/1
      element -> fn value -> is_list(value) and Enum.all?(value, element) end
    end
  end

  defp literal_kind(type) do
    case Ash.Type.get_type(type) do
      nil -> nil
      resolved -> resolved |> unwrap_subtype() |> kind_of()
    end
  rescue
    _ -> nil
  end

  defp unwrap_subtype(type) do
    if Ash.Type.NewType.new_type?(type),
      do: type |> Ash.Type.NewType.subtype_of() |> unwrap_subtype(),
      else: type
  end

  defp kind_of(Ash.Type.String), do: &is_binary/1
  defp kind_of(Ash.Type.Integer), do: &is_integer/1
  defp kind_of(Ash.Type.Boolean), do: &is_boolean/1
  defp kind_of(Ash.Type.Date), do: &match?(%Date{}, &1)
  defp kind_of(Ash.Type.Time), do: &match?(%Time{}, &1)
  defp kind_of(Ash.Type.DateTime), do: &match?(%DateTime{}, &1)
  defp kind_of(Ash.Type.NaiveDateTime), do: &match?(%NaiveDateTime{}, &1)
  defp kind_of(Ash.Type.Decimal), do: &(is_struct(&1, Decimal) or is_integer(&1) or is_float(&1))
  defp kind_of(Ash.Type.Atom), do: &(is_atom(&1) or is_binary(&1))
  defp kind_of(Ash.Type.CiString), do: &is_binary/1
  defp kind_of(Ash.Type.UUID), do: &is_binary/1
  defp kind_of(_type), do: nil

  # The legacy column behind a plain `map` mapping, or `nil`: an atom `from`,
  # or an expression that is a bare reference.
  defp mapping_source(branch, attribute) do
    Enum.find_value(branch.mappings, fn
      %MapEntry{attribute: ^attribute, from: from} when is_atom(from) ->
        from

      %MapEntry{attribute: ^attribute, from: from} ->
        case Expr.simple_reference(from) do
          {:ok, attribute} -> attribute
          :error -> nil
        end

      _ ->
        nil
    end)
  end

  # With `security_definer` the trigger functions have an empty search_path: every relation is qualified.
  defp definer_problems(branch, true) do
    if String.contains?(Twin.relation(branch.twin), "."),
      do: [],
      else: ["`security_definer` needs #{inspect(branch.twin)} to declare a schema"]
  end

  defp definer_problems(_branch, false), do: []

  # A dual-write update SETs each legacy column once; two columns mapped from one cannot both be written.
  defp shared_source_problems(%{phase: :dual_write, mappings: mappings} = branch) do
    not_written = Info.not_written_back(branch)

    mappings
    |> Enum.filter(
      &(is_struct(&1, MapEntry) and is_atom(&1.from) and &1.attribute not in not_written)
    )
    |> Enum.group_by(& &1.from, & &1.attribute)
    |> Enum.flat_map(fn
      {from, [_, _ | _] = attributes} ->
        [
          "columns #{Enum.map_join(attributes, ", ", &inspect/1)} are all mapped from #{inspect(from)}, " <>
            "which a :dual_write update cannot set twice: map all but one with `from: expr(#{from})`"
        ]

      _ ->
        []
    end)
  end

  defp shared_source_problems(_branch), do: []

  defp missing(twin, columns, what) do
    attrs = Twin.columns(twin)

    for column <- columns,
        column not in attrs,
        do: "#{what} reads #{inspect(column)}, which #{inspect(twin)} does not have"
  end

  # Two branches may share a key namespace only when each names the other in `shares_key_with`:
  # the sharing is a claim about both branches' filters, so one side alone cannot make it.
  defp key_collisions(branches) do
    by_name = Map.new(branches, &{&1.name, &1})

    sharing_declaration_problems(branches, by_name) ++
      (branches
       |> Enum.filter(&Info.key_space/1)
       |> Enum.group_by(&Info.key_space/1)
       |> Map.values()
       |> Enum.flat_map(&undeclared_pairs/1))
  end

  defp sharing_declaration_problems(branches, by_name) do
    for b <- branches,
        problem <-
          dups(b.shares_key_with, "`shares_key_with` entry") ++
            Enum.flat_map(Enum.uniq(b.shares_key_with), &sharing_target_problem(b, &1, by_name)),
        do: "branch #{inspect(b.name)}: " <> problem
  end

  defp sharing_target_problem(%{name: name}, name, _by_name),
    do: ["`shares_key_with` names the branch itself"]

  defp sharing_target_problem(b, other, by_name) do
    case Map.fetch(by_name, other) do
      :error ->
        ["`shares_key_with` names #{inspect(other)}, which is not a legacy branch of this union"]

      {:ok, target} ->
        cond do
          is_nil(Info.key_space(b)) ->
            [
              "`shares_key_with` needs a `uuid_v5` or `uuid_v8` key: an `:identity` key has no namespace to share"
            ]

          Info.key_space(target) != Info.key_space(b) ->
            [
              "`shares_key_with` names #{inspect(other)}, whose key is in another namespace: " <>
                "the two share nothing, so drop the declaration"
            ]

          true ->
            []
        end
    end
  end

  defp undeclared_pairs(group) do
    sorted = Enum.sort_by(group, & &1.name)

    for {a, i} <- Enum.with_index(sorted),
        b <- Enum.drop(sorted, i + 1),
        problem <- pair_problem(a, b, b.name in a.shares_key_with, a.name in b.shares_key_with),
        do: problem
  end

  defp pair_problem(_a, _b, true, true), do: []

  defp pair_problem(a, b, true, false), do: [one_sided(a.name, b.name)]

  defp pair_problem(a, b, false, true), do: [one_sided(b.name, a.name)]

  defp pair_problem(a, b, false, false),
    do: [
      "branches #{inspect(a.name)}, #{inspect(b.name)} share a key namespace, so their ids can collide: " <>
        "give each its own namespace or kind, or, when their filters keep the same legacy entity " <>
        "in one branch at a time, declare `shares_key_with` on both"
    ]

  defp one_sided(declares, other),
    do:
      "branches #{inspect(declares)} and #{inspect(other)} share a key namespace, but only " <>
        "#{inspect(declares)} declares `shares_key_with: [#{inspect(other)}]`: " <>
        "declare `shares_key_with: [#{inspect(declares)}]` on #{inspect(other)} too, " <>
        "or give the branches their own namespaces"

  defp error(dsl, first, all) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:union],
      message: """
      #{first}

      All problems:
      #{Enum.map_join(all, "\n", &"  * #{&1}")}
      """
    )
  end
end
