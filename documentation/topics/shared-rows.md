<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Shared rows: one database, two schemas, one transaction

`ash_strangler` lets a legacy schema and a new Ash schema read and write the
**same PostgreSQL rows** while the legacy application is still alive. No sync
job, no shadow copy of the business row, no second database.

The guarantee has one premise: **one database, one transaction**. The
compatibility view, the legacy relation, the extension table, the ledger row
and the observer receipt all live behind one Postgres transaction. Cross two
databases and the guarantee is gone; that is change data capture and out of
scope.

## What lives where

| Data | Storage | Why |
|---|---|---|
| Legacy-owned attributes (`name`, flags, legacy timestamps) | Existing legacy table | The legacy application still owns and writes these columns. |
| Canonical view | A view in the new schema | Ash reads the legacy row through the declared forward mapping; writes flow back through the reverse. |
| Host-only attributes (`negotiating_notes`, provenance) | One extension table per resource | Real storage beside the shared row, keyed by the canonical primary key; no column is invented in a schema the host does not own. |
| Durable source events | `legacy_change_events` | Written by the legacy relation's trigger in the legacy transaction. |
| Projected observations + consumer receipts | `strangler_observations`, `strangler_receipts` | Derived delivery state; the source ledger remains intact. |

The Contract fixture is the runnable example: one `Contract` resource over
`legacy.clm_contracts`, with `negotiating_notes` beside it, an organization id
derived through the client party, and a lifecycle collapsed from legacy flags.
See `AshStrangler.Test.Legacy.ContractMapping` and
`AshStrangler.Test.Contract`.

## The view and its write path

The resource's `postgres` table is the compatibility view's name. Its `source`
names a typed twin for the legacy relation. Every view column comes from one
lens, which builds the forward read and (where possible) the backward write.
A mapping through a relationship adds a `LEFT JOIN`; a resource with an
extension table adds a second `LEFT JOIN` to `"<view_schema>"."<table>_extension"`.

Row-local plain renames keep Postgres' auto-updatable view path. A multi-column
write, relationship write, or extension write forces `INSTEAD OF` triggers.
Those triggers write the legacy row and extension row in one transaction;
`RETURNING` re-reads through the view so the caller gets the projected id and
state, not the unprojected input record.

The trigger trade is real: `ON CONFLICT DO UPDATE`, correct `RETURNING` and
`WITH CHECK OPTION` do not survive an `INSTEAD OF` trigger. `mix
ash_strangler.check` reports the mechanism and the emitted mechanism; it does
not hide the cost.

## The phases

1. `:read_from_legacy` — new Ash code reads the view; the legacy application
   still reads and writes its table.
2. `:dual_write` — new Ash writes go through the view and triggers; old writes
   still hit the same table. One transaction is the consistency boundary.
3. `:read_from_new` — the owned table is authoritative; the old relation name
   becomes a reverse view. The durable ledger trigger follows the owned table
   while any compatibility writer remains, because legacy writes through the
   reverse view fire no Ash notifier. `Sql.Notify` is refused here: Postgres
   rejects row-level triggers on views.
4. `:decommissioned` — compatibility objects are gone.

The backfill and reconciler are how you earn the right to move from
`:dual_write` to `:read_from_new`; a phase declaration does not prove the data
is ready. `mix ash_strangler.check` measures the rows.

## What this is not

- Not dual-database replication. One database is the premise.
- Not materialisation. The ingester writes an *owned, distinct* representation
  through host Ash actions. It does not re-run an action to make a shared-row
  change "count".
- Not exactly-once event delivery. The ledger + observer path is at-least-once;
  consumers are idempotent by `source_event_id`.
- Not a hand-maintained set of view/trigger/index declarations. The
  `strangler do ... end` declaration is the source for all of them.
