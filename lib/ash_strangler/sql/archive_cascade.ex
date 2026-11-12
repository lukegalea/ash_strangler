# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.ArchiveCascade do
  @moduledoc """
  What `AshArchival`'s `archive_related` cascade means to a legacy `DELETE` at
  `:read_from_new`, decided once: the plan the reverse `INSTEAD OF DELETE`
  renders, or the reason a trigger cannot follow it.

  `AshArchival` cascades in Ash: after a destroy archives a row, it reads each
  relationship listed in `archive_related` through the destination's archive
  filter and runs the destination's primary destroy over what it finds, which
  archives those rows and recurses through the destination's own
  `archive_related`. `AshStrangler.Sql.ReverseTriggers` does the same work in
  the `DELETE`'s own statement, one data-modifying CTE per relationship, each
  stamping the destination's archive column on the not-yet-archived rows
  related to the rows the CTE before it archived.

  That is faithful only for a relationship a foreign-key comparison describes
  and a destination whose archive is a column stamp in the same database.
  `plan/1` walks the graph from the resource, depth first in declared order,
  and refuses the first relationship that is not:

    * a relationship that does not exist, or is `many_to_many`, `manual`,
      `no_attributes?`, carries a `filter`, or is a `has_one` with
      `from_many?`: which rows it relates is something only Ash can compute;
    * a destination outside `AshPostgres.DataLayer`, in another repo, with no
      table, with `:context` multitenancy, or temporal;
    * a destination strangled at `:read_from_legacy` or `:dual_write`, whose
      table is still the compatibility view over the legacy table: the cascade's
      `UPDATE` would land on the legacy table through that view (read-only, or
      through the destination's own dual-write `INSTEAD OF UPDATE` trigger),
      not on an owned table. The cascade can follow it once that resource
      reaches `:read_from_new`;
    * a destination that does not use `AshArchival.Resource`, or whose primary
      destroy action does not archive (there is none, or it is listed in
      `exclude_destroy_actions`): `AshArchival` would destroy those rows;
    * a resource on the path that sets `archive_related_arguments`, arguments
      the SQL has no way to pass;
    * a cycle: one statement cannot update the same row twice, and a cycle is
      a cascade of unbounded depth.

  `AshStrangler.Verifiers.VerifyArchiveRelated` reports the refusal at compile
  time; `ReverseTriggers` raises the same message if it is asked to build one.
  """

  alias AshStrangler.Info
  alias AshStrangler.Sql.ReverseView

  @typedoc """
  One relationship the cascade follows. The columns are quoted for SQL:
  `source_column` is read from the rows the parent step archived and compared
  with `destination_column`; `archive_column` is the destination's archive
  attribute, honouring `source:`.
  """
  @type step :: %{
          source: Ash.Resource.t(),
          relationship: atom(),
          destination: Ash.Resource.t(),
          relation: String.t(),
          archive_column: String.t(),
          source_column: String.t(),
          destination_column: String.t(),
          cascade: [step()]
        }

  @typedoc "The relationship a trigger cannot follow, where it was reached, and why."
  @type refusal :: %{
          root: Ash.Resource.t(),
          resource: Ash.Resource.t(),
          relationship: atom(),
          path: [{Ash.Resource.t(), atom()}],
          reason: String.t()
        }

  @doc """
  The cascade a legacy `DELETE` of `resource` runs, as `{:ok, steps}` (`[]`
  when it archives nothing related), or `{:error, refusal}`.

  `resource` must archive (`AshStrangler.Sql.ReverseTriggers.archive_column/1`).
  """
  @spec plan(Ash.Resource.t()) :: {:ok, [step()]} | {:error, refusal()}
  def plan(resource) do
    steps(resource, %{root: resource, repo: repo(resource), on_path: [resource], path: []})
  end

  @doc "The message a refusal is reported with, naming the resource, relationship and reason."
  @spec message(refusal()) :: String.t()
  def message(refusal) do
    via =
      case refusal.path do
        [] ->
          ""

        path ->
          trail =
            Enum.map_join(path ++ [{refusal.resource, refusal.relationship}], " -> ", fn
              {source, name} -> "#{inspect(source)} #{inspect(name)}"
            end)

          "\nThe cascade reaches it from #{inspect(refusal.root)}: #{trail}.\n"
      end

    """
    #{inspect(refusal.resource)} cannot cascade archive_related #{inspect(refusal.relationship)} \
    on a legacy DELETE at :read_from_new: #{refusal.reason}.
    #{via}
    A legacy DELETE through the reverse view archives the owned row and, in the \
    same statement, the rows AshArchival's archive_related would archive. A \
    trigger can only do that for a relationship a foreign key describes and a \
    destination whose archive is a column in the same database. Remove the \
    relationship from archive_related, or change it so that it is one.
    """
  end

  # --- the walk -----------------------------------------------------------------

  defp steps(source, walk) do
    related = AshArchival.Resource.Info.archive_archive_related!(source)

    with :ok <- check_arguments(source, related, walk) do
      Enum.reduce_while(related, {:ok, []}, fn name, {:ok, acc} ->
        case step(source, name, walk) do
          {:ok, step} -> {:cont, {:ok, [step | acc]}}
          {:error, refusal} -> {:halt, {:error, refusal}}
        end
      end)
      |> case do
        {:ok, steps} -> {:ok, Enum.reverse(steps)}
        error -> error
      end
    end
  end

  defp step(source, name, walk) do
    relationship = Ash.Resource.Info.relationship(source, name)

    with :ok <- check_relationship(source, relationship),
         destination = relationship.destination,
         :ok <- check_destination(destination, walk.repo),
         :ok <- check_cycle(destination, walk),
         {:ok, cascade} <- steps(destination, descend(walk, {source, name}, destination)) do
      {:ok,
       %{
         source: source,
         relationship: name,
         destination: destination,
         relation: ReverseView.owned_relation(destination),
         archive_column:
           ReverseView.owned_column(
             destination,
             AshArchival.Resource.Info.archive_attribute!(destination)
           ),
         source_column: ReverseView.owned_column(source, relationship.source_attribute),
         destination_column:
           ReverseView.owned_column(destination, relationship.destination_attribute),
         cascade: cascade
       }}
    else
      {:error, reason} when is_binary(reason) ->
        {:error,
         %{root: walk.root, resource: source, relationship: name, path: walk.path, reason: reason}}

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  defp descend(walk, edge, destination),
    do: %{walk | on_path: [destination | walk.on_path], path: walk.path ++ [edge]}

  # --- the checks, one place for every level ------------------------------------

  defp check_arguments(_source, [], _walk), do: :ok

  defp check_arguments(source, [first | _], walk) do
    case AshArchival.Resource.Info.archive_archive_related_arguments(source) do
      {:ok, _function} ->
        {:error,
         %{
           root: walk.root,
           resource: source,
           relationship: first,
           path: walk.path,
           reason:
             "#{inspect(source)} sets archive_related_arguments, and a trigger has no " <>
               "destroy arguments to pass along"
         }}

      _ ->
        :ok
    end
  end

  defp check_relationship(source, nil),
    do: {:error, "it is not a relationship of #{inspect(source)}"}

  defp check_relationship(_source, %{type: :many_to_many}),
    do:
      {:error,
       "it is a many_to_many relationship, whose rows are found through a join resource " <>
         "rather than one foreign key"}

  defp check_relationship(_source, %{manual: manual}) when not is_nil(manual),
    do: {:error, "it is a manual relationship, whose rows only its Elixir code can find"}

  defp check_relationship(_source, %{no_attributes?: true}),
    do: {:error, "it is a no_attributes? relationship, which has no foreign key to follow"}

  defp check_relationship(_source, %{filter: filter}) when not is_nil(filter),
    do: {:error, "it has a filter, which is an Ash expression a trigger does not evaluate"}

  defp check_relationship(_source, %{type: :has_one, from_many?: true}),
    do: {:error, "it is a has_one with from_many?, and only Ash picks which one of many rows"}

  defp check_relationship(_source, _relationship), do: :ok

  defp check_destination(destination, repo) do
    cond do
      Ash.DataLayer.data_layer(destination) != AshPostgres.DataLayer ->
        {:error,
         "the destination #{inspect(destination)} is in " <>
           "#{inspect(Ash.DataLayer.data_layer(destination))}, not AshPostgres.DataLayer"}

      repo(destination) != repo ->
        {:error,
         "the destination #{inspect(destination)} is in #{inspect(repo(destination))}, not " <>
           "#{inspect(repo)}, and one statement cannot write to another database"}

      is_nil(AshPostgres.DataLayer.Info.table(destination)) ->
        {:error, "the destination #{inspect(destination)} has no table to update"}

      Ash.Resource.Info.multitenancy_strategy(destination) == :context ->
        {:error,
         "the destination #{inspect(destination)} uses :context multitenancy, so its rows are " <>
           "in a schema per tenant and the trigger does not know the tenant"}

      Ash.Resource.Info.temporal?(destination) ->
        {:error,
         "the destination #{inspect(destination)} is temporal, where an archive closes a " <>
           "version, which a stamp in place would rewrite"}

      Info.strangled?(destination) and
          Info.strangler_phase!(destination) in [:read_from_legacy, :dual_write] ->
        {:error,
         "the destination #{inspect(destination)} is strangled at " <>
           "#{inspect(Info.strangler_phase!(destination))}, so its table is still the " <>
           "compatibility view over the legacy table; the cascade can follow it once it " <>
           "reaches :read_from_new"}

      true ->
        check_archives(destination)
    end
  end

  defp check_archives(destination) do
    cond do
      AshArchival.Resource not in Spark.extensions(destination) ->
        {:error,
         "the destination #{inspect(destination)} does not use AshArchival.Resource, so " <>
           "AshArchival would destroy its rows rather than archive them"}

      is_nil(
        Ash.Resource.Info.attribute(
          destination,
          AshArchival.Resource.Info.archive_attribute!(destination)
        )
      ) ->
        {:error, "the destination #{inspect(destination)} has no archive attribute"}

      true ->
        check_primary_destroy(destination)
    end
  end

  # AshArchival's cascade runs the destination's primary destroy action.
  defp check_primary_destroy(destination) do
    excluded = AshArchival.Resource.Info.archive_exclude_destroy_actions!(destination)

    case Ash.Resource.Info.primary_action(destination, :destroy) do
      nil ->
        {:error,
         "the destination #{inspect(destination)} has no primary destroy action for " <>
           "AshArchival's cascade to run"}

      %{name: name} ->
        if name in excluded do
          {:error,
           "the destination #{inspect(destination)}'s primary destroy action " <>
             "#{inspect(name)} is in exclude_destroy_actions, so AshArchival would delete " <>
             "its rows rather than archive them"}
        else
          :ok
        end
    end
  end

  defp check_cycle(destination, walk) do
    if destination in walk.on_path do
      {:error,
       "it leads back to #{inspect(destination)}, a cycle: one statement cannot update " <>
         "the same row twice, and a cycle has no depth a statement could stop at"}
    else
      :ok
    end
  end

  defp repo(resource), do: AshPostgres.DataLayer.Info.repo(resource, :mutate)
end
