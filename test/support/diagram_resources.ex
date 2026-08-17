# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# Fixtures for the diagram tests.
#
# These live in test/support rather than beside the tests that use them because
# two test files need the same resources, and ExUnit compiles test files in
# parallel -- a resource defined in one test file is not reliably a finished
# Spark DSL module by the time another test file asks it a question.

defmodule AshStrangler.DiagramTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.DiagramTest.Account
    resource AshStrangler.DiagramTest.Plain
  end
end

defmodule AshStrangler.DiagramTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.DiagramTest.Legacy.Accounts
    resource AshStrangler.DiagramTest.Legacy.Addresses
  end
end

defmodule AshStrangler.DiagramTest.Legacy.Addresses do
  @moduledoc "Twin for the joined relation the diagram has to draw in its own subgraph."
  use Ash.Resource,
    domain: AshStrangler.DiagramTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "addresses"
    schema "drawn_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :account_id, :integer
    attribute :city, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.DiagramTest.Legacy.Accounts do
  @moduledoc """
  Twin for the primary relation.

  The `address` relationship is what 0.1 spelled as
  `join "drawn_legacy.addresses", as: "addr", on: "addr.account_id = accounts.id"` —
  arbitrary SQL in a DSL option. As a `has_one` the join condition is derived, the
  fan-out is a property of a declared relationship, and a cross join is not
  expressible.
  """
  use Ash.Resource,
    domain: AshStrangler.DiagramTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "drawn_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :login, :string
    attribute :nick, :string
    attribute :phone, :string
    attribute :post_code, :string
    attribute :email, :string

    attribute :state, :atom do
      constraints one_of: [:passive, :pending, :active, :suspended, :deleted]
    end
  end

  relationships do
    has_one :address, AshStrangler.DiagramTest.Legacy.Addresses do
      source_attribute :id
      destination_attribute :account_id
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.DiagramTest.Plain do
  @moduledoc "An ordinary resource, here to be left out of the diagram."
  use Ash.Resource, domain: AshStrangler.DiagramTest.Domain

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end
end

defmodule AshStrangler.DiagramTest.Account do
  @moduledoc """
  A resource carrying every mapping construct the diagram has to draw at once:
  plain renames, a derived cast, a column read through a relationship, a constant,
  an unmapped attribute, an invertible `decode`, and an opaque `fragment`.

  It exists to be drawn, not to be run — no migration is generated from it.

  ## One node it can no longer carry

  0.1's version had a mapping whose source columns the diagram *could not work
  out* — `from "now()"` — which drew a rhombus reading "source columns not
  resolved". That node is not expressible any more: lineage is
  `AshStrangler.Expr.refs/1` over a tree that was constructed, so there is no
  inference to fail. `seen_at` is an opaque `fragment` here instead, which is a
  different thing and is drawn as one: the diagram knows exactly which columns it
  reads (none), and says the transform itself is unproven.
  """
  use Ash.Resource,
    domain: AshStrangler.DiagramTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  postgres do
    table "accounts"
    schema "drawn"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :nickname, :string, public?: true
    attribute :phone, :string, public?: true
    attribute :postcode, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :city, :string, public?: true

    attribute :state_code, :integer do
      public? true
      constraints min: 0, max: 4
    end

    attribute :seen_at, :utc_datetime_usec, public?: true
    attribute :tenant_id, :uuid, public?: true
    attribute :created_by_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.DiagramTest.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      # Four plain mappings, which is over the bundling threshold.
      map :login, from: :login
      map :nickname, from: :nick
      map :phone, from: :phone
      map :postcode, from: :post_code

      # The cast is derived from `:string` against `:ci_string` -- not typed.
      map :email, from: :email

      map :city,
        from: expr(address.city),
        read_only?: true,
        because: "Read through a relationship; write it through its own resource."

      decode :state_code,
        from: :state,
        values: %{active: 0, passive: 1, pending: 2, suspended: 3, deleted: 4}

      map :seen_at,
        from: expr(fragment("now()")),
        read_only?: true,
        because: "Not stored in legacy at all; the view reports read time."

      constant :tenant_id, expr(type("00000000-0000-0000-0000-0000000000fe", :uuid))

      unmapped([:created_by_id], as: :null, because: "No provenance for pre-migration rows.")
    end
  end
end
