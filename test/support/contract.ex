# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Legacy.ContractMapping do
  @moduledoc """
  The ENTIRE strangler mapping for `AshStrangler.Test.Contract`, declared
  outside the resource — the R1.1 proof shape this fixture exists in.

  The lifecycle is the handoff §5 collapse: legacy encodes only `processed`,
  `verified` and `archived`; everything else the contract can BE has a
  declared answer (extension / refuse / lossy / derived).
  """

  use AshStrangler.Mapping, resource: AshStrangler.Test.Contract

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.ClmContracts do
      # The observation fixture: the durable ledger plus its observers. The
      # channel is this fixture's own -- the wake payload on a shared channel
      # would race whatever else listens on the default.
      notify? true
      ledger? true
      notify_channel "ash_strangler_contract_observation"
      observers([AshStrangler.Test.RecordingObserver])

      # The legacy key IS the canonical id -- clm_contracts was born with uuid
      # primary keys -- so the host mints the id on create and the INSERT
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

      map :vendor_party_id, from: :service_provider_party_id
      map :client_party_id, from: :client_party_id

      # Read through the join; the display name stays the legacy party row's.
      map :vendor_name,
        from: expr(service_provider_party.name),
        read_only?: true,
        because: "The vendor's name is the party row's name; contracts do not own it."

      # Storage the legacy schema has no room for, beside the shared rows.
      extension([:negotiating_notes, :created_by_id])

      # Tenancy is a fact about the client party's row, derived once.
      tenant :organization_id, derive: expr(client_party.organization_id)

      # THE lifecycle. Clause order is declaration order; the extension state
      # reads first, the fallback last. The `active`/`terminated` sets write
      # the booleans so the backward direction is total and canonical: a
      # transition INTO the state stamps the legacy encoding, and the
      # legacy-encoded rows read back as the state they encode.
      collapse :lifecycle_state do
        hit_policy :first

        state :negotiating, representation: {:extension, :lifecycle_state}
        state :archived, when: expr(not is_nil(archived)), set: [archived: expr(now())]
        state :expired, when: expr(expiry_date < fragment("CURRENT_DATE")), derived: true
        state :active, when: expr(processed and verified), set: [processed: true, verified: true]

        state :terminated,
          when: expr(processed and not verified),
          set: [processed: true, verified: false]

        state :ready_to_execute,
          representation:
            {:lossy,
             to: :draft,
             loss:
               "terms finalised but not executed; legacy only knows un-executed contracts as draft"}

        state :cancelled,
          representation:
            {:refuse,
             reason:
               "legacy clm_contracts has no cancelled encoding; cancelling is refused while legacy is authoritative"}

        state :draft, when: :otherwise, set: [processed: false, verified: false]
      end
    end
  end
end

defmodule AshStrangler.Test.Contract do
  @moduledoc """
  The shared-rows fixture: one resource over `legacy.clm_contracts` — the
  handoff §5 contract — with the mapping entirely external (see
  `AshStrangler.Test.Legacy.ContractMapping`).

  The lifecycle is an `AshStateMachine` over the collapse: every command is a
  named update whose only state change is its declared transition, and there
  is **no primary `:update`** — an executed contract is never edited, it is
  amended. The absence of any generic edit path is the enforcement; the
  lifecycle tests also assert a raw state write is refused.
  """

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
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
    attribute :vendor_party_id, :uuid, public?: true
    attribute :client_party_id, :uuid, public?: true
    attribute :vendor_name, :string, public?: true
    attribute :organization_id, :uuid, public?: true
    attribute :negotiating_notes, :string, public?: true, default: ""

    # Provenance (platform convention): WHO created this row on the host
    # side. Stored in the extension store (see ContractMapping), travels with
    # the shared row, and rolls back with the command that wrote it.
    attribute :created_by_id, :uuid, public?: true

    attribute :lifecycle_state, :atom do
      public? true
      allow_nil? false
      default :draft

      constraints one_of: [
                    :draft,
                    :negotiating,
                    :ready_to_execute,
                    :active,
                    :terminated,
                    :archived,
                    :cancelled,
                    :expired
                  ]
    end
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft
    state_attribute :lifecycle_state

    # :expired has no command — it is a function of expiry_date, not a
    # transition — so the machine is told about it here rather than through a
    # transition that could never fire.
    extra_states [:expired]

    transitions do
      transition :negotiate_terms, from: :draft, to: :negotiating
      transition :finalise_terms, from: :negotiating, to: :ready_to_execute
      # :ready_to_execute is lossy -- it reads back as :draft -- so the
      # machine that traverses it must accept the read-back spelling, or the
      # lossy declaration would make its own forward path unreachable.
      transition :execute, from: [:ready_to_execute, :draft], to: :active
      transition :amend, from: :active, to: :active
      transition :renew, from: :active, to: :active
      transition :extend, from: :active, to: :active
      transition :terminate, from: :active, to: :terminated
      transition :cancel, from: [:draft, :negotiating, :ready_to_execute], to: :cancelled
      transition :archive, from: :terminated, to: :archived
    end
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
      :vendor_party_id,
      :client_party_id,
      :negotiating_notes,
      :created_by_id
    ]

    create :create do
      primary? true
    end

    update :negotiate_terms do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      accept [
        :name,
        :description,
        :effective_date,
        :expiry_date,
        :renewal_start_date,
        :renewal_end_date,
        :value,
        :payment_term,
        :vendor_party_id,
        :client_party_id,
        :negotiating_notes
      ]

      change transition_state(:negotiating)
    end

    update :finalise_terms do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      change transition_state(:ready_to_execute)
    end

    update :execute do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      change transition_state(:active)
    end

    update :amend do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      accept [:name, :description, :value, :payment_term, :negotiating_notes]
      change transition_state(:active)
    end

    update :renew do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      accept [:renewal_start_date, :renewal_end_date]
      change transition_state(:active)
    end

    update :extend do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      accept [:expiry_date]
      change transition_state(:active)
    end

    update :terminate do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      change transition_state(:terminated)
    end

    update :cancel do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      change transition_state(:cancelled)
    end

    update :archive do
      # Atomicity is delivered by the INSTEAD OF trigger's single statement;
      # the machine's atomic guard expression cannot compile against a
      # view-backed data layer.
      require_atomic? false

      change transition_state(:archived)
    end
  end

  @doc "The extension table's qualified name, for raw SQL assertions."
  def extension_table, do: ~s("strangler"."clm_contracts_view_extension")
end
