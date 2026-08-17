# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Info do
  @moduledoc "Introspection for the `strangler` DSL section."

  use Spark.InfoGenerator, extension: AshStrangler.Resource, sections: [:strangler]

  alias AshStrangler.{Lens, Mechanism, Twin}

  @doc "The resource's `source` block, or `nil` when it has no strangler mapping."
  @spec source(Spark.Dsl.t() | Ash.Resource.t()) :: AshStrangler.Source.t() | nil
  def source(resource) do
    resource
    |> Spark.Dsl.Extension.get_entities([:strangler])
    |> Enum.find(&is_struct(&1, AshStrangler.Source))
  end

  @doc "True when the resource carries a strangler mapping at all."
  @spec strangled?(Spark.Dsl.t() | Ash.Resource.t()) :: boolean()
  def strangled?(resource), do: not is_nil(source(resource))

  @doc "The twin module the resource is mapped onto, or `nil`."
  @spec twin(Spark.Dsl.t() | Ash.Resource.t()) :: Ash.Resource.t() | nil
  def twin(resource) do
    case source(resource) do
      %{twin: twin} -> twin
      _ -> nil
    end
  end

  @doc """
  The legacy relation, schema-qualified — read off the twin rather than typed.

  0.1 took this as a `"legacy.users"` string in `source`, which meant the relation
  name and the twin's `postgres do table/schema end` were two places one fact
  could be written. Now there is one.
  """
  @spec relation(Spark.Dsl.t() | Ash.Resource.t()) :: String.t() | nil
  def relation(resource) do
    case twin(resource) do
      nil -> nil
      twin -> Twin.relation(twin)
    end
  end

  @doc """
  The alias the primary relation's columns are qualified by, which is the twin's
  bare table name.
  """
  @spec primary_alias(Spark.Dsl.t() | Ash.Resource.t()) :: String.t() | nil
  def primary_alias(resource) do
    case twin(resource) do
      nil -> nil
      twin -> Twin.table!(twin)
    end
  end

  @doc "Every mapping entity in the resource's source block, in declaration order."
  @spec mappings(Spark.Dsl.t() | Ash.Resource.t()) :: [struct()]
  def mappings(resource) do
    case source(resource) do
      nil -> []
      source -> source.mappings
    end
  end

  @doc "Every `constant` entry."
  @spec constants(Spark.Dsl.t() | Ash.Resource.t()) :: [AshStrangler.Constant.t()]
  def constants(resource), do: of_type(resource, AshStrangler.Constant)

  @doc "Every `unmapped` declaration."
  @spec unmapped(Spark.Dsl.t() | Ash.Resource.t()) :: [AshStrangler.Unmapped.t()]
  def unmapped(resource), do: of_type(resource, AshStrangler.Unmapped)

  @doc """
  The resource's single `key`, or `nil`.

  Raises when there are several: a view has one primary key expression, and
  "several keys" has no meaning that is not just a bug in the declaration.
  """
  @spec key(Spark.Dsl.t() | Ash.Resource.t()) :: AshStrangler.Key.t() | nil
  def key(resource) do
    case source(resource) do
      nil ->
        nil

      %{keys: []} ->
        nil

      %{keys: [key]} ->
        key

      %{keys: keys} ->
        raise ArgumentError,
              "#{inspect(resource)}'s source declares #{length(keys)} keys; only one is supported"
    end
  end

  @doc """
  Attribute names the mapping accounts for: mapped, constant, unmapped or the key.

  This is the set `VerifyCompleteMapping` compares against the resource's real
  attributes.
  """
  @spec accounted_for(Spark.Dsl.t() | Ash.Resource.t()) :: MapSet.t(atom())
  def accounted_for(resource) do
    case source(resource) do
      nil ->
        MapSet.new()

      source ->
        mapped = for m <- source.mappings, Map.has_key?(m, :attribute), do: m.attribute
        unmapped = for u <- source.mappings, is_struct(u, AshStrangler.Unmapped), do: u.attributes
        keys = for k <- source.keys, do: k.attribute

        MapSet.new(mapped ++ List.flatten(unmapped) ++ keys)
    end
  end

  @doc """
  How writes reach the base table, resolved rather than merely declared.

  When `writes` is not set explicitly it is **derived** — by
  `AshStrangler.Mechanism`, per column, which is the change that makes most
  mappings need no `INSTEAD OF` trigger at all. The old rule was "any writable
  computed mapping forces triggers for the whole resource", and PostgreSQL does not
  require that: `CREATE VIEW`'s updatability rule is per column, so a view may hold
  a mix of plain and computed columns and stay auto-updatable.

  This still matters as much as it did, in the same direction. Auto-updatable views
  keep upserts, correct `RETURNING` and `WITH CHECK OPTION`; `INSTEAD OF` triggers
  destroy all three and gain governance of every write. Choosing by accident is how
  a migration loses `ON CONFLICT` support without anyone deciding to. The
  difference is that it is now chosen much less often.
  """
  @spec writes(Spark.Dsl.t() | Ash.Resource.t()) :: :auto | :triggers | nil
  def writes(resource) do
    case source(resource) do
      nil ->
        nil

      %{writes: declared} when declared in [:auto, :triggers] ->
        declared

      _source ->
        if Mechanism.resource_mechanism(resource) == :instead_of, do: :triggers, else: :auto
    end
  end

  @doc """
  What an `INSTEAD OF UPDATE` trigger writes back — see the `on_update` option.

  A documented choice rather than a generator detail, because PostgreSQL makes the
  distinction undetectable: `INSTEAD OF UPDATE` forbids a column list and forbids
  `WHEN`, and `NEW` arrives fully populated from the view row.
  """
  @spec on_update(Spark.Dsl.t() | Ash.Resource.t()) :: :full_row | :changed_columns
  def on_update(resource) do
    case source(resource) do
      %{on_update: on_update} -> on_update
      _ -> :full_row
    end
  end

  @doc """
  True when the `INSTEAD OF` triggers should clear the backfill flag on every row
  they write — pgroll's interlock.

  See the `backfill_interlock?` option for why this is declared rather than
  inferred from whether the twin has the column.
  """
  @spec backfill_interlock?(Spark.Dsl.t() | Ash.Resource.t()) :: boolean()
  def backfill_interlock?(resource),
    do: match?(%{backfill_interlock?: true}, source(resource))

  @default_notify_channel "ash_strangler"

  @doc """
  The `pg_notify` channel this resource announces on.

  One channel serves every resource by default, with the resource named in the
  payload, because Postgres caps a channel name at 63 bytes and a
  channel-per-resource would make a listener's `LISTEN` set grow with the
  schema.
  """
  @spec notify_channel(Spark.Dsl.t() | Ash.Resource.t()) :: String.t()
  def notify_channel(resource) do
    case source(resource) do
      %{notify_channel: channel} when is_binary(channel) -> channel
      _ -> @default_notify_channel
    end
  end

  @doc "The default channel, for a listener with no resource in hand yet."
  @spec default_notify_channel() :: String.t()
  def default_notify_channel, do: @default_notify_channel

  @doc "True when the resource opted into `pg_notify` announcements."
  @spec notify?(Spark.Dsl.t() | Ash.Resource.t()) :: boolean()
  def notify?(resource), do: match?(%{notify?: true}, source(resource))

  @doc """
  Every relationship path any mapping reads through, and the joins each needs.

  0.1 declared joins explicitly, with a relation name, an alias and an `on:`
  predicate written as raw SQL. They are now *discovered*: a mapping reading
  `expr(address.city)` says which relation it came from by naming it, and the join
  condition comes off the relationship. So the fan-out is a property of a declared
  relationship rather than of an opaque predicate, and a cross join — a join with
  no condition, which multiplies every row by every row and is never what anyone
  meant — is not expressible.
  """
  @spec joins(Spark.Dsl.t() | Ash.Resource.t()) :: [
          %{relation: String.t(), alias: String.t(), on: String.t(), relationship: term()}
        ]
  def joins(resource) do
    case twin(resource) do
      nil ->
        []

      twin ->
        resource
        |> Lens.for_resource()
        |> Enum.flat_map(& &1.sources)
        |> Enum.map(fn {path, _attribute} -> path end)
        |> Enum.reject(&(&1 == []))
        |> Enum.uniq()
        |> Enum.flat_map(fn path ->
          case Twin.joins_for(twin, path) do
            {:ok, joins} -> joins
            # A path that does not resolve is `VerifyTwin`'s finding, reported with
            # the reference named. Swallowing it here keeps a diagram drawable for a
            # resource that is already failing to compile.
            {:error, _} -> []
          end
        end)
        |> Enum.uniq_by(& &1.alias)
    end
  end

  @doc "The aliases every joined relation is referenced by."
  @spec join_aliases(Spark.Dsl.t() | Ash.Resource.t()) :: [String.t()]
  def join_aliases(resource), do: resource |> joins() |> Enum.map(& &1.alias)

  defp of_type(resource, struct_module) do
    case source(resource) do
      nil -> []
      source -> Enum.filter(source.mappings, &is_struct(&1, struct_module))
    end
  end
end
