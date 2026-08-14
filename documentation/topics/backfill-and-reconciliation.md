<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Backfill and reconciliation

Two operations run during `:dual_write`, and between them they decide whether you
are allowed to cut over. The **backfill** populates data that did not exist
before — a tenant id, a derived key, a column the legacy schema never had. The
**reconciler** answers the question the phase model cannot: are the two shapes
actually holding the same rows?

Neither is a phase. Both are things you run, repeatedly, while both applications
keep serving traffic.

Neither module reads the `strangler` DSL, and that is deliberate. A backfill is
the one operation an operator wants to run against a table the Ash model does not
describe yet — a column added by hand, a partially-migrated tenant, a rerun after
an incident. Tying it to a compiled resource would make the emergency path the one
that needs a deploy.

---

# The backfill

```elixir
AshStrangler.Backfill.add_flag_column!(MyApp.Repo, "legacy.users")

{:ok, result} =
  AshStrangler.Backfill.run(MyApp.Repo,
    relation: "legacy.users",
    key: "id",
    set: [tenant_id: "'0f0e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid"],
    batch_size: 5_000,
    progress: fn done, total -> IO.puts("#{done}/#{total}") end
  )

AshStrangler.Backfill.drop_flag_column!(MyApp.Repo, "legacy.users")
```

That is the whole API. What follows is why each mechanism is the one it is,
because every alternative here fails silently rather than loudly.

## The flag column, and why not `WHERE new_col IS NULL`

`add_flag_column!/3` adds one column:

```sql
ALTER TABLE "legacy"."users"
  ADD COLUMN IF NOT EXISTS "_strangler_needs_backfill" boolean NOT NULL DEFAULT true
```

The obvious alternative is to skip the column and batch on the work itself —
`WHERE tenant_id IS NULL`. That predicate is wrong the moment the *correct* value
of the target column can legitimately be null, and `unmapped [...], as: :null`
guarantees that case exists in a strangler mapping. When the backfill's job is to
write `NULL`, a finished row becomes indistinguishable from a pending one: the
batch re-selects it forever and the loop never terminates. **The failure is a hung
job, not an error** — every pass does real work, updates real rows and reports real
progress, so nothing in the counters ever looks wrong.

The approach is taken from `pgroll`'s implementation, which adds
`_pgroll_needs_backfill boolean DEFAULT true` and batches on it for the same
reason.

Three details of that `ALTER TABLE` are load-bearing:

- **`DEFAULT true` is a constant**, so on PostgreSQL 11 and later this is a
  catalog-only change: no table rewrite, and the `ACCESS EXCLUSIVE` lock is held
  for microseconds rather than for the length of a full rewrite. A *volatile*
  default — `gen_random_uuid()`, or a stored generated column — does rewrite,
  which is why the expand step adds nullable columns and backfills them instead of
  adding a defaulted `uuid` column.
- **`NOT NULL DEFAULT true` means rows the legacy application inserts *after* this
  runs arrive flagged**, and so get backfilled. The flag is cleared by a row having
  been processed, not by it having existed when the backfill started.
- **`IF NOT EXISTS`, never `DROP` then `ADD`.** The `DROP`/`ADD` pairing is the
  obvious way to make setup idempotent, and it silently restarts a
  forty-million-row backfill from zero.

Contract the column only once nothing still writes to it. A trigger that assigns
to a dropped column fails every write on the legacy table.

## One batch, one transaction, keyset paginated

Each batch is a single statement inside its own committed transaction:

```sql
WITH strangler_batch AS (
  SELECT "id" AS strangler_key
  FROM "legacy"."users"
  WHERE "_strangler_needs_backfill" AND "id" > $1
  ORDER BY "id"
  LIMIT 5000
  FOR NO KEY UPDATE
)
UPDATE "legacy"."users" AS strangler_target
SET "tenant_id" = '0f0e…'::uuid, "_strangler_needs_backfill" = false
FROM strangler_batch
WHERE strangler_target."id" = strangler_batch.strangler_key
RETURNING strangler_target."id"
```

