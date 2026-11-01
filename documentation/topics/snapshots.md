<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Snapshots

A twin is the legacy schema declared as an Ash resource, and the declaration is
a copy of a fact that belongs to someone else. The legacy application's next
migration changes the fact and leaves the copy alone. A snapshot pins the fact.
The schema is captured once, committed, hashed and checked from three
directions:

- **G-SNAP:** the snapshot is internally consistent. Its files match their
  hashes, and the catalog is exactly what the SQL produces.
- **V-SNAPSHOT:** every twin pinned to it agrees with it, at compile time, with
  no database.
- **G-DRIFT:** the live legacy database still matches it.

Each gate covers a different failure. If you edit the catalog by hand,
G-SNAP fails. If you edit a twin by hand, V-SNAPSHOT fails. If the legacy team
ships a migration, G-DRIFT fails.

## The directory

```text
priv/legacy/snapshot/
  extensions.sql   # optional preamble: schemas and extensions the dump assumes
  schema.sql       # pg_dump --schema-only, normalised
  catalog.json     # derived from the two above
  lock.json        # hashes, heads, provenance
```

### `schema.sql`

This file is the source of truth. `capture` runs `pg_dump --schema-only
--no-owner --no-privileges --no-comments` for each `--schema`, then normalises
the output so that two captures of the same schema produce the same bytes. The
normalisation drops the per-run `\restrict` / `\unrestrict` keys that recent
`pg_dump` versions emit and the `-- Dumped from/by` version lines, and it
rewrites `CREATE SCHEMA x;` to `CREATE SCHEMA IF NOT EXISTS x;` so the file
loads after a preamble that has already created the schema.

### `extensions.sql`

`pg_dump -n` leaves out the extensions a schema depends on. When a column is
`citext`, for example, `schema.sql` alone will not load. `extensions.sql` is a
short, hand-written preamble that you commit next to the dump, and it is
loaded first:

```sql
CREATE SCHEMA IF NOT EXISTS shop;
CREATE EXTENSION IF NOT EXISTS citext SCHEMA shop;
```

Name the extension's schema explicitly. Where an extension lives determines
how its types print in the catalog (`shop.citext`), so that placement is part
of the snapshot.

### `catalog.json`

The catalog is never parsed from SQL text. `derive` loads the SQL files into a
scratch database (`CREATE DATABASE ... TEMPLATE template0`, dropped afterwards),
reads `pg_catalog` with an empty `search_path` so that every non-catalog type
prints schema-qualified, and writes canonical JSON: sorted keys, two-space
indent, and a trailing newline. Name lists are sorted in Elixir, not by the
server's collation. Columns keep their ordinal order. Objects that belong to
an extension are excluded.

```json
{
  "format": "ash_strangler.catalog/1",
  "schemas": ["shop"],
  "extensions": {"citext": "shop"},
  "enums": {"shop.order_state": ["open", "paid", "shipped"]},
  "domains": {
    "shop.postcode": {"type": "text", "udt": "pg_catalog.text", "not_null": false,
                      "default": null, "checks": [{"name": "...", "definition": "CHECK (...)"}]}
  },
  "relations": {
    "shop.orders": {
      "kind": "table",
      "definition": null,
      "columns": [
        {"name": "id", "type": "bigint", "udt": "pg_catalog.int8", "array": false,
         "not_null": true, "default": "nextval('shop.orders_id_seq'::regclass)",
         "generated": null, "identity": null}
      ],
      "primary_key": {"name": "orders_pkey", "columns": ["id"]},
      "unique": [{"name": "...", "columns": ["..."], "predicate": null}],
      "foreign_keys": [{"name": "...", "columns": ["customer_id"],
                        "references": {"relation": "shop.customers", "columns": ["id"]},
                        "on_update": "no_action", "on_delete": "cascade", "validated": true}],
      "checks": [{"name": "...", "columns": ["state"], "definition": "CHECK (...)",
                  "values": ["open", "paid"], "validated": true}],
      "triggers": [{"name": "...", "definition": "CREATE TRIGGER ..."}]
    }
  }
}
```

The fields:

- `kind` is `table`, `partitioned_table`, `foreign_table`, `view` or
  `materialized_view`.
- `definition` is the view's query, and `null` for anything else.
- `type` is `format_type` as PostgreSQL prints it.
- `udt` is the underlying type. For an array, it is the element type.
- `identity` is `always`, `by_default` or `null`.
- `predicate` is set only on a partial unique index.
- A check's `values` is filled in when the whole check is a single-column
  `col IN (...)` / `= ANY (ARRAY[...])` over literals, which is what makes the
  column an `:atom` with `one_of`. An IN list joined to anything else (`OR`,
  `AND`, or a `NOT VALID` constraint that does not hold yet) has no `values`.
- `not_null` is false for a column whose `NOT NULL` was added `NOT VALID`
  (PostgreSQL 18): the constraint is listed among the relation's `checks` with
  `validated: false`, because it does not promise the rows hold no NULL.
- `diff` cannot see what the catalog does not record. `AshStrangler.Snapshot.Catalog`
  lists those kinds (collations, `NULLS NOT DISTINCT`, exclusion constraints,
  partition bounds and others); a schema that uses them needs its own review.

### `lock.json`

```json
{
  "format": "ash_strangler.lock/1",
  "generator": "ash_strangler 0.5.0",
  "schemas": ["shop"],
  "heads": {"app": {"head": "20261028120000", "count": 412}},
  "files": {"catalog.json": "<sha256>", "extensions.sql": "<sha256>", "schema.sql": "<sha256>"},
  "derived_on": "PostgreSQL 16.4",
  "captured": {"at": "...", "pg_dump": "pg_dump (PostgreSQL) 16.4", "server": "16.4"}
}
```

