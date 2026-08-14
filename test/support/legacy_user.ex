# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Domain do
  @moduledoc "Domain for the round-trip test resources. Test-env only."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Test.LegacyUser
    resource AshStrangler.Test.DualWriteUser
  end
end

defmodule AshStrangler.Test.LegacyUser do
  @moduledoc """
  A resource mapped onto the `legacy.users` fixture, used by the round-trip
  property tests.

  Every mapping *kind* the DSL supports appears here exactly once, so the
  round-trip property covers all of them in a single generated row:

  | Attribute | Kind | What it exercises |
  |---|---|---|
  | `id` | `key`, `{:uuid_v5, ...}` | SQL/Elixir agreement on the derived key |
  | `login` | plain `map`, no cast | pass-through, and the unique legacy index |
  | `email` | `map ... cast: :citext` | a cast that changes comparison semantics |
  | `full_name` | computed `from`, read-only | NULL handling inside concatenation |
  | `archived_at` | `map ... cast: :timestamptz` | a cast that can depend on session state |
  | `organization_id` | `constant` | a column with no legacy source |
  | `created_by_id` | `unmapped, as: :null` | a deliberately absent column |

  ## `migrate? true`, deliberately

  Ash does **not** own `legacy.users` -- but it does own the view, and the view
  is emitted through `custom_statements`, which the AshPostgres migration
  generator only visits for resources with `migrate? true`. Setting
  `migrate? false` (the instinct for a view-backed resource, and what
  `mix ash_postgres.gen.resources --include-views` writes) would silently mean
  no view is ever generated.
  """

  # Fixed so the derived ids are stable across runs and can be asserted
  # against literal values as well as against Postgres.
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"
  @organization_id "00000000-0000-0000-0000-0000000000fe"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :full_name, :string, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :organization_id, :uuid, public?: true
    attribute :created_by_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "legacy.users" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: @namespace}

      map :login, "login"
      map :email, "email", cast: :citext
      # `from_zone:` is mandatory with `cast: :timestamptz` -- see
      # AshStrangler.Verifiers.VerifyTimestampZones. The fixture's `deleted_at`
      # is a naive `timestamp` recorded in UTC.
      map :archived_at, "deleted_at", cast: :timestamptz, from_zone: "UTC"

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
      end

      constant :organization_id, "'#{@organization_id}'::uuid"

      unmapped [:created_by_id], as: :null, because: "No provenance for pre-migration rows."

      index "index_users_on_login", unique: true, columns: ["login"]
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace

  @doc "The value the `organization_id` constant projects, for test assertions."
  def organization_id, do: @organization_id
end
