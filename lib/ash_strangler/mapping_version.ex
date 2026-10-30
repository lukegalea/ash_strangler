# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.MappingVersion do
  @moduledoc """
  A content hash of a resource's whole mapping — the observation envelope's
  `mapping_version`.

  The projector stamps every observation with the version of the mapping that
  produced it, so a consumer can tell "the row changed" from "the MEANING of
  the row changed". Two observations carrying different versions are not
  comparable value-for-value: the mapping between them moved, and the
  consumer re-baselines instead of diffing.

  The hash is over the CANONICAL form: every collection that has no semantic
  order is sorted (mappings by attribute, extension attributes, source
  options), and every declaration-order collection keeps its order (a
  collapse's clauses — first-match precedence IS the meaning). Structurally
  identical mappings hash equal regardless of declaration site: the same
  mapping inline and in a fragment are one mapping, and one version.

  SHA-256 over `:erlang.term_to_binary/2` with `deterministic: true` (OTP 27
  sorts map keys), hex-encoded: 64 characters, stable across runs and nodes.
  """

  alias AshStrangler.Info

  @doc """
  The 64-character hex hash of `resource`'s mapping.
  """
  @spec hash(Ash.Resource.t()) :: String.t()
  def hash(resource) do
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical(resource), [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # The canonical form. `__spark_metadata__` is stripped everywhere — file
  # and line are where a declaration was WRITTEN, not what it means, and the
  # same mapping declared in a fragment must hash equal to the inline one.
  defp canonical(resource) do
    source = Info.source(resource)

    {
      Info.strangler_phase!(resource),
      # source options, sorted: twin, write mechanism, channels, flags
      source
      |> Map.from_struct()
      |> Map.drop([:__spark_metadata__, :mappings, :extensions, :tenants, :keys])
      |> Enum.sort(),
      # the key: strategy and columns
      canonical_entity(Info.key(resource)),
      Enum.sort(Info.extension_attrs(resource)),
      canonical_entity(Info.tenant(resource)),
      # mappings, sorted by the attribute they produce (an `unmapped [:a, b]`
      # sorts under its first attribute), each canonicalised
      source.mappings
      |> Enum.sort_by(&mapping_sort_key/1)
      |> Enum.map(&canonical_entity/1)
    }
  end

  defp mapping_sort_key(%{attribute: attribute}) when not is_nil(attribute), do: attribute
  defp mapping_sort_key(%{attributes: [first | _]}), do: first
  defp mapping_sort_key(_entity), do: nil

  # One entity → {struct name, sorted field/value pairs}, with the Spark
  # metadata stripped and nested structures cleaned recursively: a collapse's
  # states keep their ORDER (first-match precedence is the meaning) but lose
  # their metadata.
  defp canonical_entity(nil), do: nil

  defp canonical_entity(entity) do
    {entity.__struct__, clean(Map.from_struct(entity))}
  end

  defp clean(%struct{} = value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__spark_metadata__])
    |> Map.new(fn {k, v} -> {k, clean(v)} end)
    |> then(&{struct, &1})
  end

  defp clean(list) when is_list(list), do: Enum.map(list, &clean/1)
  defp clean(%{} = map), do: Map.new(map, fn {k, v} -> {k, clean(v)} end)
  defp clean(other), do: other
end
