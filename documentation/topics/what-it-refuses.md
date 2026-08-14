<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# What it refuses to generate

Every check in this guide exists because the mistake it catches **does not fail on
its own**. The migration runs, the query succeeds, the row count looks right, and
the data is wrong.

That is the shape of the whole problem. A compatibility layer sits between two
applications, so when it is subtly wrong the symptom is not an exception — it is a
value that quietly differs from what either side believed. The checks below turn
those into compile errors, which is the only point at which they are cheap.

Each one names the failure it prevents, so the error message is worth reading
rather than working around.

---

## A column nobody mapped

**`VerifyCompleteMapping`**

The convenient behaviour would be to select `NULL` for any attribute the mapping
does not mention. That is also exactly how a strangler migration loses data
quietly: somebody adds an attribute to the resource, the view keeps compiling, and
the column reads `NULL` for every legacy row — in production, for months, until
somebody notices a report is wrong.

So every attribute must be accounted for: mapped, `constant`, or explicitly
`unmapped` with a reason.

```elixir
unmapped [:created_by_id], as: :null,
  because: "No provenance exists for pre-migration rows and none can be manufactured."
```

The reason is required rather than optional. It ends up in the generated
documentation and it is what a reviewer reads in eighteen months when deciding
whether the omission is still deliberate.

Generating the view is *stricter still*: it requires every attribute including
private ones, because a `SELECT` list has no notion of privacy.

---

## A computed mapping that claims to be writable

**`VerifyWritableMappingsReversible`**

PostgreSQL cannot invert `coalesce(first_name,'') || ' ' || coalesce(last_name,'')`,
and neither can this library. `'de la Cruz'` does not split back into a first and
last name by any rule you would want to rely on.

A mapping that computes a value must therefore either supply the inverse, or
declare that it has none:

```elixir
map :full_name do
  from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
  writable? false
  because "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
end
```

The `because:` text is not documentation. **It is quoted verbatim in the runtime
error** when something tries to write that attribute through the view:

```
ERROR:  cannot write users.full_name: Not decomposable: 'de la Cruz' splits
        wrong, and no rule fixes it.
```

That is the message somebody reads at 3am, which is why "not writable" is not an
acceptable reason — say what to do instead.

---

## A timestamp cast that is not deterministic

**`VerifyTimestampZones`**

This one is worth dwelling on, because it looks completely innocuous.

Most legacy schemas store naive timestamps — `timestamp without time zone` — and
the obvious mapping casts them:

```elixir
map :archived_at, "deleted_at", cast: :timestamptz   # rejected
```

`(deleted_at)::timestamptz` reads the stored value as **wall-clock time in the
session's `TimeZone`** and converts to an instant accordingly. `TimeZone` is a
per-connection setting. Measured against PostgreSQL 17.10, one row, one view:

| session `TimeZone` | resulting instant |
|---|---|
| `UTC` | `2024-06-15 12:00:00Z` |
| `America/New_York` | `2024-06-15 16:00:00Z` |
| `Australia/Lord_Howe` | `2024-06-15 01:30:00Z` |

Ten and a half hours of drift between two connections reading the same row, with
no error anywhere. A background job, a `psql` session, a replica with a different
default, or a pooled connection that inherited a `SET TimeZone` each read something
different.

So the zone has to be stated:

```elixir
map :archived_at, "deleted_at", cast: :timestamptz, from_zone: "UTC"
```

which generates `deleted_at AT TIME ZONE 'UTC'` — deterministic, because the zone
is in the view rather than in session state.

**Why not just default to UTC?** Because which zone a naive column is recorded in
is a fact about the *old application*, not about its schema. There is nothing in
the database to read it from. Defaulting would be right for most legacy systems and
silently wrong for the rest, moving every timestamp by a fixed offset — the worst
available outcome. If the column is already `timestamptz`, drop the cast instead;
`AT TIME ZONE` applied to an already-aware value converts it *back* to naive.

The write path reverses this exactly, and has to: assigning a `timestamptz` into a
naive column uses an assignment cast with the same session dependence, mirrored.

---

