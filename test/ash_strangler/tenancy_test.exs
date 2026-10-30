# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TenancyTest.TenantedDestination do
  @moduledoc """
  A strangled, tenanted resource used as a relationship destination: the
  cross-tenant check fires only when the other side declares a tenant too.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "tenanted_destination_v"
    schema "verified"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :organization_id, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      map :login, from: :login
      map :organization_id, from: :salt

      tenant :organization_id, derive: expr(salt)
    end
  end
end

defmodule AshStrangler.TenancyTest.CrossTenantSource do
  @moduledoc """
  Tenanted through a derive with no relationship path — `expr(salt)` is
  row-local — yet related to `TenantedDestination`. The relationship's
  destination is tenanted and this source's derive roots cannot name the
  relationship, so `VerifyTenancy` refuses; the exempt variant below carries
  the same shape with the decision on the record.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "cross_tenant_source_v"
    schema "verified"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :organization_id, :string, public?: true
    attribute :other_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  relationships do
    belongs_to :other, AshStrangler.TenancyTest.TenantedDestination do
      public? true
      attribute_writable? true
    end
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      map :login, from: :login
      map :organization_id, from: :salt
      unmapped [:other_id], as: :null, because: "Probe fixture: no legacy column for it."

      tenant :organization_id, derive: expr(salt)
    end
  end
end

defmodule AshStrangler.TenancyTest.ExemptCrossTenantSource do
  @moduledoc """
  The same shape as `CrossTenantSource`, with the exemption declared. The
  verifier accepts it; `mix ash_strangler.check` reports it.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "exempt_cross_tenant_v"
    schema "verified"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :organization_id, :string, public?: true
    attribute :other_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  relationships do
    belongs_to :other, AshStrangler.TenancyTest.TenantedDestination do
      public? true
      attribute_writable? true
    end
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      map :login, from: :login
      map :organization_id, from: :salt
      unmapped [:other_id], as: :null, because: "Probe fixture: no legacy column for it."

      tenant :organization_id, derive: expr(salt), allow_unproven: [:other]
    end
  end
end

defmodule AshStrangler.TenancyTest do
  @moduledoc """
  The tenant declaration: single, resolvable, and honest about cross-resource
  proofs. The derive-through-a-join end-to-end case is the Contract fixture's;
  these cover the refusals and the exemption.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tenancy AshStrangler.Verifiers.VerifyTenancy
  @twin AshStrangler.Verifiers.VerifyTwin
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  test "refuses a second tenant declaration" do
    probe = two_tenants_probe()

    assert {:error, error} = @tenancy.verify(probe)

    assert Exception.message(error) =~ "2 `tenant` declarations on one source"
  end

  test "refuses a cross-tenant relationship its derive path cannot name" do
    assert {:error, error} =
             @tenancy.verify(AshStrangler.TenancyTest.CrossTenantSource.spark_dsl_config())

    message = Exception.message(error)

    assert message =~
             "cross-tenant relationship :other to AshStrangler.TenancyTest.TenantedDestination"

    assert message =~ "its tenant cannot be proven from this source"
    assert message =~ "allow_unproven: [:other]"
  end

  test "accepts the same shape with the exemption declared" do
    assert :ok =
             @tenancy.verify(AshStrangler.TenancyTest.ExemptCrossTenantSource.spark_dsl_config())
  end

  test "the tenant derive resolves on the twin through VerifyTwin" do
    probe = unresolvable_tenant_probe()

    assert {:error, error} = @twin.verify(probe)

    assert Exception.message(error) =~ ":organization_id"
  end

  test "the tenant lens is structural: no writes, masked, and accounted for" do
    lens = AshStrangler.Lens.tenant_lens(AshStrangler.TenancyTest.CrossTenantSource)

    assert lens.combinator == :tenant
    assert lens.writes == []
    assert lens.type == :masked
    assert lens.sources == [{[], :salt}]

    assert AshStrangler.Info.accounted_for(AshStrangler.TenancyTest.CrossTenantSource) ==
             MapSet.new([:id, :login, :organization_id, :other_id])
  end

  defp two_tenants_probe do
    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string(
          """
          defmodule AshStrangler.TenancyTest.TwoTenants#{System.unique_integer([:positive])} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "two_tenants_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false
              attribute :login, :string, public?: true
              attribute :organization_id, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :read_from_legacy

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "#{@namespace}"}
                map :login, from: :login
                map :organization_id, from: :salt

                tenant :organization_id, derive: expr(salt)
                tenant :organization_id, derive: expr(login)
              end
            end
          end
          """,
          [],
          file: "probe_two_tenants.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end

  defp unresolvable_tenant_probe do
    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string(
          """
          defmodule AshStrangler.TenancyTest.Unresolvable#{System.unique_integer([:positive])} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "unresolvable_tenant_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false
              attribute :login, :string, public?: true
              attribute :organization_id, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :read_from_legacy

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "#{@namespace}"}
                map :login, from: :login
                map :organization_id, from: :salt

                tenant :organization_id, derive: expr(client_party.organization_id)
              end
            end
          end
          """,
          [],
          file: "probe_unresolvable_tenant.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end
end
