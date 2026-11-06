<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Keys and references

A strangled resource needs a primary key, and the legacy table already has
one. Most legacy keys are integers; the canonical side wants UUIDs. This guide
covers how the two are related without a lookup table, how a foreign key
between two legacy tables becomes a reference between two canonical
resources, and what the compiler proves about each.

## Three strategies

| Strategy | Legacy key | Invertible | Use it for |
|---|---|---|---|
| `{:uuid_v8, Registry, :kind}` | one or more integer columns, 94 bits in total | yes | integer-keyed tables, including composite keys |
| `{:uuid_v5, namespace: "..."}` | one column of any type | no | a key that is not integers |
| `:identity` | one `uuid` column | yes | tables already keyed by UUID |

A hashed (`uuid_v5`) key cannot be turned back into the legacy key, so the
legacy column has to be carried next to the id wherever the row is located
again, and a foreign key has to be re-hashed the same way with nothing to
check that it was. A packed (`uuid_v8`) key is a bijection: the id **is** the
legacy integers behind a tag, the legacy key comes back out of it, and a
foreign key is the same packing of the foreign key's columns.

## The key-kind registry

```elixir
defmodule MyApp.Keys do
  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x4C42
    snapshot "priv/legacy/snapshot/catalog.json"
    reserved [0x00F]

    kind :branch, 0x001, parts: [{"library.branches.id", 16}]
    kind :member, 0x002, parts: [{"library.members.id", 32}]
    kind :copy, 0x003, parts: [{"library.copies.branch_id", 16}, {"library.copies.copy_no", 64}]
  end
end
```

Each kind has a 12-bit tag and the legacy columns it packs, each with the width
it is packed in. The estate tag fills the first 16 bits of every id, so two
legacy systems (or two stacks of one) can share a canonical database without
their integers colliding.

The layout, from `AshStrangler.UuidV8`:

```text
bits   0..15   estate tag (16 bits)      ┐
bits  16..27   kind tag (12 bits)        │ custom_a (48)
bits  28..47   payload[0..19]            ┘
bits  48..51   version 0b1000
bits  52..63   payload[20..31]             custom_b (12)
bits  64..65   variant 0b10
bits  66..127  payload[32..93]             custom_c (62)
```

The parts fill the 94-bit payload most significant first, in offset binary, so
within one kind the ids sort exactly as the legacy keys do. Different tags
give different ids for equal integers, and the version nibble keeps packed ids
apart from hashed (v5), time-ordered (v7) and random (v4) ones.

`AshStrangler.KeyKinds.encode/3` and `decode/2,3` are the Elixir side.
`to_sql/3` and `part_sql/4` print the same functions as PostgreSQL expressions
built only from immutable built-ins, so the view's id column can have an
expression index. The test suite asserts SQL and Elixir agree on 10⁵ generated
cases across every width combination, in both directions.

Packed ids reveal the legacy integers. Do not treat them as secret.

### What the registry refuses

`VerifyKeyKinds` fails compilation when a tag is reused, reserved or not 12
bits, a kind name repeats, a kind's widths sum past 94 bits, or a part is not
`"schema.table.column"`. With a `snapshot`, every part must be a `NOT NULL`
`smallint`, `integer` or `bigint` no wider than its declared width.

The width is declared rather than read from the catalog on purpose. If a
legacy migration widens `integer` to `bigint` and the width followed the
catalog, the next capture would re-key every row of the kind. Declared, the
capture fails compilation here and names the column, and re-keying becomes a
decision.

## Logical keys

A row derived from another (a slot of a legacy row, an element of one of its
jsonb arrays, a synthesized event, see the derived rows guide) has no legacy
home of its own, so no packed kind fits. Declare it `logical`:

```elixir
key_kinds do
  estate 0x4C42
  kind :member, 0x001, parts: [{"library.members.id", 32}]
  logical :line, 0x010
end
```

`AshStrangler.KeyKinds.logical/3` is a UUID version 5 over the components you
give (integers, strings or UUIDs), joined by an unambiguous separator (a backslash or separator inside a component
is escaped), in a
namespace made from the estate tag and the kind's tag. `logical_sql/3` is the
same expression in SQL, and the two agree. The key is deterministic and can't be
decoded: reach the row through its parent. A `NULL` component gives no key. The
tag shares the 12-bit space of `kind` and is never reused.

A packed `kind` may also be declared `tenant?: true`. That is what estate check
E5 requires of a tenant column (see the estates guide).

## Keys

```elixir
source MyApp.Legacy.Members do
  key :id, from: :id, strategy: {:uuid_v8, MyApp.Keys, :member}
end

source MyApp.Legacy.Copies do
  key :id, from: [:branch_id, :copy_no], strategy: {:uuid_v8, MyApp.Keys, :copy}
end
```

