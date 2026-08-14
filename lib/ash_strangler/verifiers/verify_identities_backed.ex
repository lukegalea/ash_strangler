defmodule AshStrangler.Verifiers.VerifyIdentitiesBacked do
  @moduledoc """
  Every Ash identity must be backed by a real uniqueness constraint on the
  legacy table.

  An identity Ash believes in but Postgres does not enforce is worse than no
  identity: Ash will use it to plan upserts and to report "has already been
  taken", while the database happily accepts duplicates. The failure is a
  duplicate row that no error was raised for.

  The legacy table's constraints are declared with `index ... unique: true`,
  because this extension does not own that table and cannot add them.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if AshStrangler.Info.strangled?(dsl) do
      source = AshStrangler.Info.source(dsl)
      unique_columns = unique_column_sets(source)
      column_for = column_lookup(source)

      dsl
      |> Verifier.get_entities([:identities])
      |> verify_each(dsl, column_for, unique_columns)
    else
      :ok
    end
  end

  defp verify_each(identities, dsl, column_for, unique_columns) do
    Enum.reduce_while(identities, :ok, fn identity, :ok ->
      case check(identity, column_for, unique_columns) do
        :ok -> {:cont, :ok}
        {:error, error_for} -> {:halt, {:error, error_for.(dsl)}}
      end
    end)
  end

  # Returns a function rather than the error itself so the check stays free of
  # the DSL state, which is only needed to name the module in the message.
  defp check(identity, column_for, unique_columns) do
    legacy = Enum.map(identity.keys, &Map.get(column_for, &1))

    cond do
      Enum.any?(legacy, &is_nil/1) ->
        {:error, &unmapped_error(&1, identity)}

      MapSet.new(legacy) in unique_columns ->
        :ok

      true ->
        {:error, &unbacked_error(&1, identity, legacy)}
    end
  end

  defp unique_column_sets(source) do
    for index <- source.indexes, index.unique, into: MapSet.new() do
      MapSet.new(index.columns)
    end
  end

  defp column_lookup(source) do
    for %AshStrangler.Map{attribute: attribute, column: column} <- source.mappings,
        is_binary(column),
        into: %{} do
      {attribute, column}
    end
  end

  defp unmapped_error(dsl, identity) do
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

  defp unbacked_error(dsl, identity, legacy_columns) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:identities, identity.name],
      message: """
      Identity #{inspect(identity.name)} is not backed by a declared unique index.

      It maps to legacy columns #{inspect(legacy_columns)}, and no `index` in the
      strangler source declares those columns unique.

      Ash will use this identity to plan upserts and to report "has already been
      taken". If Postgres does not enforce it, duplicates are accepted with no
      error raised — which is worse than having no identity at all.

      If the constraint does exist, declare it:

          index "the_real_index_name", unique: true, columns: #{inspect(legacy_columns)}

      If it does not exist, either add it to the legacy table or remove the
      identity. Do not leave it undeclared.
      """
    )
  end
end
