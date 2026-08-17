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

defmodule AshStrangler.Demo.Legacy do
  @moduledoc "Domain for the demo's twin."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Demo.Legacy.Accounts
  end
end

defmodule AshStrangler.Demo.Legacy.Accounts do
  @moduledoc """
  The twin for `demo_legacy.accounts`.

  Three resources are mapped onto it. Declaring the legacy schema once, here, is
  what replaced repeating `source "demo_legacy.accounts" do key … end` in each of
  them — and it is what lets all three read a *typed* column rather than a name in
  a string.
  """
  use Ash.Resource,
    domain: AshStrangler.Demo.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "demo_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :email, :string, allow_nil?: false
    attribute :first_name, :string
    attribute :last_name, :string
    attribute :company_name, :string
    attribute :company_vat, :string
    attribute :addr_line1, :string
    attribute :addr_city, :string
    attribute :is_active, :boolean, allow_nil?: false
    attribute :is_deleted, :boolean, allow_nil?: false
    attribute :approved_at, :naive_datetime
    attribute :cancelled_at, :naive_datetime
  end

  actions do
    defaults [:read]
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

  ## The mapping 0.1 could not write

  `status` is four legacy columns and one attribute. In 0.1 the only way to state
  it was an irreversible `CASE`, and the README said so out loud:

      map :status do
        from "CASE WHEN is_deleted THEN 'archived' ... END"
        writable? false
        because "Four legacy columns with no single inverse. Supply `to:`/`into:` before dual-write."
      end

  That `because:` was an invitation to write the bug: "supply an inverse" meant
  hand-writing a second SQL string that nothing would ever compare to the first.

  `collapse` states both directions per clause, which is Sparcl's
  `case … of { p → e with e′ }` (rule **T-RCase**, ICFP 2020). Because `set:` names
  **every** legacy column the table touches, the backward direction is total and
  canonical by construction — there is no "which of the four do I write" left to
  get wrong — and `AshStrangler.Obligations` decides completeness, reachability and
  surjectivity over the guard lattice.
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
    # than as an attribute somebody happens to set.
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

    source AshStrangler.Demo.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: AshStrangler.Demo.namespace()}

      map :email, from: :email

      concat :full_name,
        from: [:first_name, :last_name],
        separator: " ",
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no separator fixes it."

      # Four columns, one lifecycle. Most-terminal first, so the projection stays
      # a total function over rows the old application was never stopped from
      # writing -- and `:otherwise` is what makes that guarantee rather than a hope.
      collapse :status do
        hit_policy :first

        state :archived,
          when: expr(is_deleted),
          set: [is_deleted: true, cancelled_at: nil, approved_at: nil]

        state :cancelled,
          when: expr(not is_nil(cancelled_at)),
          set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]

        state :active,
          when: expr(not is_nil(approved_at)),
          set: [is_deleted: false, cancelled_at: nil, approved_at: touch()]

        state :pending,
          when: :otherwise,
          set: [is_deleted: false, cancelled_at: nil, approved_at: nil]
      end

      # The employer lives in the same row, so the association is the row itself.
      map :organization_id,
        from:
          expr(
            fragment(
              "uuid_generate_v5(?::uuid, 'demo_legacy.accounts:' || ?::text)",
              "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71",
              id
            )
          ),
        read_only?: true,
        because: "Derived from the same legacy row; the split is presentational."
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

    source AshStrangler.Demo.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: AshStrangler.Demo.namespace()}

      map :name, from: :company_name
      map :vat_number, from: :company_vat
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

    source AshStrangler.Demo.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: AshStrangler.Demo.namespace()}

      map :line1, from: :addr_line1
      map :city, from: :addr_city
    end
  end
end
