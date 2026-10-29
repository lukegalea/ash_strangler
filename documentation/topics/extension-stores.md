<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Extension stores

The legacy schema has no room for host-only data. `extension [...]` gives that
data real storage **beside** the shared row, without pretending a legacy column
exists:

```elixir
source MyApp.Legacy.Contracts do
  key :id, from: :id, strategy: :identity
  map :name, from: :name
  extension [:negotiating_notes, :created_by_id]
end
```

One table per resource: `"<view_schema>"."<table>_extension"`, keyed by the
canonical primary key. Column types come from the resource's Ash attribute type
through `AshStrangler.Sql.Printer.pg_type!/1`. The compatibility view `LEFT
JOIN`s the table in; the `INSTEAD OF` triggers insert/upsert/delete its row in
the same transaction as the legacy write.

Any extension attribute forces `:triggers`: the view has a second relation to
write, and auto-updatability cannot carry it. The upsert covers legacy rows
that predate the extension table: their first host update inserts the extension
row; later updates upsert it. The delete removes it in the same transaction as
the legacy row.

## Rows with no extension record yet

A legacy row that predates the resource has no extension row. That is history,
not corruption. For an attribute with a static literal default, the view reads
`COALESCE(ext."attr", <literal>)`; an attribute with no default reads NULL.
Function defaults are refused: a view that calls `&Ash.UUID.generate/0` or
`&DateTime.utc_now/0` returns a different value on every read.

On INSERT, the trigger always creates the extension row. If the client does
not supply an attribute, the row may carry NULL; the view still returns its
declared literal default through COALESCE. On UPDATE, the extension upsert
runs BEFORE the trigger re-selects through the view: re-selecting first would
replace `NEW` with the view's projection (including its defaults) and lose the
value the command supplied.

## State columns

A collapse state declared `representation: {:extension, :lifecycle_state}`
adds `lifecycle_state` to the same extension table implicitly, typed by the
collapse attribute. The forward CASE reads `ext."lifecycle_state" = 'value'`
before any legacy guards. The backward trigger writes that extension column
and holds the legacy columns: an update of a row sitting in the extension
state must not drag its legacy flags to the fallback values.

## Refusals

`VerifyExtension` refuses an attribute that does not exist, is already mapped
(or constant, unmapped, or the key), or has a function default. There is at
most one extension block per source. Extension stores are refused in
`:read_from_new` — that phase owns a real table; fold the extension columns
into it before cutover — and in `:decommissioned`.
