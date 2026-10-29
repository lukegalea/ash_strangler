# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Legacy.ClmParties do
  @moduledoc """
  The twin for `legacy.clm_parties` — the shared counterparty rows.

  `organization_id` is the tenant column this whole fixture hangs off: a
  contract derives its tenant from its client party's organization, which is
  the handoff §5 shape.
  """

  use Ash.Resource,
    domain: AshStrangler.Test.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "clm_parties"
    schema "legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Legacy.ClmContracts do
  @moduledoc """
  The twin for `legacy.clm_contracts`, columns exactly per handoff §5.

  The two `belongs_to` relationships are what `expr(service_provider_party.name)`
  and `tenant :organization_id, derive: expr(client_party.organization_id)`
  resolve through. `define_attribute? false` because the FK columns are already
  declared attributes — the Keystone twin's repair, and the reason the twin
  does not grow a second copy of each id column.
  """

  use Ash.Resource,
    domain: AshStrangler.Test.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "clm_contracts"
    schema "legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :effective_date, :date, public?: true
    attribute :expiry_date, :date, public?: true
    attribute :value, :decimal, public?: true
    attribute :payment_term, :string, public?: true
    attribute :processed, :boolean, allow_nil?: false, public?: true
    attribute :verified, :boolean, allow_nil?: false, public?: true
    attribute :archived, :naive_datetime, public?: true
    attribute :created_at, :naive_datetime, allow_nil?: false, public?: true
    attribute :service_provider_party_id, :uuid, public?: true
    attribute :client_party_id, :uuid, public?: true
    attribute :renewal_start_date, :date, public?: true
    attribute :renewal_end_date, :date, public?: true
    attribute :metadata, :map, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :service_provider_party, AshStrangler.Test.Legacy.ClmParties do
      define_attribute? false
      public? true
    end

    belongs_to :client_party, AshStrangler.Test.Legacy.ClmParties do
      define_attribute? false
      public? true
    end
  end

  actions do
    defaults [:read]
  end
end
