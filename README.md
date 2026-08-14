<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AshStrangler

Strangler-fig migrations for Ash: map an Ash resource onto a legacy Postgres
schema and move it through the migration phases without hand-writing SQL.

> **Alpha (0.1.0).** This version verifies mappings and phase declarations, and
> generates both the compatibility view (`:read_from_legacy`) and the
> `INSTEAD OF` triggers that carry writes back to legacy (`:dual_write`). It
> does not yet do the `:read_from_new` reversal, backfill, or notifications.
> See [Scope](#scope).

## The problem

You have a legacy database you do not own, and a new Ash application that has to
read and eventually write it. The strangler-fig pattern says: put a compatibility
layer in front of the old schema, move behaviour across it one piece at a time,
and remove the old thing when nothing reaches it any more.

In Postgres that layer is a view, plus — sometimes — `INSTEAD OF` triggers. Both
are easy to write and easy to get subtly wrong in ways that do not fail. This
package makes the mapping declarative, and checks the parts that bite.

## Scope

| | 0.1 |
|---|---|
| Verify mappings and phases at compile time | ✅ |
| `mix ash_strangler.check` pre-flight report | ✅ |
| Generate views (`:read_from_legacy`) | ✅ |
| Derive the modern key in Elixir, without a round trip | ✅ |
| Generate `INSTEAD OF` triggers (`:dual_write`) | ✅ |
| The reversed view (`:read_from_new`) | planned |
| Backfill, reconciler, notifications | planned |

Verification shipped first on purpose. It was useful on its own against a
hand-written strangler migration, and it meant the generators got built against
an oracle rather than alongside one — a real-Postgres round-trip suite that
installs the compatibility layer by *executing the generator's own output*,
never a transcribed copy.

That order paid for itself. Building the write path found four things wrong
with the read path that had already been written, reviewed and committed —
including a timestamp cast that silently produced different instants on
different connections.

## Usage

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :full_name, :string, public?: true
    attribute :archived_at, :utc_datetime_usec
  end

  identities do
    identity :unique_email, [:email]
  end

  strangler do
    phase :read_from_legacy

    source "legacy.users" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :email, "email", cast: :citext

      # `from_zone:` is required with `cast: :timestamptz` -- see below.
      map :archived_at, "deleted_at", cast: :timestamptz, from_zone: "UTC"

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
      end

      index "index_users_on_email", unique: true, columns: ["email"]
    end
  end
end
```

Add `postgres do table "users" ... end` as usual, then:

```bash
mix ash_strangler.check
mix ash.codegen add_users_view
```

`ash.codegen` finds the view and its expression index through the ordinary
`custom_statements` mechanism — no separate task, no separate migration
folder:

```sql
-- statement :strangler_users_view
CREATE OR REPLACE VIEW "public"."users" AS
SELECT
  uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text) AS id,
  id AS __legacy_id,
  (email)::citext AS email,
  coalesce(first_name,'') || ' ' || coalesce(last_name,'') AS full_name,
  (deleted_at AT TIME ZONE 'UTC') AS archived_at
FROM legacy.users;

-- statement :strangler_users_key_index
CREATE INDEX IF NOT EXISTS strangler_users_key_idx ON legacy.users
  (uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text));
```

`__legacy_id` is unused in this phase — `:read_from_legacy` is read-only, and
the verifiers reject a write to it at compile time — but it costs nothing to
expose now: every later phase's `INSTEAD OF` triggers key off it rather than
inverting the derived uuid.

Every attribute must appear in that `SELECT`, mapped, constant, or
`unmapped`, with no exception for attributes the resource keeps private — a
view cannot leave a column out the way `VerifyCompleteMapping` lets a private
attribute go unmentioned, so generating one is a strictly stronger check than
compiling one.

## Deriving the id without asking the database

`{:uuid_v5, ...}` keys are derived by a pure function, so code that has a
legacy id — a webhook payload, an import file, a URL — can compute the modern
id without a query:

```elixir
AshStrangler.KeyDerivation.uuid_v5(
  "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71",
  AshStrangler.KeyDerivation.name("legacy.users", 1)
)
#=> "5ecf8b7b-8241-5b27-a03c-4411a476359f"
```

That is the same value the generated view produces for row 1, and the test
suite asserts the agreement over generated inputs — including non-ASCII names,
where hashing codepoints instead of UTF-8 bytes would produce a stable,
plausible, permanently wrong answer. Both sides build the hashed name through
the same function so the format cannot drift.

## Why `cast: :timestamptz` makes you name a zone

Because the obvious thing is wrong in a way nothing reports.

`(deleted_at)::timestamptz` on a legacy `timestamp` **without** time zone reads
the naive value as wall-clock time in the *session's* `TimeZone`. Verified on
PostgreSQL 17.10: the same row, through the same view, is `12:00Z` on a UTC
connection and `01:30Z` on an `Australia/Lord_Howe` one. No error, no warning —
a timestamp wrong by a fixed offset, on some connections, depending on a
setting the view does not control.

So `from_zone:` is mandatory with that cast, and generates
`deleted_at AT TIME ZONE 'UTC'`, which says the zone in the view itself. Omit
it and the resource does not compile:

```
These mappings cast to `:timestamptz` without saying which time zone the
legacy column is in:

  :archived_at
