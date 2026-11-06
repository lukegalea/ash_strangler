<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Union sources

A resource sometimes has more than one legacy source, and rows the legacy
systems never had. A clinic merged two practices: each has its own visits
table, and the new system adds visits of its own. `AshStrangler.Union` presents
all of it as one relation, a view over

- one or more **legacy branches**, each a twin with its own phase, and
- one **owned branch**, a table the union creates for rows that exist only in
  the new system.

```elixir
defmodule Clinic.Visits do
  use AshStrangler.Union

  union do
    schema "clinic"
    view "visits"

    column :patient, :string, null?: false
    column :visited_on, :date
    column :notes, :string

    legacy :north do
      twin Clinic.Legacy.NorthVisits
      phase :read_from_legacy
      refused_because "the north system writes these rows until its cutover"
      key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
      map :patient, from: :patient_name
      map :visited_on, from: :seen_on
      unmapped [:notes], because: "the north system keeps no notes"
    end

    legacy :south do
      twin Clinic.Legacy.SouthVisits
      phase :dual_write
      refused_because "the south system writes these rows until its cutover"
      key :id, strategy: {:uuid_v5, namespace: "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d"}
      map :patient, from: :name
      map :visited_on, from: :date
      map :notes, from: :remarks
    end

    owned :native
  end
end
```

List the module under `config :ash_strangler, unions: [Clinic.Visits]` and
`mix ash_strangler.gen.migration` generates it with everything else. Point an
Ash resource at the view with `migrate? false`. The resource does not carry a
`strangler` block: the view is its table.

## What is generated

In order: the owned table (`"<view>_owned"` unless `owned` names one), a key
index per legacy branch, the view, and `INSTEAD OF` insert, update and delete
triggers. Every statement is one idempotent SQL command, like the rest of the
package.

The view has the key, `__branch` (the branch's name for each row), then the
declared columns. Each branch casts each column to its declared type, so
branches with different legacy types still union. Keys of different branches
must not collide: each branch derives its own with `uuid_v5` (its own
namespace) or `uuid_v8` (its own kind), and the compiler refuses two branches
that share one. The owned table's keys default to `gen_random_uuid()`.

## Writes

| Write | `:read_from_legacy` | `:dual_write` |
|---|---|---|
| insert | owned branch | owned branch |
| insert naming a legacy branch | refused | refused |
| update or delete of an owned row | owned table | owned table |
| update or delete of a legacy row | refused with `refused_because` | carried to the legacy table |

Insert always lands in the owned branch, and the trigger returns the row it
stored, so `RETURNING` carries the key and every default. In `:dual_write`, an
update writes the columns the branch renames (`map :x, from: :column`) and
refuses a changed column that has no legacy column behind it (an expression, a
constant or an unmapped column). Updating a key is refused, and so is changing a
column that is read from a twin column the key packs (writing it would re-key
the row). Each write is cast to the legacy column's own type, so a declared type
that differs from the legacy one still assigns, and a branch may not write one
legacy column from two union columns (`VerifyUnion` refuses it; derive all but
one with an expression). An insert that supplies a key already naming a live
row of the view is refused instead of duplicating the id.

A refusal is an `AshStrangler.Error.BranchWriteRefused` carrying the branch,
phase, operation and the declared reason. The triggers raise it in the
`ash_error:` form AshPostgres turns back into the exception, so an Ash action
over the view returns it inside `Ash.Error.Invalid`.

A branch in `:read_from_new` or `:decommissioned` has left the view: its rows
are expected to be in the owned table already (the backfill is the host's), and
the estate check below holds the cutover to that.

## Concurrency

A branch's phase is compiled into the trigger functions, so changing it is
`CREATE OR REPLACE FUNCTION`: transactional DDL that does not block writers.

- A write whose trigger fires before the change commits runs under the old
  phase and completes. One that fires after it runs under the new phase, even if
  its transaction began earlier.
- An insert never reads a phase, so an insert racing a phase change succeeds in
  the owned branch.
- Two concurrent owned inserts do not interact. Two inserts of the same
  supplied key conflict on the owned table's primary key; the second waits for
  the first to finish and then fails with `unique_violation` (`23505`).
- Regenerating the whole migration also replaces the view, which needs a lock on
  it and so waits for in-flight statements; apply only the function statements
  when moving a branch between `:read_from_legacy` and `:dual_write`.

## What a host verifier can read

`AshStrangler.Union.Info` reports the declarations, and `lens_kinds/2` the lens
of every column on a branch: `:column`, `:expression`, `:constant`, `:null`,
`:owned`, or `:key`. `twin_derived?/1` is true for the kinds that read the twin
(`:column`, `:expression`, `:key`). A host check that a dimension is
always derived from the twin on every legacy branch reads exactly this, and
`phase/2`, `resource_phase/1` and `live_branches/1` give the phases.

## The estate check E8

List the union in an estate's `resources` and its branches claim the twin
columns they read (and write, in `:dual_write`). `AshStrangler.Estate.Phases`
then checks, for every strangled resource and every legacy branch at
`:read_from_new` or `:decommissioned`:

- **the carry rule**: every column of its relation is mapped by it, or declared
  `carried` or `dead`. A column left `deferred` or `legacy_only`, or a relation
  declared so as a whole, blocks the move, and the problem names it. So does a
  column that only another module maps, such as a derived view reading a jsonb
  column: the moved branch's storage would not hold it.
- **the lattice rule**: a relation a branch has decommissioned is read by no
  other resource or union.

A resource below `:read_from_new` is not held to the carry rule, so `deferred`
and `legacy_only` keep meaning "not needed yet".

## What this does not do

- A branch at `:dual_write` does not insert into its legacy table; inserts land
  in the owned branch.
- Derived rows (slots, jsonb elements, filters, synthesised values) and
  composite logical keys are not part of unions.
