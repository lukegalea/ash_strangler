# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Demo do
  @moduledoc """
  The worked example from the README, as real compiling resources.

  It exists so the diagrams in the documentation are **generated from the
  model** rather than drawn by hand to look like it — `AshStrangler.DiagramTest`
  renders these and asserts the README still matches, so a mapping change that
  invalidates a picture fails the build instead of quietly leaving a lie in the
  README.

  The legacy shape it maps is deliberately the one fifteen years produces: a
  single `accounts` table holding a person, their employer and their address,
  with the lifecycle spread across four columns that can contradict each other.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  @doc "The namespace the demo's keys hash against."
  def namespace, do: @namespace

  @doc "DDL for the legacy table the demo maps, so the diagrams have a real schema behind them."
  def legacy_ddl do
    """
    CREATE TABLE demo_legacy.accounts (
      id            bigserial PRIMARY KEY,
      email         text NOT NULL,
      first_name    text,
      last_name     text,
      company_name  text,
      company_vat   text,
      addr_line1    text,
      addr_city     text,
      is_active     boolean NOT NULL DEFAULT true,
      is_deleted    boolean NOT NULL DEFAULT false,
      approved_at   timestamp,
      cancelled_at  timestamp
    )
    """
  end
end

defmodule AshStrangler.Demo.Domain do
  @moduledoc "Domain for the documented example."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Demo.Customer
    resource AshStrangler.Demo.Organization
    resource AshStrangler.Demo.Address
  end
end

defmodule AshStrangler.Demo.Customer do
  @moduledoc """
  The person — with a lifecycle collapsed out of four legacy columns and handed
  to an ordinary state machine.
  """
  use Ash.Resource,
    domain: AshStrangler.Demo.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource, AshStateMachine]

  postgres do
    table "customers"
    schema "demo"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :full_name, :string, public?: true

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :active, :cancelled, :archived]
    end

    attribute :organization_id, :uuid, public?: true
  end

  relationships do
    belongs_to :organization, AshStrangler.Demo.Organization do
      public? true
      attribute_writable? false
      define_attribute? false
    end

    has_one :address, AshStrangler.Demo.Address do
      public? true
      destination_attribute :id
      source_attribute :id
    end
  end

  # An ordinary state machine. It has no idea the data underneath is four
  # booleans in a table from 2011.
  state_machine do
    # The lifecycle attribute is the one the mapping projects, not the default
    # `:state` -- otherwise the state machine adds an attribute the mapping
    # never accounted for, and VerifyCompleteMapping rejects it.
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition :approve, from: :pending, to: :active
      transition :cancel, from: [:pending, :active], to: :cancelled
      transition :archive, from: [:pending, :active, :cancelled], to: :archived
    end
  end

  actions do
    defaults [:read]

    # One action per transition, so the lifecycle is expressed as intent rather
    # than as an attribute somebody happens to set. They become usable at
    # `:dual_write`; declaring them now is how the target model gets written
    # down while the legacy columns are still the source of truth.
    update :approve do
      accept []
      require_atomic? false
      change transition_state(:active)
    end

    update :cancel do
      accept []
      require_atomic? false
      change transition_state(:cancelled)
    end

    update :archive do
      accept []
      require_atomic? false
      change transition_state(:archived)
    end
  end

  strangler do
    phase :read_from_legacy

    source "demo_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: AshStrangler.Demo.namespace()}

      map :email, "email", cast: :citext

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
      end

      # Four columns, one lifecycle. Most-terminal first, so the projection stays
      # a total function over rows the old application was never stopped from
      # writing.
      map :status do
        from """
        CASE
          WHEN is_deleted THEN 'archived'
          WHEN cancelled_at IS NOT NULL THEN 'cancelled'
          WHEN approved_at IS NOT NULL THEN 'active'
          ELSE 'pending'
        END
        """

        writable? false

        because "Four legacy columns with no single inverse. Supply `to:`/`into:` before dual-write."
      end

      # The employer lives in the same row, so the association is the row itself.
      map :organization_id do
        from "uuid_generate_v5('#{AshStrangler.Demo.namespace()}'::uuid, 'demo_legacy.accounts:' || id::text)"
        writable? false
        because "Derived from the same legacy row; the split is presentational."
      end
    end
  end
end

defmodule AshStrangler.Demo.Organization do
  @moduledoc "The employer, from the very same legacy rows."
  use Ash.Resource,
    domain: AshStrangler.Demo.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "organizations"
    schema "demo"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
    attribute :vat_number, :string, public?: true
  end

  relationships do
    has_many :customers, AshStrangler.Demo.Customer do
      public? true
      destination_attribute :organization_id
    end
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "demo_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: AshStrangler.Demo.namespace()}

      map :name, "company_name"
      map :vat_number, "company_vat"
    end
  end
end

defmodule AshStrangler.Demo.Address do
  @moduledoc "The address, likewise — a concept the legacy table never separated."
  use Ash.Resource,
    domain: AshStrangler.Demo.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "addresses"
    schema "demo"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :line1, :string, public?: true
    attribute :city, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "demo_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: AshStrangler.Demo.namespace()}

      map :line1, "addr_line1"
      map :city, "addr_city"
    end
  end
end