`heads` records the migration state the snapshot was taken at. There are two
ways to fill it:

- declare it yourself (`--head app=20261028120000`);
- read it from the captured database
  (`--head-from app=shop.schema_migrations.version`, which reads
  `max(version)` and the row count).

A later `derive` keeps the heads and the schema list from the previous lock
unless you pass new ones. `captured` is `null` for a snapshot that was only
derived.

## The workflow

```bash
# Once, and again whenever the legacy schema moves:
mix ash_strangler.snapshot capture priv/legacy/snapshot --url "$LEGACY_URL" \
  --schema shop --head-from app=shop.schema_migrations.version

# Twins from the catalog: no database involved.
mix ash_strangler.gen.twin --from-snapshot priv/legacy/snapshot/catalog.json \
  --relation shop.orders --module MyApp.Legacy.Orders --domain MyApp.Legacy

# In CI:
mix ash_strangler.snapshot verify priv/legacy/snapshot          # G-SNAP
mix compile --warnings-as-errors                                # V-SNAPSHOT
mix ash_strangler.snapshot drift priv/legacy/snapshot \
  --url "$LEGACY_URL" --allow-file priv/legacy/drift-allow.txt   # G-DRIFT
```

`derive` and `verify` need a role that can `CREATE DATABASE`, because they
build a scratch database. `drift` only reads. `load` puts the snapshot into a
database, which gives you a stand-in for the legacy one in tests and demos.

The catalog is environment-sensitive in one respect. View definitions and
default expressions are printed by the server that derives them, so derive and
verify on the same PostgreSQL major version. `derived_on` records which one
was used.

## V-SNAPSHOT

A twin generated with `--from-snapshot` is pinned to its catalog:

```elixir
twin do
  snapshot "priv/legacy/snapshot/catalog.json"
end
```

The catalog becomes an `@external_resource` of the twin, so a new capture
recompiles every twin pinned to it. Compilation fails, naming each column,
when:

- the twin declares a column the catalog lacks;
- a column's type, or its `one_of` value set, is not the one the generator
  would choose;
- nullability differs;
- the catalog has a typed column the twin leaves out and has not declared
  secret;
- the primary key differs;
- the relation does not exist.

The error ends with the `gen.twin` command that regenerates the twin. The type
rule is the generator's own (`AshStrangler.Snapshot.Types`), so a generated
twin passes by construction.

## Secrets

Some legacy columns must never leave the legacy database: a password digest,
an API token, a card fingerprint. Declare them on the twin:

```elixir
twin do
  snapshot "priv/legacy/snapshot/catalog.json"
  secrets [:password_digest]
end
```

or pass `--secret shop.customers.password_digest` to `gen.twin`. From then on:

- the twin has no attribute for the column. The generator writes a comment
  in its place, and `AshStrangler.Verifiers.VerifySecrets` refuses one added
  by hand;
- a mapping that names it fails to compile (`VerifyTwin`), so it cannot reach
  a view, a backfill or a notification;
- the change ledger's row images are built from the twin's columns, not from
  `to_jsonb(OLD)`, so the secret is never written to `legacy_change_events`.
  V-LEDGER (`VerifyLedger`) also refuses a ledger whose image would still
  include it, which can happen in `:read_from_new`, where the image is the
  resource's own columns.

`gen.twin` reads `secrets` back from the existing twin's source before it
overwrites the file, so a regeneration cannot quietly undo the declaration.

## Watching a twin

Some legacy relations matter even though nothing maps them. A membership table,
for example, decides who sees what, and a host needs to hear when it changes.

```elixir
twin do
  watch "shop_memberships_changed"
end
```

`mix ash_strangler.gen.migration` then installs a notify-only trigger on the
relation. The payload is
`{"relation": "shop.memberships", "op": "insert", "key": {"id": 7}}`, which
carries the primary key and no row data, so it holds no secret. Delivery is
at-most-once, like every `pg_notify`. Subscribe with
`Postgrex.Notifications`; `AshStrangler.Listener` is for strangled resources,
not watches. See `AshStrangler.Sql.Watch`.

## Triggers fail closed to the legacy write

Every trigger this package installs on a legacy relation (notify, ledger and
watch) runs its side effect inside a `BEGIN ... EXCEPTION WHEN OTHERS` block,
and so does everything that reads the row's columns: the ledger's row image is
built inside it. If the ledger table has been dropped, a notify fails, or a
legacy migration has renamed or dropped a column the twin still names, the
trigger raises a `WARNING` and the legacy write commits anyway. The legacy application keeps
working even when the strangler's side of the database is broken.

The cost is a subtransaction per row. The ledger's subtransaction writes, so
it takes a transaction id. A legacy transaction that writes more than 64 ledgered
rows therefore overflows PostgreSQL's per-backend subtransaction cache, which
slows visibility checks on other sessions and on replicas for as long as that
transaction stays open. Keep this in mind for bulk legacy jobs. The notify and
watch blocks write nothing, so they do not take a transaction id.

`drift` ignores triggers whose names start with `strangler_`, on both sides,
because those are this package's own. `capture` leaves every `strangler_*`
object (trigger, trigger function, key index) out of `schema.sql`, so a
snapshot captured where a strangle already runs equals one captured before it.

A `CHECK` that is exactly `column IN (...)` compares on its columns, values
and validity, not its text. The locked catalog has been through a dump and
reload and a live database built by migrations has not, and `pg_dump` does not
round-trip the text of every IN list: a varchar list stored as
`(ARRAY['a'::character varying])::text[]` reloads as
`ARRAY[('a'::character varying)::text]`. Both admit the same rows.