**Keyset pagination, never `OFFSET`.** `OFFSET n` re-walks and discards `n` rows on
every batch, so the cost of a backfill is quadratic in table size and its last
batches are its slowest. Worse, `OFFSET` is only stable if the ordering is stable,
and a backfill mutates the very rows it is ordering over.

**One committed transaction per batch.** The tempting single large `UPDATE` holds
every row lock for the whole run, pins the global xmin so `VACUUM` reclaims
nothing *cluster-wide* for the duration, and cannot be resumed: kill it at 90% and
90% is lost.

**`FOR NO KEY UPDATE`, not `FOR UPDATE`.** Both lock the batch's rows against
concurrent update; only `FOR UPDATE` additionally blocks a concurrent foreign-key
check referencing them. A backfill is not changing the key, so it has no reason to
make every FK check on a busy child table queue behind it.

There is no `lock_timeout` on the batches, unlike on the DDL. These are row locks
behind ordinary application writes, and aborting a batch because one row was
briefly locked would turn a busy table into a backfill that never finishes.

The new cursor is `max` of the returned keys, not `List.last/1`: `RETURNING` makes
no ordering promise, and a cursor that is not the true maximum silently re-reads
rows that are already done — or, if it is too high, skips rows forever.

## Passes: why a cursor alone is not enough

The cursor lives in memory for the duration of a run and is deliberately not
persisted anywhere. It does not need to be, because **the flag column *is* the
persisted state.** An interrupted run resumes by being called again, from a
different machine if necessary, with no coordination and no cursor file to go
stale.

That also fixes a hazard a persisted cursor cannot. `bigserial` values are handed
out in order but *committed* out of order, so a row can appear with a key *below*
a cursor that has already gone past it. This is ordinary on a live table, not
exotic. So the loop is two levels deep:

```mermaid
flowchart TB
    entry(["run/2"]) --> minkey{"min(key)<br/>WHERE flag"}
    minkey -- "nothing pending" --> done(["complete? true"])
    minkey -- "a key" --> pass["start a pass at that key"]
    pass --> batch["one batch:<br/>select, lock, update, commit"]
    batch -- "rows returned" --> cursor["cursor = max(keys)"]
    cursor --> batch
    batch -- "nothing above the cursor" --> minkey
```

Each pass sweeps upward from `min(key) WHERE flag` rather than from "the
beginning" — on a table that is 39/40ths done, starting at the beginning means
walking 39 million index entries to find the first row that matters, every time
the job restarts. When a pass exhausts, the minimum pending key is recomputed and
another pass sweeps; only when nothing is pending does the run stop.

`result.passes` greater than one is therefore normal on a live table, and is
information rather than a warning.

## The two anti-spin guards

Both of these detect situations that would otherwise loop forever while looking
exactly like a slow job.

**A pass that starts where an earlier pass started raises.** Clearing the flag is
durable, so the only ways a completed key becomes pending again are something
re-setting the flag — a trigger on the legacy table that fires on the backfill's
own `UPDATE` is the realistic one — or the key being deleted and reinserted.
Nothing in the counters would ever look wrong: every pass does real work and
reports real progress, and the job simply never finishes.

**Three consecutive passes that update nothing raise**, if `min(key) WHERE flag`
is still returning a row. That combination means something outside the process is
holding rows in a state the loop cannot act on. Continuing would spin, so it
stops.

## Fitting a backfill into a maintenance window

`:max_batches` stops the run after that many committed batches and reports
`complete?: false`. Resuming is calling `run/2` again — there is nothing else to
do, because the flag column carries the state.

```elixir
{:ok, %{complete?: false, rows: rows}} =
  AshStrangler.Backfill.run(MyApp.Repo,
    relation: "legacy.users",
    key: "id",
    set: [legacy_id: "id"],
    max_batches: 200
  )
```

`run/2` takes `:relation` and `:key` (required), plus `:set`, `:batch_size`
(default `1_000`), `:flag_column`, `:progress`, `:max_batches` and `:total`. It
returns `{:ok, result}` where `result` is:

