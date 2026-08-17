# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Domain do
  @moduledoc "Domain for the round-trip test resources. Test-env only."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Test.LegacyUser
    resource AshStrangler.Test.DualWriteUser
    resource AshStrangler.Test.MixedUser
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
  | `login` | `map from: :login` | a rename, which needs no mechanism at all |
  | `email` | `map from: :email` | a **derived** cast: twin `:string` against resource `:ci_string` |
  | `full_name` | `map from: expr(...)`, read-only | NULL handling inside concatenation |
  | `archived_at` | `map ... zone: "UTC"` | a naive column read as an instant, deterministically |
  | `organization_id` | `constant` | a column with no legacy source |
  | `created_by_id` | `unmapped, as: :null` | a deliberately absent column |

  ## The cast is derived, not typed

  0.1 said `map :email, "email", cast: :citext`. That restated the resource
  attribute's own Ash type, and then the reconciler restated it a third time as
  `normalize: %{email: :ci_string}`. Here the twin says `email` is `:string` and
  the resource says it is `:ci_string`, so `AshStrangler.Lens` derives
  `(email)::citext` -- and the reconciler derives the same normalisation from the
  same two facts.

  The cast is load-bearing rather than cosmetic: without it the view column's
  declared type stays `text`, so `WHERE email = 'X'` **through the view** is
  case-sensitive while the resource says it is not.

  ## `migrate? false`, deliberately

  Ash does not own `legacy.users`, and it does not own this view either -- the
  compatibility DDL comes from `mix ash_strangler.gen.migration`, not from
  `mix ash.codegen`. See `AshStrangler.Verifiers.VerifyNotMigrated` for why there is
  no configuration in which `custom_statements` works for a view-backed resource.
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

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      map :email, from: :email

      # `zone:` replaces 0.1's `cast: :timestamptz, from_zone:` pair -- and the four
      # places that hard-coded its inversion by hand.
      map :archived_at, from: :deleted_at, zone: "UTC"

      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."

      constant :organization_id, expr(type(@organization_id, :uuid))

      unmapped [:created_by_id], as: :null, because: "No provenance for pre-migration rows."
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace

  @doc "The value the `organization_id` constant projects, for test assertions."
  def organization_id, do: @organization_id
end