## Upserts on a trigger-backed mapping

**`VerifyNoUpserts`**

Attaching an `INSTEAD OF` trigger to a view removes upsert support, and does so
quietly. `ON CONFLICT DO UPDATE` starts raising *"there is no unique or exclusion
constraint matching the ON CONFLICT specification"*. Worse,
`ON CONFLICT DO NOTHING` is **accepted and then inert** — the conflict escapes as a
raw unique violation from inside the trigger function.

So `upsert?: true` is rejected on a resource whose mapping forced triggers, and the
error names **which mapping** forced them. That turns an inexplicable limitation
into a tractable one: remove that mapping, or defer that action past cutover.

### This collides with `ash_authentication`

Verified against 4.14.1:

- The **`password`** strategy does not upsert. Password-only authentication is
  migratable on the trigger path — the common case for a legacy monolith.
- The **`oauth2`** and **`oidc`** strategies **cannot be defined without an
  upsert**: their transformer validates `upsert? true` and a non-nil
  `upsert_identity`. No configuration avoids it.
- **`UserIdentity`** upserts unconditionally.

So OAuth2 and `INSTEAD OF` triggers are mutually exclusive, and adding OAuth2 to a
resource already on the trigger path is a breaking change. The verifier names the
strategy rather than just the action, because "action `:register_with_oauth2`
requires upserts" is true and useless.

---

## An identity the database does not enforce

**`VerifyIdentitiesBacked`**

An `identity` on a view is enforced by nothing. Ash will happily use it to plan
upserts and to report *"has already been taken"* — while PostgreSQL accepts
duplicates, because a view has no unique index.

Silently unenforced uniqueness on a user table is a security defect, not an
inconvenience. So every identity must either name a legacy index that actually
exists:

```elixir
index "index_users_on_login", unique: true, columns: ["login"]
```

or be explicitly marked as unenforced.

> **A related trap worth knowing:** constraint violations through a view report the
> **base table's** index name, never the view's. Ash derives the name it expects
> from the resource's configured table, so the two do not match and a raw
> `Postgrex.Error` escapes instead of a friendly `InvalidAttribute`. Declaring the
> legacy index is what lets AshStrangler wire up `identity_index_names` for you.

---

## Cutting over when it would lose columns

**`VerifyReverseMappable`**

At `:read_from_new` the legacy name becomes a view over the new table, so the old
application's `SELECT * FROM users` keeps working. That view has to produce every
column the old application reads — and it produces them by running each mapping
**backwards**.

A `writable? false` mapping is a written declaration that no backward direction
exists. The legacy columns behind it therefore cannot appear, and the old
application would read `NULL` for them **from the moment of cutover** — which is
the least recoverable moment in the entire migration.

So the phase is refused, and the offending mappings are named along with their
`because:` text. The fix is not to delete the check: it is to carry those legacy
columns across unchanged as well, or to confirm nothing still reads them.

---

## Building the view on a resource Ash would try to create

**`VerifyNotMigrated`**

A strangler resource's `table` names a view, so `migrate? false` is required in
the first two phases. Left at the default, `mix ash.codegen` emits a `create
table` for that same name and the view DDL then fails against it — the migration
cannot run at all.

The error explains the second half too, which is less obvious: `migrate? false`
*also* stops the resource producing a snapshot, and `custom_statements` are read
only from snapshots. There is no setting in which ordinary codegen can carry this,
which is why `mix ash_strangler.gen.migration` exists.

---

## What the checks cannot know

They see one version of your code and have no memory of the previous one, so they
validate the *current state*, never the *transition*. Whether `:read_from_new` is
safe depends on whether the backfill finished and the reconciler is clean — facts
about data, not about code.

That is what `mix ash_strangler.check` is for, and why it should be run before
every phase change without exception. It runs your new model's assertions as plain
SQL against the legacy data: `allow_nil? false` becomes a `count(*) WHERE col IS
NULL`, an identity becomes a `GROUP BY … HAVING count(*) > 1`, a cast becomes a
probe for values that will not convert.

It answers the question that has to come first: **is my target model even
satisfiable by this data?**
