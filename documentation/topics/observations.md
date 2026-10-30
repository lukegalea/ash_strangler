<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Observations: what shared rows did

The observation mode sits **beside** the materialisation ingester. It does not
re-run a host action to make a shared-row change "count". The ledger captures
the source write; an observer projects that captured event into a stable,
versioned envelope. A consumer that owns a distinct representation through
host Ash actions uses the separate materialisation mode (`mix
ash_strangler.gen.ingester`).

## The envelope

`AshStrangler.Observation` carries:

- `id`, `source_event_id` (ledger `bigserial`, the dedup key), `category`
  (`:baseline` or `:observation`), `resource`, canonical `record_id`,
  `operation` (`:insert`, `:update`, `:delete`, `:invalidate`);
- `before`, `after`, `changed_attributes`, `invalidated_attributes`;
- `origin` (`:host`, `:legacy`, `:unknown`), `attribution` (actor + confidence),
  `correlation_id`, `causation_id`;
- `mapping_version`, `source` (relation, primary key, transaction id/timestamp),
  `captured_at`, `recorded_at`.

The projector renders each lens against the ledger's old/new jsonb row images,
through the same SQL printer and the twin's PostgreSQL types. Row-local
legacy-backed attributes are exact. Joined reads are not history in the event
row: they are excluded from before/after and emitted as invalidations when the
source relation changes. Extension columns are not in the legacy row, so they
are unprojected too; their shared-row state is read from the forward mapping.

`mapping_version` is the SHA-256 canonical hash of the mapping. A value change
under a different mapping version is a meaning change; consumers re-baseline
rather than diffing unlike representations.

## Capture, projection and receipts

One trigger on the legacy relation writes the ledger row in the legacy write's
transaction and sends a key-only wake. `AshStrangler.Observation.Processor`
claims unprocessed rows `FOR UPDATE SKIP LOCKED` in id order, **without**
setting `processed_at` (the materialisation ingester owns that column),
projects them idempotently into `strangler_observations`, and delivers each to
the source's `observers: [...]`.

Receipts are per `(consumer, observation_id)`:

- `:ok` closes delivery for that consumer;
- `{:error, reason}` increments attempts and retries; at
  `Application.get_env(:ash_strangler, :observer_max_attempts, 5)` it
  quarantines;
- `{:quarantine, reason}` quarantines immediately.

The observation insert and the observer callback + receipt share one repo
transaction. Same-database effects are transactional with the receipt. For
external effects, enqueue to the consumer's outbox inside that transaction and
be idempotent by `source_event_id`.

Delivery is **at-least-once**, never exactly-once. Ledger id order is NOT
commit order: there is no `WHERE id > last` cursor, because a lower id may
commit after a higher one. Consumers reconcile using `source_event_id` and
`transaction_id`.

## Correlation context

Wrap host writes with `AshStrangler.Context.set/3`:

```elixir
AshStrangler.Context.set(Repo, [
  origin: :host,
  actor: user.id,
  correlation_id: correlation_id,
  causation_id: command_id
], fn ->
  Ash.create!(Contract, params)
end)
```

It sets transaction-local `ash_strangler.*` custom GUCs. The trigger copies
them into the event and marks `actor_confidence: 'asserted'` when any context
is present. Absent context stays absent: origin `:unknown`, no fabricated
`:legacy`. Capture is never suppressed by missing context.

## Baseline at watch start

`mix ash_strangler.baseline MyApp.Clm.Contract --repo MyApp.Repo` takes a
`REPEATABLE READ` snapshot, reads the ledger `max(id)` inside it, keyset-scans
the legacy relation, and projects each row as `category: :baseline` with one
`baseline_group`. The trigger is already installed, so every commit outside
the snapshot is in the stream. No `MAX(id)` fence: commit order is not id
order, and a fence would lose rows.

A baseline says **"row seen as executed"**, never **"execution happened
now"**. Baselines are idempotent per `(record_id, resource, baseline_group)`
(no-op re-run with the same group); a new group is a new snapshot. A stream
event older than the baseline may arrive after it; consumers reconcile via the
source event and transaction ids.

## Inspect and replay

```sh
mix ash_strangler.observations --resource MyApp.Clm.Contract
mix ash_strangler.observations --quarantined --consumer MyApp.Observer
mix ash_strangler.observations --inspect <observation-uuid>
mix ash_strangler.observations --replay --consumer MyApp.Observer
mix ash_strangler.observations --replay --observation-id <observation-uuid>
```

Replay resets receipts; it never deletes observations or truncates the
source ledger. The next drain re-delivers to the selected consumer, whose
idempotence contract is still `source_event_id`.

## Events vs observations

The AshEvents event log records **the command the host ran** (`Contract.archive`).
The observation records **the row change the ledger saw** (legacy `archived`
changed). They are different kinds of record with different replay semantics.
`mix ash_strangler.gen.events_bridge` renders a read-only companion resource
over `strangler_observations` for a unified timeline; it has no write actions,
so observations cannot be replayed as commands.
