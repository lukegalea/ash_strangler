# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyTenancy do
  @moduledoc """
  The tenant declaration must be single, resolvable, and honest about what it
  can prove across resources.

    * at most one `tenant` per source. The tenant attribute is one fact about
      the resource; a second `derive:` for it is two answers to one question,
      the same bug `VerifySingleSource` refuses for mappings.
    * the derive expression resolves on the twin. That check is
      `VerifyTwin`'s, which runs first and sees the tenant lens like any
      mapping's sources — this verifier does not restate it.
    * cross-tenant relationships are proven or declared. For every
      relationship from this resource to another strangled resource that also
      declares a tenant, the destination's tenant must lie on this resource's
      derive path — the relationship and the derive's path root must be the
      same name, so "this row's tenant" and "that row's tenant" are provably
      the same organization. Anything else is refused:

          cross-tenant relationship :client_party to Y: Y's tenant cannot be
          proven from this source

      An exemption is a declaration, not a silence:
      `tenant :organization_id, derive: expr(...), allow_unproven: [:rel]` —
      and `mix ash_strangler.check` reports every one.

  A relationship to a resource that is not compiled yet is skipped, and is
  checked from the other side when it compiles: a verifier sees one resource's
  DSL, and both endpoints of the relationship run this check.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Expr
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case AshStrangler.Info.tenant(dsl) do
      nil ->
        :ok

      tenant ->
        with :ok <- at_most_one(dsl),
             :ok <- verify_cross_tenant(dsl, tenant) do
          :ok
        else
          {:error, error} -> {:error, error}
        end
    end
  end

  defp at_most_one(dsl) do
    source = AshStrangler.Info.source(dsl)

    case Enum.count(source.tenants, &is_struct(&1, AshStrangler.Tenant)) do
      count when count <= 1 ->
        :ok

      count ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:strangler, :source, :tenant],
           message: """
           #{count} `tenant` declarations on one source.

           The tenant attribute is one fact about the resource, and `derive:`
           is its one derivation. Two declarations would leave the view with
           two expressions for one column. Declare it once.
           """
         )}
    end
  end

  defp verify_cross_tenant(dsl, tenant) do
    resource = Verifier.get_persisted(dsl, :module)

    if resource == nil do
      :ok
    else
      derive_roots = derive_roots(tenant)

      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reject(&relationship_exempt?(tenant, &1))
      |> Enum.find(:ok, fn relationship ->
        cross_tenant_violation?(relationship, derive_roots)
      end)
      |> case do
        :ok ->
          :ok

        relationship ->
          {:error,
           Spark.Error.DslError.exception(
             module: resource,
             path: [:strangler, :source, :tenant],
             message: """
             cross-tenant relationship :#{relationship.name} to \
             #{inspect(relationship.destination)}: its tenant cannot be proven \
             from this source.

             Both resources declare a tenant, so a row of one implies a row of
             the other -- but only if both tenants derive from the same legacy
             fact. This resource's derive path roots are \
             #{derive_roots |> Enum.uniq() |> Enum.map_join(", ", &":#{&1}")} \
             -- none of them is the relationship :#{relationship.name}.

             Either derive this resource's tenant through that relationship, or
             declare the exemption and have `mix ash_strangler.check` carry it
             on the record:

                 tenant :#{tenant.attribute}, derive: expr(...), allow_unproven: [:#{relationship.name}]
             """
           )}
      end
    end
  end

  # The relationship names this resource declines to prove. An exemption is
  # reported by the check task; the verifier's job is only to keep it on the
  # record rather than implied.
  defp relationship_exempt?(tenant, relationship),
    do: relationship.name in List.wrap(tenant.allow_unproven)

  defp cross_tenant_violation?(relationship, derive_roots) do
    destination = relationship.destination

    Code.ensure_loaded?(destination) and AshStrangler.Info.strangled?(destination) and
      AshStrangler.Info.tenant(destination) != nil and
      relationship.name not in derive_roots
  end

  # The first segment of every relationship path the derive reads through —
  # the joins this resource's own tenant derivation crosses. A destination
  # whose tenant "cannot be proven" is one no derive path root names.
  defp derive_roots(tenant) do
    tenant.derive
    |> Expr.refs()
    |> Enum.flat_map(fn
      {[], _attribute} -> []
      {path, _attribute} -> [List.first(path)]
    end)
  end
end