| Field | Meaning |
|---|---|
| `:rows` | rows actually updated — not an estimate |
| `:batches` | committed batch transactions |
| `:passes` | sweeps from `min(key) WHERE flag` |
| `:total` | the row-count estimate reported to `:progress`, for reference |
| `:complete?` | false only when `:max_batches` stopped the run early |

`:total` comes from `pg_stat_user_tables.n_live_tup`, which is free, falling back
to an exact `count(*)` when the estimate is `0` — which is exactly the state a
freshly loaded table is in before autovacuum has visited it, and a progress bar
reading `1000/0` is worse than no progress bar.

`AshStrangler.Backfill.pending_count/3` gives an exact `count(*)` of flagged rows.
It is a diagnostic, not something to call in a loop.

## `:set` values are SQL, on purpose

Values in `:set` are interpolated verbatim, not bound. This is a SQL generator,
and the point is to push the work into the database rather than pull forty million
rows through the BEAM. They are evaluated against the row being updated, so
`[counter: "counter + 1"]` is legal and means what it says, and `[legacy_id: "id"]`
is how the legacy key gets carried across for the reverse view to expose later.

Column names are validated as plain SQL identifiers; values are not touched at
all. That asymmetry is the contract — there is no bind-parameter form for a column
name, so validation is the only defence available on the left-hand side, and the
right-hand side is an expression by design.

## DDL under a lock timeout

`AshStrangler.Backfill.with_lock_retry/3` is public because every DDL statement a
strangler migration issues wants this treatment, not just the two in this module:

```elixir
AshStrangler.Backfill.with_lock_retry(MyApp.Repo, [lock_timeout: 3_000], fn ->
  MyApp.Repo.query!("ALTER TABLE legacy.users ADD COLUMN IF NOT EXISTS row_uuid uuid", [])
end)
```

A DDL statement waiting for `ACCESS EXCLUSIVE` goes to the **head** of the lock
queue, and every subsequent `SELECT` queues behind it. One long-running reader plus
one waiting `ALTER TABLE` takes the table offline for everyone — the `ALTER` has
not run, and the reads are not running either. A short `lock_timeout` converts that
outage into a retry, on SQLSTATE `55P03` only. `statement_timeout` is not a
substitute: it also kills a DDL that has already acquired its lock and is doing
legitimate work, which is the one case you want to leave alone.

Each attempt is its own transaction, with `mode: :savepoint`. A failed statement
poisons its transaction — everything after it errors with `25P02 current
transaction is aborted` — so retrying inside the transaction that just took the
`55P03` cannot succeed. It fails with a different, more confusing error, and does
so instantly, so the backoff appears to work while never actually retrying
anything. Since Ecto runs migrations inside a transaction, and this function is
called from migrations, the savepoint is the difference between a working retry
loop and a decorative one.

## What the backfill does not do

It issues no `CREATE INDEX CONCURRENTLY`. A partial index on `(key) WHERE flag` is
the right way to keep resumption cheap on a large table, but CIC cannot run in a
transaction block, and on failure it leaves an *invalid* index behind that still
costs write throughput — so it needs a `pg_index.indisvalid` check and a migration
of its own. That belongs with a migration, not in a loop that is expected to be
safe to kill at any moment.

---

# The reconciler

Drift detection between two relations that are supposed to hold the same rows: a
legacy table and the compatibility view over it, or the legacy table and the new
table during dual-write.

```elixir
config = [
  legacy: [relation: "legacy.users", key: "id"],
  view: [relation: "strangler.users", key: "__legacy_id"],
  columns: [
    email: "email",
    full_name: {"coalesce(first_name,'') || ' ' || coalesce(last_name,'')", "full_name"}
  ],
  normalize: %{email: :ci_string}
]

%{agrees?: true} = AshStrangler.Reconciler.diff(MyApp.Repo, config)
```

