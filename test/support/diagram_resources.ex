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
  plain renames, a cast, a joined relation, a constant, an unmapped attribute,
  an expression with an inverse, and an expression whose source columns cannot
  be worked out.

  It exists to be drawn, not to be run — no migration is generated from it.
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
    attribute :state_code, :integer, public?: true
    attribute :seen_at, :utc_datetime_usec, public?: true
    attribute :tenant_id, :uuid, public?: true
    attribute :created_by_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "drawn_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: @namespace}

      join("drawn_legacy.addresses", as: "addr", on: "addr.account_id = accounts.id")

      # Four plain mappings, which is over the bundling threshold.
      map :login, "login"
      map :nickname, "nick"
      map :phone, "phone"
      map :postcode, "post_code"

      map :email, "email", cast: :citext

      map :city, "addr.city" do
        writable? false
        because "Read from a joined relation; write it through its own resource."
      end

      map :state_code do
        from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
        to "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END"
        into "state"
      end

      map :seen_at do
        from "now()"
        writable? false
        because "Not stored in legacy at all; the view reports read time."
      end

      constant :tenant_id, "'00000000-0000-0000-0000-0000000000fe'::uuid"

      unmapped([:created_by_id], as: :null, because: "No provenance for pre-migration rows.")
    end
  end
end
