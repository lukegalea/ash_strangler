# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyIdentitiesBacked do
  @moduledoc """
  Every Ash identity must be backed by a real uniqueness constraint on the legacy
  table.

  An identity Ash believes in but Postgres does not enforce is worse than no
  identity: Ash will use it to plan upserts and to report "has already been taken",
  while the database happily accepts duplicates. The failure is a duplicate row that
  no error was raised for.

  ## Where the constraint comes from now

  0.1 declared it in the `strangler` block:

      index "index_users_on_login", unique: true, columns: ["login"]

  — which restated something the database can be *asked about*, in a place nothing
  compared to the database. The `index` entity is gone. Uniqueness is an `identity`
  on the twin, and Ash already has that vocabulary:

      identities do
        identity :index_users_on_login, [:login]
      end

  This verifier compares the strangled resource's identities against the twin's,
  mapping attributes through the mapping to get from modern names to legacy columns.
  `mix ash_strangler.check` then compares the *twin's* identities against
  `pg_index`, which is the half a compile step cannot do — so the chain from "Ash
  believes this is unique" to "Postgres enforces it" is complete, with each link
  checked by whatever can actually check it.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Info, Lens, Twin}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if Info.strangled?(dsl) do
      twin = Info.twin(dsl)
      unique_columns = Twin.unique_column_sets(twin)
      column_for = column_lookup(dsl, twin)

      dsl
      |> Verifier.get_entities([:identities])
      |> verify_each(dsl, twin, column_for, unique_columns)
    else
      :ok
    end
  rescue
    # A stale or unusable twin is `VerifyTwin`'s finding, reported with the column
    # named and the regeneration command. Failing here as well would report the same
    # problem twice, in the less useful of the two places.
    _ -> :ok
  end

  defp verify_each(identities, dsl, twin, column_for, unique_columns) do
    Enum.reduce_while(identities, :ok, fn identity, :ok ->
      case check(identity, column_for, unique_columns) do
        :ok -> {:cont, :ok}
        {:error, error_for} -> {:halt, {:error, error_for.(dsl, twin)}}
      end
    end)
  end

  # Returns a function rather than the error itself so the check stays free of
  # the DSL state, which is only needed to name the module in the message.
  defp check(identity, column_for, unique_columns) do
    legacy = Enum.map(identity.keys, &Map.get(column_for, &1))

    cond do
      Enum.any?(legacy, &is_nil/1) ->
        {:error, &unmapped_error(&1, &2, identity)}

      MapSet.new(legacy) in unique_columns ->
        :ok

      true ->
        {:error, &unbacked_error(&1, &2, identity, legacy)}
    end
  end

  # Only mappings that resolve to one real column contribute: an identity can only
  # be enforced by the database if every key is a real column, and a computed
  # mapping cannot carry a unique constraint.
  defp column_lookup(dsl, twin) do
    dsl
    |> Lens.for_resource()
    |> Enum.filter(&(&1.combinator in [:rename, :cast, :zone, :key]))
    |> Enum.map(&{&1.attribute, legacy_column(twin, &1)})
    |> Enum.reject(fn {_attribute, column} -> is_nil(column) end)
    |> Map.new()
  end

  defp legacy_column(twin, %Lens{combinator: :key, entry: %{from: from}}),
    do: Twin.column!(twin, from)

  defp legacy_column(twin, %Lens{writes: [{column, _expression}]}), do: Twin.column!(twin, column)
  defp legacy_column(_twin, _lens), do: nil

  defp unmapped_error(dsl, _twin, identity) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:identities, identity.name],
      message: """
      Identity #{inspect(identity.name)} covers #{inspect(identity.keys)}, but at least one
      of those attributes is not mapped to a plain legacy column.

      An identity can only be enforced by the database if every key is a real
      column. A computed mapping cannot carry a unique constraint.
      """
    )
  end

  defp unbacked_error(dsl, twin, identity, legacy_columns) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:identities, identity.name],
      message: """
      Identity #{inspect(identity.name)} is not backed by a uniqueness constraint the twin declares.

      It maps to legacy columns #{inspect(legacy_columns)}, and no `identity` on
      #{inspect(twin)} covers those columns.

      Ash will use this identity to plan upserts and to report "has already been
      taken". If Postgres does not enforce it, duplicates are accepted with no
      error raised — which is worse than having no identity at all.

      If the constraint does exist on the legacy table, the twin is stale.
      Regenerate it rather than typing the identity in by hand — the generator reads
      `pg_index`, which is the only thing that actually knows:

          mix ash_strangler.gen.twin #{inspect(twin)}

      If it does not exist, either add it to the legacy table or remove the identity
      from this resource. Do not leave it unbacked.
      """
    )
  end
end
