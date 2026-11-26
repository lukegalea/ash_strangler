<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Facades

A facade is an Ash resource with no storage of its own
(`data_layer: Ash.DataLayer.Simple`) that gives a different vocabulary to the
rows of one **source** resource. It reads by calling the source's read action
*as the caller*, and each write runs one named source action *as the caller*.
It declares no rule about who may see or change anything — the source's
policies and field policies decide, because every fact keeps one record, on
the source.

Where a strangled resource moves rows out of a legacy relation, a facade moves
*words*: the same rows, named the way one consumer already speaks. A task
source speaks of `status`; the work-tracking view of it speaks of `state`.

```elixir
defmodule MyApp.WorkItem do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :state, :atom, public?: true, constraints: [one_of: [:new, :finished]]
    attribute :effort_minutes, :integer, public?: true
    attribute :licence_number, :string, public?: true, sensitive?: true
  end

  facade do
    source MyApp.Task            # the row source (an Ash resource)
    read_action :read            # the source's read action; default :read

    map :id, from: :id
    map :title, from: :name
    decode :state, from: :status, values: %{done: :finished}
    map :effort_minutes, from: :estimate_minutes
    map :licence_number, from: :number

    hide :internal_notes, because: "Not part of this vocabulary."
    defer :legacy_ref

    # Writes: each is a generic action on the facade that runs ONE named
    # source action.
    write :finish, via: :complete, sets: [state: :finished]              # by value
    write :set_estimate, via: :set_estimate, accepts: [:effort_minutes]  # by acceptance
  end
end
```

The mapping grammar is the strangler's: `map`, `decode`, `collapse`,
`coalesce`, `concat`, `negate`, `affine`, `constant` and `unmapped` are the
same entities (`AshStrangler.Dsl.mapping_entities/0`), so one lens describes a
view over Postgres and a facade over an Ash resource. `key` and `reference`
are absent on purpose — a facade reads a source that already holds its own
keys.

## What a read does

`AshStrangler.Facade.Read` calls the source's read action with the caller's
`actor`, `tenant`, `authorize?` and `as_of`. The whole `query.filter`
travels — the policy filter included — translated by
`AshStrangler.Translate.filter/3`; the sort by `Translate.sort/2`; `limit` and
`offset` are passed. A translation error is an error, never a dropped filter:
dropping one widens the result. Filters and sorts on a facade attribute whose
lens reads a calculation or aggregate load that calculation on the source
query first.

Each facade attribute is evaluated with `AshStrangler.Eval.forward/3` over the
row the source returned. The forward lens is deliberately **not** a source
calculation: Ash applies no field policy to a column an expression reads, so
computing there would bypass the source's decisions. A source value the caller
was refused becomes a `%Ash.ForbiddenField{}` named for the *facade*
attribute — and a value computed from one (`concat`, `decode`) is forbidden
too, never a computed value. The source row's primary key is kept as the
record's `:source` metadata.

Three limits are facts, not oversights:

- **Offset pagination only, and no count.** Ash reports no count for a manual
  read, and keyset cursors are not translated — the generated read declares
  offset pagination and refuses a count.
- **`as_of` is read-only on a facade.** Over a temporal source it is
  forwarded, and rows come back as of that instant; a facade has the time of
  its source, so it reaches a temporal resource through any number of
  facades (`AshStrangler.Facade.Info.temporal?/1`). Over a source with no
  time, a read that carries `as_of` is refused, never dropped. It is refused
  on every write, before anything runs.
- **No tenant, no read, no write.** A source with a multitenancy strategy refuses a
  tenant-less read or write — for a person and for a system actor alike. A `global?
  true` attribute-tenant source would otherwise read every tenant's rows.

## What a write does

`AshStrangler.Facade.Write`, behind each generated generic action:

1. `as_of` on the input is refused, naming `as_of`, before anything runs. A
   facade write takes effect now.
2. The source row is read as the caller, by primary key. No row, no write — a
   row the caller cannot read is a row that is not there.
3. The source action's input is built by putting values through the lens's
   reverse direction: for `accepts:` the argument value. The write is an
   update of the row step 2 read, so a collapse state whose `set:` omits a
   column holds that column's stored value. A lens with no reverse refuses
   with its `because:` text, before the source action runs.
4. The source update action (`via:`) runs with the caller's `actor`, `tenant`
   and `authorize?`. The source's own validations and guard errors are
   returned as the source raised them.