`diff/2` runs counts first, then per-batch checksums, and returns structured data.
It logs nothing and decides nothing.

Each entry in `:columns` is `name: "expression"` when both sides spell it the same
and `name: {legacy_expression, view_expression}` when they do not. Both halves are
SQL *expressions*, not identifiers, because the usual reason a column needs
reconciling is that it is
`coalesce(first_name,'') || ' ' || coalesce(last_name,'')` on one side and a
single column on the other.

## The same function is the scheduled job and the test assertion

The Oban job that runs nightly and the test that asserts a mapping is faithful call
the identical function and read the identical map. That is not tidiness: the drift
check *is* the correctness oracle for this package, so if the production checker
and the test checker were different code, the tests would certify something nobody
is running.

Which raises the obvious question — who checks the checker? Every mutation the
reconciler can detect is proven in `test/ash_strangler/reconciler_test.exs` by
deliberately introducing that mutation and asserting it is found. A drift detector
nobody has proven can detect drift is worse than no drift detector, because it
manufactures confidence.

## Counts

```elixir
AshStrangler.Reconciler.count_drift(MyApp.Repo, config)
#=> %{agrees?: false, legacy: 40_112_004, view: 40_111_998, drift: 6}
```

Cheap, and the first thing worth knowing. `drift` is `legacy - view`, signed, so
the direction is legible without comparing the other two numbers. Both counts come
from a single statement, for the reason in the next section.

## Checksums

```elixir
%{agrees?: false, mismatched: [batch | _], columns: columns} =
  AshStrangler.Reconciler.checksum_drift(MyApp.Repo, config)

batch
#=> %{agrees?: false, lower: 8001, upper: 9000, rows: 1000,
#     legacy: "3f1c…", view: "9ab4…"}
```

The key space is walked in `:batch_size` ranges (default `1_000`) and each side of
each range is md5'd. The answer to "where is the drift" is therefore a key range a
human can go and look at, rather than "somewhere in forty million rows".
`:mismatched` is the sublist of `:batches` that disagreed — the thing to open.

Checksums run even when the counts agree, because equal counts with unequal values
is the interesting failure: a mapping that reads the wrong column keeps the row
count perfect.

Four decisions inside that pass are worth knowing about, because the obvious
implementation gets each of them wrong.

**Batch bounds come from the `UNION` of both sides' keys.** Batching off the legacy
side alone is the obvious implementation and it is unsound: a key that exists only
in the view falls outside every range, so the pass reports agreement for a row it
never looked at. The union costs one more index scan and closes the hole. `rows` on
each batch is the count of distinct keys across *both* sides, so a row present on
only one of them still counts.

**Both checksums are computed in one statement.** Under `READ COMMITTED` each
statement takes a fresh snapshot, so two separate `SELECT`s see two different
states of the database and any concurrent write between them looks exactly like
drift. A nightly job on a live table would report drift more or less at random.
Both sides are therefore scalar subqueries of a single statement, sharing the batch
bounds as bind parameters — the two sides must be given literally the same range,
not two renderings of it.

**The per-row encoding has to be injective, and the obvious one is not.**
`concat_ws('|', a, b)` *skips* nulls rather than encoding them, so it moves a
column boundary: `(NULL, 'a|b')` and `('a', 'b')` both render as `a|b`, and a row
that lost a value to NULL is reported as agreeing with one that did not. Checked
on 17.10, `concat_ws` *does* distinguish `NULL` from `''` when neither is at a
boundary — which makes this the more dangerous kind of bug, because it is right in
the case you would test by hand. Every value is therefore wrapped in
`quote_nullable`, which renders `NULL` as the bare word `NULL` and everything else
as a quoted, escaped literal, so nothing in a value can imitate a separator and
nothing can be omitted.

**`ORDER BY` goes inside `string_agg`, not outside.** Without it the aggregation
order is whatever the scan produced, so an `UPDATE` that moved one row to the end
of the heap on one side changes that side's checksum and nothing else. The drift
would be real-looking, reproducible, and entirely fictional.