```

Which zone a naive column is in is a fact about the *old application*, not
about its schema, so it cannot be inferred and is not guessed — defaulting to
UTC would be right for most legacy databases and silently wrong for the rest,
which is the worst available outcome. If the column is already `timestamptz`,
drop the `cast:` instead: `AT TIME ZONE` on an already-aware value converts it
back to naive.

The write path reverses this exactly, and has to: assigning a `timestamptz`
into a naive column uses an assignment cast with the same session dependence,
mirrored.

## What the verifiers catch

Each exists because the mistake it catches **does not fail on its own**.

**An attribute nobody mapped.** The convenient behaviour is to select `NULL`.
That is also how a strangler migration loses data silently: somebody adds an
attribute, the view keeps compiling, and the column reads NULL for every legacy
row. Omissions must be declared with a reason.

**A computed mapping that claims to be writable.** Postgres cannot invert
`first || ' ' || last`, and neither can this package. Either supply the inverse
or declare it read-only — and `because:` is required because that text is shown
to whoever attempts the write.

**An identity the database does not enforce.** Ash will use it to plan upserts
and to report "has already been taken" while Postgres accepts duplicates. An
identity must map to a declared unique index.

**Upserts on a trigger-backed mapping.** See below — this one is the sharpest.

## `writes:` is a trade, not an option

How writes reach the base table is derived from the mapping shape, and can be
overridden. **Both settings cost something**, which is why the package refuses to
pick silently when you declare one:

| | `:auto` (view auto-updatability) | `:triggers` (`INSTEAD OF`) |
|---|---|---|
| `INSERT … ON CONFLICT` | works | **broken** |
| `RETURNING` | correct | correct — the generated triggers re-read |
| `WITH CHECK OPTION` | enforced | **not enforced** |
| Governs every write | no — `MERGE` bypasses the mapping | yes |
| Rejects writes to read-only mappings | no | yes, quoting `because:` |

The upsert row is the one that surprises people. Against a view with an
`INSTEAD OF` trigger, `ON CONFLICT DO NOTHING` is **accepted and then does
nothing** — no error, no row. `DO UPDATE` at least fails loudly.

Which is why triggers are **derived rather than always generated**: a
single-table projection of plain columns stays auto-updatable and keeps its
upserts. A computed writable mapping (`to:`/`into:`) is what forces them.

The `RETURNING` row is the one that would have bitten hardest. On a view with
an `INSTEAD OF INSERT` trigger, `RETURNING` reports whatever the trigger
function returned — so the obvious body (insert, then `RETURN NEW`) hands back
NULL for every derived column including the primary key, **raising nothing**.
The generated functions re-read the stored row through the view and return
that.

### This collides with `ash_authentication`

Verified against 4.14.1:

- The **`password`** strategy does not upsert. Password-only authentication is
  migratable on the trigger path — the common case for a legacy monolith.
- The **`oauth2`** and **`oidc`** strategies **cannot be defined without an
  upsert**: their transformer validates `upsert? true` and a non-nil
  `upsert_identity`. There is no configuration that avoids it.
- The **`UserIdentity`** resource upserts unconditionally.

So OAuth2 and `INSTEAD OF` triggers are mutually exclusive, and adding OAuth2 to
a resource already on the trigger path is a breaking change. `VerifyNoUpserts`
says this in the error rather than reporting "action `:register_with_oauth2`
requires upserts", which would be true and useless.

## Installation

```elixir
def deps do
  [{:ash_strangler, "~> 0.1"}]
end
```

Add `:ash_strangler` to `import_deps` in `.formatter.exs`.

## Status and stability

Alpha. The DSL will change. Pin an exact version.

By the tier rules of the project this was extracted from, it is **tier 3**:
isolate it behind a seam and keep removal to a deletion until it has real
deployments.

## License

MIT.