5. The updated source row goes back through the forward lens. No second
   source action runs to produce the return value.

One write is one source action — counted, not assumed, by the tests. `sets:`
values are not passed as action input: the compile-time check proves the
source action itself sets the source attribute to that value (its own
`set_attribute` change, or a state machine's `transition_state`, or either
wrapped for replay by `ash_events`), so the source's guards see the row as it
is and its own change makes the change. `accepts:` values travel through the
lens and must reach the action as an input: in its `accept`, or as an
argument the action copies into that column with
`set_attribute(column, arg(name))`, in which case the value is passed as that
argument.

## What the compiler refuses

The verifiers under `AshStrangler.Facade.Verifiers`:

- the source is an Ash resource carrying the named read action, and every
  `from:` names something the source has (a `Lens.over/3` failure, named);
- the facade declares **no field policy, no `secured_fields`, no
  `extra_grants`** and no create, update or destroy action of its own; every
  read action it declares is the facade manual read. A facade has no security
  vocabulary: the source's is the only one;
- `sensitive?` is **inherited, never set**: a facade attribute's `sensitive?`
  equals "any source attribute, calculation or aggregate its lens reads is
  sensitive?", and a difference in either direction is refused;
- each write names an existing **update** action of the source, names at
  least one of `sets:`/`accepts:`, writes only through lenses with a reverse,
  sets only what its source action really sets, and accepts only columns the
  action accepts. The facade's primary key is one attribute, because the
  action takes it as one `id` argument;
- the **estate** places every attribute of the source: exposed by a lens,
  `hide ... because:`, or `defer`. An unplaced attribute fails with its name;
  a `hide`/`defer` naming nothing, or a `hide` of an attribute a lens reads,
  fails too (`AshStrangler.Facade.Info.estate/1` reads the same result);
- `AshStrangler.Obligations.over/3` findings of severity **error** fail
  compilation, exactly as they do for a strangled mapping.

## Hops

`AshStrangler.Facade.Info.hops/1` returns the lineage chain from the facade
down, one `%AshStrangler.Facade.Hop{}` per hop: `kind` (`:facade`,
`:strangled` or `:owned`), the hop's `resource`, its `source`, its `dataset`
(the Postgres database, schema and table of the hop's rows — `nil` for a
facade, which has no storage), the hop's `mapping_version`, and its `edges`
(`AshStrangler.Lineage.Edge` structs, classified by the same code that draws a
strangled mapping). A facade over a facade adds a hop per facade; a strangled
source adds a hop hashed with `AshStrangler.MappingVersion.hash/1`; an owned
source ends the chain. A chain over a facade source is read hop by hop — no
hop trusts the description of the one above it.
`AshStrangler.Facade.Info.mapping_versions/1` is the same chain as a list of
versions, in hop order.

```elixir
AshStrangler.Facade.Info.hops(MyApp.WorkItemRow)
# [%Hop{kind: :facade, resource: MyApp.WorkItemRow, source: MyApp.WorkItem, ...},
#  %Hop{kind: :facade, resource: MyApp.WorkItem, source: MyApp.Task, ...},
#  %Hop{kind: :owned, resource: MyApp.Task, source: nil, ...}]
```

## Where a value came from

With the optional `:ash_provenance` dependency,
`AshStrangler.Facade.Explain.value/3` answers where one facade value came from,
on that package's contract. It takes a facade record the caller has already
read, as the caller, and reads nothing itself, so what the caller may see is
what the answer may name.

```elixir
record = MyApp.Domain.get_work_item!(id, actor: actor, tenant: tenant)

%{steps: steps, gaps: gaps, antecedents: antecedents} =
  AshStrangler.Facade.Explain.value(record, :title,
    address: address_of_the_facade_value,
    source_type: "task"
  )
```

A value read through a lens has one `:was_derived_from` step for each source
attribute the lens reads, naming that source value by address, and the
facade's mapping version as the step's plan. A constant, a key or an unmapped
attribute has one `:was_generated_by` step. A read-only or non-invertible lens
is explained forward like any other, and its `because:` text is in the step's
summary: the forward direction is known, so that is not a gap. A value the
caller was refused is an `:unreadable` gap and no step, because a step would
name the source row. The `antecedents` are the source value addresses: the
walk that called `value/3` asks the source's own explainer about each one,
and a facade over a facade is two such hops. The address type tokens belong
to the host, which is why `source_type` is an argument.