## Normalization, and why it is not optional

Ash normalises values on the way in. `Ash.Type.CiString` defaults to
`trim?: true`, so `" alice@example.com"` written *through Ash* is stored trimmed,
while the identical value written by the legacy application is stored as given.
The same applies to any Ash type with normalising constraints.

**Both are correct.** Each side stores what it is supposed to store. This is not a
defect the mapping can fix, and it should not try — the entire reason to adopt Ash
is that it validates and normalises. But it means "the two write paths agree" is
false by construction for some columns.

A comparison that does not know this reports every such row as drift, forever. And
a drift report that is mostly false positives gets muted, which is how a team ends
up with a drift detector and no drift detection. That is the failure the
normalization hook exists to prevent, and it is a human failure rather than a
technical one, which is why it is worth being explicit about.

```elixir
normalize: %{
  email:       :ci_string,                      # lower(btrim(...)) — trim? and case-insensitivity
  login:       :trim,                           # btrim(...)
  archived_at: {:sql, "%s AT TIME ZONE 'UTC'"}, # a naive timestamp against a timestamptz
  weird:       fn expr -> "my_fn(#{expr})" end
}
```

Three design decisions in that hook:

- **It is SQL, not Elixir.** The entire value of a checksum is that the comparison
  happens in the database over whole batches. A normalizer that forced rows into
  the BEAM would defeat the mechanism it is part of.
- **It is applied to *both* sides.** Applying it only to the legacy side would
  assume Ash's normalisation is idempotent — usually true, never guaranteed.
  Applied to both, the comparison stops being "are these bytes equal" and becomes
  "are these values equal *modulo the transformation Ash performs*", which is the
  question actually being asked.
- **The shorthands are named after the cause, not the effect.**
  `normalize: %{email: :ci_string}` records *why* the column needs normalising —
  because the Ash attribute is an `Ash.Type.CiString` — where
  `"lower(btrim(%s))"` would leave the next reader to reverse-engineer it.

`{:sql, template}` substitutes the column expression for each `%s`. The
`archived_at` line above is the second real case: a naive `timestamp` and a
`timestamptz` render differently as text, so comparing them without stating the
zone compares a rendering artefact.

A normalizer the reconciler does not recognise raises rather than being ignored.
Silently ignoring it would mean the column is compared un-normalised and the report
fills with exactly the false positives the config was written to prevent.

One caution that no code can enforce: a normalizer is a way to ignore a *known,
explained* transformation, not a way to stop looking at a column. `{:sql, "'x'"}`
would make any column agree with itself forever. Keep them as narrow as the
divergence they describe.

## Running it

As a test, against a fixture:

```elixir
test "the users mapping is faithful" do
  assert %{agrees?: true} = AshStrangler.Reconciler.diff(MyApp.Repo, users_config())
end
```

As a scheduled job, where the output matters more than the boolean:

```elixir
def perform(_job) do
  case AshStrangler.Reconciler.diff(MyApp.Repo, users_config()) do
    %{agrees?: true} ->
      :ok

    %{counts: counts, checksums: %{mismatched: mismatched}} ->
      Logger.error("""
      strangler drift on MyApp.Accounts.User
        counts: #{inspect(counts)}
        ranges: #{Enum.map_join(mismatched, ", ", &"#{&1.lower}..#{&1.upper}")}
      """)

      {:error, :drift}
  end
end
```

---

## The order these come in

1. Enter `:dual_write` and ship the write path.
2. `add_flag_column!/3`, then `run/2` until `complete?: true` and
   `pending_count/3` returns `0`.
3. `diff/2` until `agrees?: true`, with a normalizer for each column where Ash and
   the legacy application legitimately disagree — and a note in the config saying
   which divergence each one describes.
4. Keep the reconciler running on a schedule for as long as both applications
   write. It is the only thing that will tell you a legacy code path you did not
   know about is still writing values your mapping cannot round-trip.
5. Only then move to `:read_from_new`. An incomplete backfill at cutover produces
   missing rows, not an error.
