# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.KeyKinds do
  @moduledoc """
  A registry of packed key kinds: invertible version 8 UUIDs for rows keyed by
  legacy integers.

      defmodule MyApp.Keys do
        use AshStrangler.KeyKinds

        key_kinds do
          estate 0x4C42
          snapshot "priv/legacy/snapshot/catalog.json"

          kind :member, 0x001, parts: [{"library.members.id", 32}]
          kind :copy, 0x002, parts: [{"library.copies.branch_id", 16}, {"library.copies.copy_no", 64}]
        end
      end

  A resource keyed by a kind declares

      key :id, from: :id, strategy: {:uuid_v8, MyApp.Keys, :member}

  and an attribute holding another kind's id declares

      reference :member_id, kind: {MyApp.Keys, :member}, from: :member_id

  ## Why packed rather than hashed

  A `{:uuid_v5, ...}` key is a one-way hash, so the legacy integer has to be
  kept somewhere to get back to the row, and a foreign key between two strangled
  resources has to be re-derived through the same hash with nothing checking
  that it was. A packed key is a bijection: `decode/2` recovers the integers,
  the SQL printer (`to_sql/3`) and the Elixir function (`encode/3`) are two
  prints of one definition, and a reference is closed by construction when a
  validated foreign key in the snapshot backs it.

  Packed ids reveal the legacy integers. Nothing may treat them as secret.

  ## What is verified at compile time

  `AshStrangler.Verifiers.VerifyKeyKinds`: tags are unique, within `1..0xFFF`
  and not reserved; widths sum to at most 94 bits; with a `snapshot`, every
  part is a `NOT NULL` integer column no wider than its declared width.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshStrangler.KeyKinds.Dsl]]

  alias AshStrangler.{KeyKind, UuidV8}
  alias Spark.Dsl.Extension

  @typedoc "A registry module defined with `use AshStrangler.KeyKinds`."
  @type registry :: module()

  @doc "The registry's estate tag."
  @spec estate(registry() | Spark.Dsl.t()) :: non_neg_integer()
  def estate(registry), do: Extension.get_opt(registry, [:key_kinds], :estate)

  @doc "The snapshot catalog the registry is checked against, or `nil`."
  @spec snapshot(registry() | Spark.Dsl.t()) :: String.t() | nil
  def snapshot(registry), do: Extension.get_opt(registry, [:key_kinds], :snapshot, nil)

  @doc "The reserved tags."
  @spec reserved(registry() | Spark.Dsl.t()) :: [pos_integer()]
  def reserved(registry), do: Extension.get_opt(registry, [:key_kinds], :reserved, [])

  @doc "Every kind, in declaration order."
  @spec kinds(registry() | Spark.Dsl.t()) :: [KeyKind.t()]
  def kinds(registry), do: Extension.get_entities(registry, [:key_kinds])

  @doc "The kind named `name`, or `nil`."
  @spec kind(registry() | Spark.Dsl.t(), atom()) :: KeyKind.t() | nil
  def kind(registry, name), do: Enum.find(kinds(registry), &(&1.name == name))

  @doc "The kind named `name`; raises `ArgumentError` when the registry has none."
  @spec kind!(registry(), atom()) :: KeyKind.t()
  def kind!(registry, name) do
    kind(registry, name) ||
      raise ArgumentError,
            "#{inspect(registry)} declares no key kind #{inspect(name)}; it declares " <>
              inspect(Enum.map(kinds(registry), & &1.name))
  end

  @doc "True when `module` is a compiled key-kind registry."
  @spec registry?(term()) :: boolean()
  def registry?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      AshStrangler.KeyKinds.Dsl in Spark.extensions(module)
  end

  def registry?(_other), do: false

  @doc """
  The id of the `name` row whose packed columns hold `parts`. `nil` when any
  part is `nil`.

  Raises `ArgumentError` when a part does not fit its width.
  """
  @spec encode(registry(), atom(), [integer() | nil]) :: String.t() | nil
  def encode(registry, name, parts) do
    kind = kind!(registry, name)
    UuidV8.encode(estate(registry), kind.tag, KeyKind.widths(kind), parts)
  end

  @doc """
  The kind and parts packed in `uuid`, or `:error` when it is not a key of any
  kind in this registry.
  """
  @spec decode(registry(), String.t()) :: {:ok, {atom(), [integer()]}} | :error
  def decode(registry, uuid) do
    estate = estate(registry)

    with {:ok, {^estate, tag, payload}} <- UuidV8.split(uuid),
         %KeyKind{} = kind <- Enum.find(kinds(registry), &(&1.tag == tag)),
         {:ok, parts} <- UuidV8.unpack(payload, KeyKind.widths(kind)) do
      {:ok, {kind.name, parts}}
    else
      _ -> :error
    end
  end

  @doc "The parts packed in `uuid`, or `:error` when it is not a `name` key."
  @spec decode(registry(), atom(), String.t()) :: {:ok, [integer()]} | :error
  def decode(registry, name, uuid) do
    kind = kind!(registry, name)
    UuidV8.decode(estate(registry), kind.tag, KeyKind.widths(kind), uuid)
  end

  @doc """
  The SQL expression (type `uuid`) of a `name` key over `part_sql`, one SQL
  expression per part. Agrees with `encode/3`.
  """
  @spec to_sql(registry() | Spark.Dsl.t(), atom(), [String.t()]) :: String.t()
  def to_sql(registry, name, part_sql) do
    kind = kind!(registry, name)
    UuidV8.sql(estate(registry), kind.tag, KeyKind.widths(kind), part_sql)
  end

  @doc """
  The SQL expression for part `index` of the `name` key `uuid_sql` evaluates
  to. Agrees with `decode/3`, and fails rather than decoding a key of another
  kind.
  """
  @spec part_sql(registry(), atom(), non_neg_integer(), String.t()) :: String.t()
  def part_sql(registry, name, index, uuid_sql) do
    kind = kind!(registry, name)
    UuidV8.part_sql(estate(registry), kind.tag, KeyKind.widths(kind), index, uuid_sql)
  end
end
