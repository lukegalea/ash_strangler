# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.DualWriteUser do
  @moduledoc """
  A `:dual_write` resource over the same `legacy.users` fixture, projected
  through its own view so it can coexist with `AshStrangler.Test.LegacyUser`.

  ## This fixture used to carry the bug

  In 0.1 it read:

      map :state_code do
        from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
        to   "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END"
        into "state"
      end

  `state` ranges over `passive | pending | active | suspended | deleted`. Forward
  sent every non-`active` value to `1`; backward sent `1` to `'suspended'`. So
  reading a `passive` user and writing the row back — assigning **only the
  email** — silently rewrote it to `suspended`, and three of five lifecycle states
  were destroyed by a write that never mentioned the lifecycle. All nine verifiers
  passed, because `VerifyWritableMappingsReversible` only checked that `to:` and
  `into:` were *present*.

  The property test missed it too: it generated `state_code <- member_of([0, 1])`,
  the one value set on which the mapping *is* a bijection, and its legacy-row
  helper never set `state`, so every row in the suite carried the column default
  `'active'`.

  ## What replaces it

  One `decode` declaration, from which both directions are derived — so they
  cannot disagree. `AshStrangler.Obligations` then decides four things about it
  against the twin's declared value set and the attribute's `one_of`:

  | Obligation | What would fail |
  |---|---|
  | `GetTotal` | dropping `:passive` from the table — the 0.1 bug, refused at compile time |
  | `PutTotal` | leaving `state_code` unconstrained, which let `state_code: 7` through |
  | `PutGet` | two legacy values sharing one code, so one of them cannot round-trip |
  | type agreement | a code that is not an `:integer` |

  `AshStrangler.ObligationsTest` writes each of those four mappings out and asserts
  the compile fails, which is the only way to know a refusal is real.

  ## What it still exercises

  `INSTEAD OF` triggers. `AshStrangler.Mechanism` classifies the `decode` as
  `:base_trigger` — a `BEFORE` trigger on the base table plus a shadow column would
  carry it and the view would stay auto-updatable — but that needs
  `ALTER TABLE legacy.users`, which this generator will not do unsupervised, so it
  is *emitted* as `:instead_of`. `AshStrangler.Test.MixedUser` is the fixture that
  proves the other side: a view whose computed columns are all read-only keeps
  `writes: :auto`, and upserts survive on it.

  It also carries a read-only mapping, so the guard that raises with the mapping's
  own `because:` text has something to fire on — including an apostrophe in that
  text, since the message is interpolated into a plpgsql string literal and a naive
  implementation would produce a syntax error the first time somebody wrote "don't".
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "dual_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true

    # The bound is what makes `PutTotal` decidable. Without it the attribute admits
    # `state_code: 7`, which 0.1 accepted and wrote back as `'suspended'` -- and read
    # back as `1`.
    #
    # `min`/`max` rather than `one_of` because `Ash.Type.Integer` has no `one_of`
    # constraint at all. An integer code is the common target for a `decode`, so
    # `AshStrangler.Obligations` enumerates a bounded integer range as a value space
    # too; see its `constraint_one_of/1`.
    attribute :state_code, :integer do
      public? true
      constraints min: 0, max: 4
    end

    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :full_name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:login, :email, :state_code, :archived_at]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      # Opted in so the notify trigger is generated and the listener has
      # something real to receive. Off by default, because it costs the legacy
      # application a pg_notify on every write.
      notify? true

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      map :email, from: :email
      map :archived_at, from: :deleted_at, zone: "UTC"

      # One declaration, both directions. The twin says `state` ranges over these
      # five values, so a missing entry is a `GetTotal` violation rather than a
      # silent `ELSE`.
      decode :state_code,
        from: :state,
        values: %{
          active: 0,
          passive: 1,
          pending: 2,
          suspended: 3,
          deleted: 4
        }

      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace

  @doc "The decode table, so tests assert against the declaration rather than a copy of it."
  def state_codes,
    do: %{active: 0, passive: 1, pending: 2, suspended: 3, deleted: 4}
end
