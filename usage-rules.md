<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Rules for working with AshStrangler

AshStrangler maps an Ash resource onto a legacy Postgres relation for a
strangler-fig migration. All four phases generate SQL; backfill, reconciliation
and a notification bridge to `Ash.Notifier` exist.

## The phase model

`phase` is the single control knob. An agent that does not know which phase a
resource is in cannot judge whether a change is safe.

| Phase | Reads from | Writes to | Safe to change |
|---|---|---|---|
| `:read_from_legacy` | legacy, via the view | nothing | freely |
| `:dual_write` | legacy | both | after backfill starts |
| `:read_from_new` | new tables | both | **only when backfill is complete** |
| `:decommissioned` | new tables | new tables | only when nothing writes legacy |

Phase changes are **one-way in practice**. Moving to `:read_from_new` with an
incomplete backfill produces missing rows, not an error.

## Rules

1. **The DDL comes from `mix ash_strangler.gen.migration`, NOT `mix
   ash.codegen`.** A strangler resource must declare `migrate? false`, and the
   compiler enforces it: left at the default, codegen emits a `create table` for
   the view's own name and the view DDL then fails against it. But `migrate?
   false` also stops the resource producing a snapshot, and `custom_statements`
   are only read from snapshots — so there is no configuration in which codegen
   can carry this. Never hand-edit a generated migration; edit the mapping and
   regenerate.

2. **`writable? false` requires `because:`, and the text is user-facing.** It
   appears in the runtime error raised when something tries to write the
   attribute. "not writable" is not an acceptable reason; say what to do instead.

3. **Every attribute must be accounted for.** Mapped, `constant`, or listed in
   `unmapped ... because:`. An unmentioned attribute would read NULL for every
   legacy row — silent data loss, not a failure.

4. **`upsert?: true` is available only on `writes: :auto` mappings.** Against a
   view with an `INSTEAD OF` trigger, `ON CONFLICT DO NOTHING` is accepted and
   silently does nothing. If the compiler rejects an upsert, change the mapping
   or do not strangle that resource — do not work around the verifier.

5. **`oauth2` and `oidc` cannot be strangled with triggers.** Their
   `ash_authentication` transformer requires `upsert? true`; it is not
   configurable. The `password` strategy is fine.

6. **Adding an attribute to a strangler-backed resource is a schema change**,
   because the view's `SELECT` list must grow. Regenerate.

7. **Every Ash identity needs a declared `index ... unique: true`.** Otherwise
   Ash reports "has already been taken" for a constraint Postgres does not
   enforce, and duplicates are accepted with no error.

8. **Never compute a modern id by querying for it.** Use
   `AshStrangler.KeyDerivation.derive/3` (or `uuid_v5/2` + `name/2`), which is a
   pure function and is asserted to agree byte-for-byte with the SQL the view
   uses. Do not reimplement the hashing or re-spell the `"<relation>:<id>"`
   name format anywhere — both sides go through `name_prefix/1` precisely so
   they cannot drift, and a drift produces `Ash.get/2` returning nothing for
   rows that exist.

9. **`cast: :timestamptz` requires `from_zone:`, and the compiler enforces it.**
   A bare cast on a naive legacy `timestamp` reads the value as wall-clock time
   in the *connection's* `TimeZone`, so different connections see different
   instants with no error. State the zone the legacy column is recorded in
   (`from_zone: "UTC"`). If the column is already `timestamptz`, drop the
   `cast:` instead — do not supply a zone, because `AT TIME ZONE` on an
   already-aware value converts it back to naive.

10. **The mapped primary key must not be declared with a default, and does not
    need `generated? true` written by hand** — the extension sets it, because
    the view computes the id and Ash would otherwise reject every create with
    `attribute id is required`. Declare it plainly:
    `attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false`.

11. **Expect Ash's own casting to differ from what the legacy app writes.**
    `Ash.Type.CiString` trims by default, so during `:dual_write` a value
    written through Ash may not be byte-identical to the same value written
    directly by the old application. This is not a bug to fix in the mapping;
    it is a real divergence to account for when comparing the two paths.

12. **Run `mix ash_strangler.check` before every phase change.** No exceptions.
   It reports what compile-time verification cannot know: whether the backfill is
   complete, whether the legacy write path is dead, whether the reconciler is
   clean.

13. **Backfill with the flag column, never `WHERE new_col IS NULL`.** Use
    `AshStrangler.Backfill`. An `IS NULL` predicate cannot terminate once a
    target column's correct value may legitimately be null, which
    `unmapped ..., as: :null` guarantees.

14. **`:read_from_new` is a one-way door and the compiler treats it as one.**
    Every mapping must be reversible, because the legacy name becomes a view
    over the new table and the old application still reads those columns. A
    `writable? false` mapping blocks the phase by design — do not work around
    `VerifyReverseMappable`, carry the legacy columns across instead.

15. **`cast: :citext` folds differently depending on the database collation.**
    citext folds by calling SQL `lower()`, which follows `LC_CTYPE`. Under `C`
    only ASCII folds; under a UTF-8 locale non-ASCII case folds too. The same
    mapping therefore gives a *different uniqueness answer* on two servers —
    and a strangler migration has two servers in it by definition. Check the
    collation on both before relying on a citext identity, and never assume
    what holds in development holds in production. It never folds whitespace,
    and never normalizes NFC against NFD, under any collation.

16. **Notifications are opt-in (`notify? true`) and at-most-once.** Never build
    a `pg_notify` payload from row data: the ceiling is 7999 bytes and
    exceeding it aborts the *legacy application's* transaction. Never use them
    to count writes — Postgres collapses duplicates within a transaction.

## What the verifiers cannot check

They see one version of the code and have no memory of the previous one, so they
validate the *current state*, never the *transition*. Whether `:read_from_new` is
safe depends on the state of the data. That is `mix ash_strangler.check`.
