# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Legacy.ContractMapping do
  @moduledoc """
  The ENTIRE strangler mapping for `AshStrangler.Test.Contract`, declared
  outside the resource — the R1.1 proof shape this fixture exists in.

  The resource file contains no `strangler` block and no `extensions:`; the
  fragment carries both, and `mapping_fragment_test.exs` proved inline ==
  fragment DDL byte-for-byte. This is the same arrangement, live against the
  `legacy.clm_contracts` rows.
  """

  use AshStrangler.Mapping, resource: AshStrangler.Test.Contract

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.ClmContracts do
      # The legacy key IS the canonical id — clm_contracts was born with uuid
      # primary keys — so the host mints the id on create and the INSERT
      # trigger passes it into the legacy key column. No lookup table, both
      # directions.
      key :id, from: :id, strategy: :identity

      map :name, from: :name
      map :description, from: :description
      map :effective_date, from: :effective_date
      map :expiry_date, from: :expiry_date
      map :renewal_start_date, from: :renewal_start_date
      map :renewal_end_date, from: :renewal_end_date
      map :value, from: :value
      map :payment_term, from: :payment_term
      map :processed, from: :processed
      map :verified, from: :verified

      # Naive legacy timestamp, recorded in UTC — `zone:` bridges it, and its
      # collapse clause (R2) stamps it through the write direction.
      map :archived_at, from: :archived, zone: "UTC"

      map :vendor_party_id, from: :service_provider_party_id
      map :client_party_id, from: :client_party_id

      # Read through the join; the display name stays the legacy party row's.
      map :vendor_name,
        from: expr(service_provider_party.name),
        read_only?: true,
        because: "The vendor's name is the party row's name; contracts do not own it."

      # Storage the legacy schema has no room for, beside the shared rows.
      extension([:negotiating_notes])

      # Tenancy is a fact about the client party's row, derived once.
      tenant :organization_id, derive: expr(client_party.organization_id)
    end
  end
end

defmodule AshStrangler.Test.Contract do
  @moduledoc """
  The shared-rows fixture: one resource over `legacy.clm_contracts` — the
  handoff §5 contract — with the mapping entirely external (see
  `AshStrangler.Test.Legacy.ContractMapping`).

  Every acceptance property of the strangler is asserted against rows this
  resource shares with raw SQL on both sides: legacy edits read through with
  no sync job, host writes are visible to legacy immediately, and a command
  touching shared and extension data fails atomically.
  """

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshStrangler.Test.Legacy.ContractMapping]

  postgres do
    table "clm_contracts_view"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0

    attribute :name, :string, public?: true, allow_nil?: false
    attribute :description, :string, public?: true
    attribute :effective_date, :date, public?: true
    attribute :expiry_date, :date, public?: true
    attribute :renewal_start_date, :date, public?: true
    attribute :renewal_end_date, :date, public?: true
    attribute :value, :decimal, public?: true
    attribute :payment_term, :string, public?: true
    attribute :processed, :boolean, public?: true, default: false
    attribute :verified, :boolean, public?: true, default: false
    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :vendor_party_id, :uuid, public?: true
    attribute :client_party_id, :uuid, public?: true
    attribute :vendor_name, :string, public?: true
    attribute :organization_id, :uuid, public?: true
    attribute :negotiating_notes, :string, public?: true, default: ""
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :name,
      :description,
      :effective_date,
      :expiry_date,
      :renewal_start_date,
      :renewal_end_date,
      :value,
      :payment_term,
      :processed,
      :verified,
      :archived_at,
      :vendor_party_id,
      :client_party_id,
      :negotiating_notes
    ]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  @doc "The extension table's qualified name, for raw SQL assertions."
  def extension_table, do: ~s("strangler"."clm_contracts_view_extension")
end
