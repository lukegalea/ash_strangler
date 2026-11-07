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

## Showing part of a relation

A branch normally shows every row of its twin. A relation that holds several kinds of row
(a parties table with a `type` column, a table where a null tenant means "not ours") can be
split across branches, or limited to the rows this resource is about, with a `filter`:

```elixir
legacy :outside do
  twin Clinic.Legacy.Contacts
  phase :read_from_legacy
  refused_because "the legacy system writes these rows"
  filter expr(kind == "outside" and not is_nil(clinic_id))
  key :id, strategy: :identity
  ...
end
```

The filter is an expression over the twin's own columns, printed as the `WHERE` of the
branch's select. A row it excludes is in no branch of the view. The filter's columns count as
read by the union in an estate, and a filter over a column the twin lacks fails compilation.

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

A union with a `tenant` column has one more hidden column per part of the
tenant key, `__tenant_p0`, `__tenant_p1`, ..., last in the view: the legacy
integers themselves, uncast (`NULL` on the owned branch). See "Tenant reads that
use the legacy index" below.

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
constant or an unmapped column), and one read from a legacy column that forms the
key. Each value is cast to the legacy column's own type. Two columns mapped from
one legacy column are refused at compile time on a `:dual_write` branch: map all
but one with `from: expr(column)`. Updating a key is refused, and so is an
insert whose supplied key is already in the view.

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

## Tenant reads that use the legacy index

`tenant = $1` on a union evaluates the packing expression for every legacy row.
Where you cannot add an expression index to the legacy tables, that is a
sequential scan. The packing is a bijection, so `AshStrangler.Inversion` decodes
`$1` once, in Elixir, and compares the hidden `__tenant_p<i>` columns instead.
The planner pushes that into each branch of the `UNION ALL`, where it meets the
index the legacy table already has on those columns.

    AshStrangler.Inversion.where_sql(MyApp.Visits, tenant_id)
    #=> (("__branch" = 'north' AND "__tenant_p0" = 7) OR ("__branch" = 'native' AND "tenant" = '...'))

    Ash.Query.filter(query, ^AshStrangler.Inversion.filter(MyApp.Visits, MyApp.Visit, tenant_id))

`filter/3` needs the resource to declare `__branch` and `__tenant_p<i>` as
attributes. Each arm names its branch with a constant, so the other branches'
arms disappear from each subquery. The owned branch keeps the original
predicate. A branch whose key kind does not decode `$1` gets no arm. Give a tenant
part the same integer type on every branch: if they differ the view widens the
column and the narrower branch is cast, which hides its index. Derived views are
not inverted: a `DISTINCT ON` sits between the predicate and the table.

## The estate check E8

List the union in an estate's `resources` and its branches claim the twin
columns they read (and write, in `:dual_write`). `AshStrangler.Estate.Phases`
then checks, for every strangled resource and every legacy branch at
`:read_from_new` or `:decommissioned`:

- **the carry rule**: every column of its relation is mapped by it, or declared
  `carried` or `dead`. A column left `deferred` or `legacy_only`, or a relation
  declared so as a whole, blocks the move, and the problem names it.
- **the lattice rule**: a relation a branch has decommissioned is read by no
  other resource or union.

A resource below `:read_from_new` is not held to the carry rule, so `deferred`
and `legacy_only` keep meaning "not needed yet".

## What this does not do

- A branch at `:dual_write` does not insert into its legacy table; inserts land
  in the owned branch.
- Derived rows (slots, jsonb elements, filters, synthesised values) and
  composite logical keys are not part of unions.
