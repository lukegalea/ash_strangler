<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Derived rows

One legacy row sometimes holds several things the new model keeps as rows of
their own: two nurses in two columns, a list of ids inside a jsonb document, a
"booked" event that was never stored. `use AshStrangler.Derived` presents them
as one read-only view over the legacy relation.

```elixir
defmodule Clinic.VisitStaff do
  use AshStrangler.Derived

  derived do
    schema "clinic"
    view "visit_staff"
    twin Clinic.Legacy.Visits
    registry Clinic.Keys
    kind :staff
    from [:id]

    column :visit, :integer, null?: false
    column :person, :string
    column :role, :string
    column :position, :integer

    slot :lead do
      filter expr(not is_nil(lead_nurse))
      map :visit, from: :id
      map :person, from: :lead_nurse
      constant :role, "lead"
      unmapped [:position], because: "a slot has no position"
    end

    synthesized :booked do
      filter expr(not is_nil(booked_at))
      map :visit, from: :id
      constant :person, "front desk"
      constant :role, "booked"
      unmapped [:position], because: "a synthesized row has no position"
    end

    element :guest do
      from :details
      path ["guests"]
      type :text
      value :person
      ordinal :position
      map :visit, from: :id
      constant :role, "guest"
    end
  end
end
```

## The three sources

| Source | Yields | Use it for |
|---|---|---|
| `slot` | one row per legacy row for which `filter` holds | a fixed place in the legacy row |
| `synthesized` | the same, with computed values | a row with no counterpart in the legacy data |
| `element` | one row per accepted element of a jsonb array | a list inside a document |

A `filter` over the twin's columns applies to one source. A `filter` in the
`derived` block applies to all of them. Every source answers every column, with
`map`, `constant` or `unmapped`; an `element` answers its `value` and `ordinal`
columns itself. `VerifyDerived` refuses a column left unanswered, a read of a
column the twin doesn't have, and a registry that has no such `logical` kind.

The view's columns are the key, `__source` (the source's name), then the
declared ones. The view has no triggers. A write goes to the parent's resource.

## Keys

The key is `AshStrangler.KeyKinds.logical/3` over the `from` columns, the twin's
relation, the source's name and, for an element, its value. It is stable when the
legacy row's other columns change, and two sources never collide, even across
two views that share a logical kind. A repeated element yields
one row (the first). See the keys guide.

The element census counts a value at the path that is not an array (a scalar or
an object) as one refused element. A missing path and a JSON `null` are no
element. The view drops all of them.

## The integer guard

`type: :integer` accepts an element only when it is a JSON number whose value
is an integer in the 32-bit range. These are refused, never cast:

| Element | Why |
|---|---|
| `12.5` | a cast would round it to 13 and match another row |
| `1e10`, `-2147483649` | out of range; a cast would raise and fail every read |
| `"12"`, `true`, `null`, `[]`, `{}` | not a number |

`5` and `5.0` are the same element. `type: :text` accepts only JSON strings. A
value that is not an array, or a path that is absent, yields no rows.

Refusing is silent in the view, so the estate counts it: every `element`
source adds an obligation to the estate's registry that reports how many
elements the guard refuses over how many there are (see the estates guide).

## Tenants

A derived view may declare `tenant :column`. Each source must then answer the
column with `tenant_of`, a packed key of a `tenant?: true` kind, and estate
check E5 refuses one that doesn't.

## In an estate

List the module in the estate's `resources`. Its sources claim the twin columns
they read (the key columns, filters, mappings, jsonb columns) as `mapped`. List
it in `config :ash_strangler, deriveds: [...]` for `mix ash_strangler.gen.migration`.
