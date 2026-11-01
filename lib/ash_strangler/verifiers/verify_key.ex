# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyKey do
  @moduledoc """
  V-KEY: a key strategy holds only when the legacy columns make it hold.

  For a packed key, `key :id, from: ..., strategy: {:uuid_v8, Registry, :kind}`:

    * the registry is a compiled `AshStrangler.KeyKinds` module declaring the
      kind, and `from` names as many columns as the kind has parts;
    * the twin is pinned to a snapshot, because the part widths are checked
      against the catalog's column types;
    * `from` is exactly the kind's columns, on the kind's relation: a kind
      identifies the rows of one relation, so keying another relation with it
      would give two resources one id space;
    * each column is a `NOT NULL` integer no wider than its part;
    * the columns hold a non-partial unique key (the primary key or a unique
      index with no `WHERE`).

  For an `:identity` key on a pinned twin, the column is a `NOT NULL` `uuid`
  that is the primary key or a non-partial unique index on its own.

  A composite `from` needs a packed strategy (only a packed key decodes back to
  more than one column), and for now stays in `:read_from_legacy` with no
  `notify?` or `ledger?`: triggers, the change ledger, notifications and the
  backfill locate a legacy row by a single `__legacy_id`, and a composite key
  has none.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Info, Key, KeyKind}
  alias AshStrangler.Verifiers.KeyCatalog
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    with %{} = source <- Info.source(dsl),
         %Key{} = key <- Info.key(dsl) do
      case problems(dsl, source, key) do
        [] -> :ok
        problems -> {:error, error(dsl, key, problems)}
      end
    else
      _ -> :ok
    end
  end

  defp problems(dsl, source, %Key{strategy: {:uuid_v8, registry, name}} = key) do
    with {:ok, kind} <- KeyCatalog.kind(registry, name),
         [] <- arity_problems(key, kind),
         [] <- composite_problems(dsl, source, key),
         {:ok, catalog_relation} <- pinned(source.twin),
         {:ok, columns} <- columns(source.twin, key) do
      home_problems(source.twin, columns, kind) ++
        KeyCatalog.width_problems(catalog_relation, columns, kind, true) ++
        unique_problems(catalog_relation, columns)
    else
      {:error, message} -> [message]
      problems when is_list(problems) -> problems
    end
  end

  defp problems(_dsl, source, %Key{strategy: :identity} = key) do
    if Key.composite?(key) do
      [composite_strategy()]
    else
      case KeyCatalog.relation(source.twin) do
        {:ok, _catalog, relation} -> identity_problems(source.twin, relation, key)
        :unpinned -> []
        {:error, message} -> [message]
      end
    end
  end

  defp problems(_dsl, _source, key) do
    if Key.composite?(key), do: [composite_strategy()], else: []
  end

  defp composite_strategy,
    do: "a composite `from` needs a packed strategy, `{:uuid_v8, Registry, :kind}`"

  defp arity_problems(key, kind) do
    if length(Key.columns(key)) == length(kind.parts) do
      []
    else
      [
        "`from` names #{length(Key.columns(key))} column(s); kind #{inspect(kind.name)} " <>
          "packs #{length(kind.parts)}"
      ]
    end
  end

  defp composite_problems(dsl, source, key) do
    phase = Info.strangler_phase!(dsl)

    cond do
      not Key.composite?(key) ->
        []

      phase != :read_from_legacy ->
        [
          "a composite key is read-only for now, so the resource stays in :read_from_legacy " <>
            "(it is in #{inspect(phase)}): the write triggers locate a row by one legacy column"
        ]

      source.notify? or source.ledger? ->
        [
          "a composite key cannot carry `notify?` or `ledger?` yet: their payloads name one " <>
            "legacy key column. Watch the twin instead (`twin do watch \"channel\" end`)"
        ]

      true ->
        []
    end
  end

  defp pinned(twin) do
    case KeyCatalog.relation(twin) do
      {:ok, _catalog, relation} ->
        {:ok, relation}

      :unpinned ->
        {:error,
         "#{inspect(twin)} is not pinned to a snapshot, so the part widths cannot be checked; " <>
           "declare `twin do snapshot \"…/catalog.json\" end`"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp columns(twin, key) do
    case KeyCatalog.columns(twin, Key.columns(key)) do
      {:ok, columns} -> {:ok, columns}
      {:error, attribute} -> {:error, "#{inspect(twin)} has no attribute #{inspect(attribute)}"}
    end
  end

  defp home_problems(twin, columns, kind) do
    relation = KeyCatalog.relation_name(twin)
    home = KeyKind.columns(kind)

    if home == Enum.map(columns, &{relation, &1}) do
      []
    else
      [
        "kind #{inspect(kind.name)} packs #{format_columns(home)}, but this key reads " <>
          "#{format_columns(Enum.map(columns, &{relation, &1}))}. A kind identifies the rows of " <>
          "one relation; key this relation with its own kind"
      ]
    end
  end

  defp unique_problems(relation, columns) do
    if KeyCatalog.unique?(relation, columns) do
      []
    else
      [
        "#{inspect(columns)} hold no primary key or non-partial unique index in the snapshot, " <>
          "so two legacy rows could pack to one id"
      ]
    end
  end

  defp identity_problems(twin, relation, key) do
    with {:ok, [name]} <- columns(twin, key),
         %{} = column <- KeyCatalog.column(relation, name) do
      Enum.reject(
        [
          column["udt"] != "pg_catalog.uuid" &&
            "`#{name}` is #{column["type"]}; an :identity key passes a uuid through, so it must be uuid",
          not column["not_null"] && "`#{name}` is nullable; a key must be NOT NULL",
          not KeyCatalog.unique?(relation, [name]) &&
            "`#{name}` is not the primary key or a non-partial unique index on its own"
        ],
        &(&1 == false)
      )
    else
      {:error, message} -> [message]
      nil -> ["the snapshot relation has no column for the key"]
    end
  end

  defp format_columns(columns),
    do: Enum.map_join(columns, ", ", fn {relation, column} -> "`#{relation}.#{column}`" end)

  defp error(dsl, key, problems) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :key, key.attribute],
      message: """
      `key #{inspect(key.attribute)}, from: #{inspect(key.from)}, strategy: #{inspect(key.strategy)}` \
      does not hold:

      #{Enum.map_join(problems, "\n", &"  * #{&1}")}
      """
    )
  end
end