`VerifyKey` (V-KEY) holds a packed key to its kind:

- the registry and kind exist, and `from` has as many columns as the kind has
  parts;
- the twin is pinned to a snapshot, so widths can be checked;
- `from` is exactly the kind's columns on the kind's relation. A kind
  identifies the rows of one relation, and keying another relation with it
  would put two resources in one id space;
- each column is a `NOT NULL` integer no wider than its part;
- the columns hold a non-partial unique key (the primary key, or a unique index
  with no `WHERE`), so two rows cannot pack to one id.

On a pinned twin, an `:identity` key must be a `NOT NULL uuid` column that is
the primary key or a non-partial unique index on its own.

### Composite keys are read-only for now

Triggers, the change ledger, notifications, the backfill and the reconciler
find a legacy row through one `__legacy_id` column, and a composite key has no
single value to put there. V-KEY therefore keeps a resource with a composite
key in `:read_from_legacy`, with no `notify?` or `ledger?`. To be told when such
a relation changes, watch its twin (`twin do watch "channel" end`); the watch
payload carries the whole primary key.

## References

```elixir
source MyApp.Legacy.Loans do
  key :id, from: :id, strategy: {:uuid_v8, MyApp.Keys, :loan}
  reference :member_id, kind: {MyApp.Keys, :member}, from: :member_id
  reference :copy_id, kind: {MyApp.Keys, :copy}, from: [:branch_id, :copy_no]
end
```

A `reference` is a mapping whose value is the packed key of another row. It
equals that row's id by construction, so `Ash.get(Member, loan.member_id)`
finds the member with no lookup table and no join through the legacy table.

The reverse is the decode. A write through the `INSTEAD OF` triggers stores
the legacy integers the id packs. An id of another kind, or a UUID that is not
packed at all, fails the write with `not a key of this kind: <uuid>`. It is
never stored as a wrong integer.

### Closure

That a reference has the right shape does not show that the row it names
exists. The snapshot can show it. `VerifyReferences` (V-REF) proves
**closure** when, in the twin's catalog:

- `from` is the kind's own columns on the kind's own relation, or
- a **validated** foreign key on the twin's relation maps `from`, column for
  column, onto the kind's columns.

A reference with no such constraint must say why:

```elixir
reference :referred_by_id,
  kind: {MyApp.Keys, :member},
  from: :referrer_id,
  soft: "The referrer foreign key was added NOT VALID over rows that predate it."
```

`soft:` is refused where closure is proven, so the reason cannot outlive the
fact. Every soft reference becomes a `reference_closure` assertion in
`AshStrangler.Obligations`, and `mix ash_strangler.check` counts the rows whose
parts name no row of the kind. An unpinned twin can prove nothing, so all of
its references must be soft.

V-REF also checks that each `from` column is an integer attribute of the twin
and, on a pinned twin, no wider than its part.

## The twin authorizer

A twin is legacy data with none of the canonical resource's policies. A twin
can be restricted to the host's system actor:

```elixir
use Ash.Resource,
  domain: MyApp.Legacy,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshStrangler.Twin],
  authorizers: [Ash.Policy.Authorizer]

twin do
  snapshot "priv/legacy/snapshot/catalog.json"
  system_actor MyApp.Checks.SystemActor
end
```

`AshStrangler.Transformers.AddTwinPolicy` adds the single policy
`policy always() do authorize_if MyApp.Checks.SystemActor end`. A read with
any other actor, or with none, is forbidden. `authorize?: false` still reads,
as it does on any resource. The transformer refuses `system_actor` without the
policy authorizer, because the policy would never run, and refuses a `bypass`
on the same twin, because a bypass could authorize another actor.
`mix ash_strangler.gen.twin --system-actor MyApp.Checks.SystemActor` writes
both, and regeneration keeps them.

## Fixture writers

Seed and test data for a stand-in legacy schema should go in the way the legacy
application would write it, under the database's own constraints, and should
not go through the canonical side. `AshStrangler.Twin.Fixture` does this:

```elixir
member = AshStrangler.Twin.Fixture.insert!(MyApp.Legacy.Members, %{home_branch_id: 1, email: "a@example.com"})
AshStrangler.KeyKinds.encode(MyApp.Keys, :member, [member.id])

AshStrangler.Twin.Fixture.insert_all!(MyApp.Legacy.Copies, rows)
```

`insert!/3` returns the row as the database wrote it (defaults and identity
columns included), keyed by twin attribute. `insert_all!/3` batches rows up to
PostgreSQL's bind-parameter limit and returns the count. A key that is not a
twin attribute is refused, and secrets are never twin attributes.
