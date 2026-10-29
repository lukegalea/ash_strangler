# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyKeyAllocation do
  @moduledoc """
  A resource the host can create rows on must have a key allocation path that
  actually works — in both directions.

  Two strategies, two answers to "who allocates the key on a host create":

    * `{:uuid_v5, namespace: ...}` — the **legacy** side allocates: the host
      inserts through the view, the legacy sequence (or default) picks the
      legacy key, and the canonical id is derived from it in the view. That
      needs `INSTEAD OF` triggers, because an auto-updatable view has no
      statement that runs after the base insert to derive anything — the id
      column of the view is an expression, and an expression column cannot
      accept what a create action sends. So: creates + `:auto` + a derived
      strategy is refused, with the fix named.

    * `:identity` — the **host** mints: the canonical id is the legacy key, so
      the create action must be able to supply one. The primary key attribute
      needs a default or `writable?` on create; the INSERT trigger passes
      `NEW.<pk>` into the legacy key column. Without a mintable key the create
      would send nothing, the legacy side would allocate its own, and the id
      the client asked for would be silently replaced by the view's projection
      of a row it did not create.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case AshStrangler.Info.source(dsl) do
      nil ->
        :ok

      _source ->
        verify_allocation(dsl)
    end
  end

  defp verify_allocation(dsl) do
    key = AshStrangler.Info.key(dsl)
    resource = Verifier.get_persisted(dsl, :module)
    creates? = resource != nil and has_create?(resource)

    cond do
      is_nil(key) ->
        # A source with no key is VerifyPhaseTransition's finding, in the terms
        # of phases; nothing about allocation to add here.
        :ok

      not creates? ->
        # Nothing creates rows on this resource; both directions of the
        # derivation are reads, and reads work for either strategy.
        :ok

      key.strategy == :identity ->
        verify_mintable(dsl, resource, key)

      AshStrangler.Info.writes(dsl) == :auto and sends_id?(resource, key) ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:strangler, :key],
           message: """
           create needs writes: :triggers so the legacy sequence allocates the \
           key -- an auto-updatable view cannot insert through a derived id.

           The view's id column is `uuid_generate_v5(...)` over the legacy key,
           and PostgreSQL refuses an INSERT that supplies a value for an
           expression column. This resource's create would send one: its
           primary key is writable or has a default, so the statement carries
           the id, and the view rejects it.

               writes: :triggers

           (When the create sends no id at all -- primary key neither writable
           nor defaulted -- the insert omits the column, the legacy key
           allocates, and the derived id comes back through RETURNING. That
           shape is accepted, and measured working; this refusal is about the
           id being sent.)
           """
         )}

      true ->
        :ok
    end
  end

  # A create sends the id when the pk attribute is writable or has a default:
  # either way AshPostgres includes the column, and an auto-updatable view
  # refuses to take a value for its expression column. A non-writable,
  # default-less pk is omitted from the statement entirely, and the legacy
  # sequence's choice comes back projected through the view.
  defp sends_id?(resource, key) do
    case Ash.Resource.Info.attribute(resource, key.attribute) do
      nil -> true
      attribute -> attribute.writable? or attribute.default != nil
    end
  end

  defp verify_mintable(_dsl, resource, key) do
    attribute = Ash.Resource.Info.attribute(resource, key.attribute)

    mintable? =
      attribute != nil and (attribute.default != nil or attribute.writable?)

    if mintable? do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: resource,
         path: [:strangler, :key],
         message: """
         `key :#{key.attribute}, strategy: :identity` needs a key the host can \
         mint on create, and #{inspect(resource)}'s `#{key.attribute}` has \
         neither a default nor `writable?`.

         An :identity key IS the legacy key: a host-created row names its own
         id, and the INSERT trigger passes it into the legacy key column. Give
         the attribute a default the host side generates -- a uuid default is
         the usual shape --

             attribute #{inspect(attribute.name)}, :uuid, default: &Ash.UUID.generate/0

         -- or make it writable and supply it on every create.
         """
       )}
    end
  end

  defp has_create?(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.any?(&(&1.type == :create))
  end
end
