<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AshStrangler

Strangler-fig migrations for Ash: map an Ash resource onto a legacy Postgres
schema and move it through the migration phases without hand-writing SQL.

> **Alpha (0.1.0).** All four phases generate SQL, and backfill, reconciliation
> and notification bridging exist. The DSL will change. See [Scope](#scope).

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
| The reversed view (`:read_from_new`) | ✅ |
| Resumable backfill | ✅ |
| Reconciler (drift detection) | ✅ |
| Notification bridge to `Ash.Notifier` | ✅ |

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

Add `postgres do table "users"; schema "strangler"; repo MyApp.Repo;
migrate? false end` — `migrate? false` is required and the compiler enforces it,
for a reason worth reading below. Then:

```bash
mix ash_strangler.check
mix ash_strangler.gen.migration
mix ecto.migrate
```

which generates:

```sql
CREATE OR REPLACE VIEW "strangler"."users" AS
SELECT
  uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text) AS id,
  id AS __legacy_id,
  (email)::citext AS email,
  coalesce(first_name,'') || ' ' || coalesce(last_name,'') AS full_name,
  (deleted_at AT TIME ZONE 'UTC') AS archived_at
FROM legacy.users;

CREATE INDEX IF NOT EXISTS strangler_users_key_idx ON legacy.users
  (uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text));
```

## Why a separate task instead of `mix ash.codegen`

Because there is no setting in which codegen can carry it. Both were tried
against a real generated migration:

| `migrate?` | What happens |
|---|---|
| `true` (the default) | codegen emits `create table` for the **view's own name**, then the view DDL fails against it. The migration cannot run. |
| `false` | the resource produces no snapshot, and `custom_statements` are read only from snapshots — so the view, index and triggers are silently dropped. |

So `migrate? false` is mandatory (`VerifyNotMigrated` enforces it, with that
explanation in the error) and the DDL gets its own generator. This is the same
position AshPostgres itself takes: `mix ash_postgres.gen.resources
--include-views` writes `migrate? false` beside a comment saying migrations for
views are handled manually. This package automates the manual part.

Every generated statement is idempotent, so regenerating after a mapping change
and running the new migration is the workflow. Never hand-edit a generated
migration — the next regeneration will contradict it.

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

## Moving through the phases

`phase` is the one control knob; everything generated follows from it.

| | `:read_from_legacy` | `:dual_write` | `:read_from_new` | `:decommissioned` |
|---|---|---|---|---|
| Source of truth | legacy | legacy | the new table | the new table |
| The view is named for | the modern shape | the modern shape | the **legacy** shape | — |
| `INSTEAD OF` triggers | none | only if the mapping needs them | on the legacy-named view | none |
| `migrate?` | `false` | `false` | `true` | `true` |
| Ash writes | rejected | through the view | direct to the table | direct |

The view **flips direction, and its name flips with it**. In the last phase the
old application still runs `SELECT * FROM users` unchanged — `users` is simply
no longer a table. That is what makes cutover a migration rather than a
coordinated deploy of two systems, and it is the single most valuable thing
here.

`:read_from_new` is the one-way door, so it is locked: a mapping that declared
`writable? false` cannot be run backwards, which means the legacy columns behind
it would read `NULL` for the old application from the moment of cutover.
`VerifyReverseMappable` refuses the phase and names them.

## Backfill

Batched, resumable, and designed not to take the database down while it runs:

```elixir
AshStrangler.Backfill.add_flag_column!(MyApp.Repo, "legacy.users")
AshStrangler.Backfill.run(MyApp.Repo,
  relation: "legacy.users",
  batch_size: 1_000,
  progress: fn done, total -> IO.puts("#{done}/#{total}") end
)
```

Two choices worth explaining, both borrowed from `pgroll` after reading its
source:

**A dedicated `_needs_backfill` flag column, not `WHERE new_col IS NULL`.** The
`IS NULL` predicate is wrong the moment a target column's *correct* value can
legitimately be null — which `unmapped ..., as: :null` guarantees — because then
a finished row is indistinguishable from a pending one and the loop never
terminates.

**`FOR NO KEY UPDATE`, not `FOR UPDATE`**, so a batch does not block concurrent
foreign-key checks against the rows it holds.

Plus keyset pagination with one committed transaction per batch: a single large
`UPDATE` holds row locks for the whole run, pins the global xmin so `VACUUM`
reclaims nothing cluster-wide, and cannot be resumed.

## Reconciler

The drift detector, and the correctness oracle the tests use — deliberately the
same code in both, because a reconciler that is only exercised by production is
one nobody has proven can detect anything.

```elixir
AshStrangler.Reconciler.diff(MyApp.Repo, relation: "legacy.users", view: "strangler.users")
```

It takes per-column normalization, and that is not a nicety. Ash's own types
transform values on write — `Ash.Type.CiString` trims by default — so a value
written through Ash legitimately differs from the same value written by the old
application. A reconciler that does not know this reports a wall of false
positives on its first production run, which is how a drift detector gets
switched off.

## Notifications

Opt in with `notify? true` on the source, then run the bridge:

```elixir
{AshStrangler.Listener, repo: MyApp.Repo, resources: [MyApp.Accounts.User]}
```

A legacy write becomes a real `Ash.Notifier.Notification`, re-read through Ash
so calculations, policies and tenancy apply — which is the part no generic
watcher can do, and the reason this is not simply `ecto_watch`. If you already
run `ecto_watch`, prefer it for the transport and hand its key to
`AshStrangler.Listener.notify/2`.

The payload carries the key and nothing else. `pg_notify` has a 7999-**byte**
ceiling and exceeding it is a hard error that aborts the transaction that issued
it — which is the *legacy application's* transaction. A payload built from row
data is a latent outage in the old system.

Delivery is at-most-once and in-memory: fine for cache invalidation and LiveView
reactivity, unacceptable as an audit trail. `LISTEN` is also session-scoped, so
it does not work under pgbouncer transaction pooling.

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
