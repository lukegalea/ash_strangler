# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Info do
  @moduledoc "Introspection for the `strangler` DSL section."

  use Spark.InfoGenerator, extension: AshStrangler.Resource, sections: [:strangler]

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

  @doc "Every `map` entry in the resource's source block."
  @spec mappings(Spark.Dsl.t() | Ash.Resource.t()) :: [AshStrangler.Map.t()]
  def mappings(resource), do: of_type(resource, AshStrangler.Map)

  @doc "Every `constant` entry."
  @spec constants(Spark.Dsl.t() | Ash.Resource.t()) :: [AshStrangler.Constant.t()]
  def constants(resource), do: of_type(resource, AshStrangler.Constant)

  @doc "Every `unmapped` declaration."
  @spec unmapped(Spark.Dsl.t() | Ash.Resource.t()) :: [AshStrangler.Unmapped.t()]
  def unmapped(resource), do: of_type(resource, AshStrangler.Unmapped)

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

  When `writes` is not set explicitly it is DERIVED from the mapping shape: a
  mapping that needs a computed value written back cannot rely on Postgres view
  auto-updatability, so it requires triggers.

  This matters because the two are not equivalent. Auto-updatable views keep
  upserts, correct `RETURNING` and `WITH CHECK OPTION`; `INSTEAD OF` triggers
  destroy all three and gain governance of every write. Choosing by accident is
  how a
  migration loses `ON CONFLICT` support without anyone deciding to.
  """
  @spec writes(Spark.Dsl.t() | Ash.Resource.t()) :: :auto | :triggers | nil
  def writes(resource) do
    case source(resource) do
      nil -> nil
      %{writes: declared} when declared in [:auto, :triggers] -> declared
      source -> derive_writes(source)
    end
  end

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

  defp derive_writes(source) do
    needs_triggers? =
      Enum.any?(source.mappings, fn
        %AshStrangler.Map{writable?: true, to: to} when is_binary(to) -> true
        _ -> false
      end)

    if needs_triggers?, do: :triggers, else: :auto
  end

  defp of_type(resource, struct_module) do
    case source(resource) do
      nil -> []
      source -> Enum.filter(source.mappings, &is_struct(&1, struct_module))
    end
  end
end
