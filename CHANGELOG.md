<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## Unreleased

Requires Elixir 1.20 or later.

### Features

- **A union `:dual_write` update assigns only the columns it changed:** the trigger's `NEW` and `OLD` are
  both the view scan, so a column the statement left alone carried a value that could predate a
  concurrent commit to the legacy row, and assigning it back reverted that commit. Each legacy column is
  now `col = CASE WHEN NEW.x IS DISTINCT FROM OLD.x THEN <new> ELSE col END`, and the extension upsert
  overwrites only the changed extension columns. Writing a column back to the value the scan showed is
  indistinguishable from not writing it, as with a twin's `on_update: :changed_columns`.
- **`:read_from_new` carries the old application's writes and every column it reads:**
  - The reverse view now has one column per twin attribute, in the twin's declared order (it was
    sorted by name), named through `Twin.column!/2` and the printer's identifier rule, so a
    CamelCase column or a `key.from` with a `source:` rename is spelled as the legacy schema spells
    it. References to the owned table use the owned attribute's own column name (`source:`).
  - **New `AshStrangler.Sql.ReverseTriggers`:** `INSTEAD OF INSERT`, `UPDATE` and `DELETE` on the
    legacy-named view, as the docs promised. Each lens's forward expression is rendered over
    `NEW.<legacy column>`, so a legacy write stores what a backfill would have stored; the owned
    key comes from the forward view's key expression and the legacy key is stored as `legacy_id`.
    Attributes with no legacy source are not assigned. `RETURNING` reports the re-read row, and a
    write that cannot be carried raises (a changed key, a retired column, a `decode`d value with no
    counterpart, an `UPDATE` of a vanished row, an `INSERT` with no key and no sequence on
    `legacy_id` to allocate one). An `UPDATE` assigns only the columns whose legacy source the
    statement changed. A mapped column an `INSERT` leaves out is stored as `NULL`; a legacy
    `DEFAULT` belongs on the view (`ALTER VIEW ... SET DEFAULT`). They are emitted only when a
    plain auto-updatable view cannot carry the write: a derived key, a computed column or a legacy
    column read by more than one attribute needs them; an `:identity` key with no `legacy_id`
    and plain renames does not, and keeps `ON CONFLICT`.
  - **New `retired [:column], because: "..."` in a `source`:** declares twin columns the old
    application no longer reads. `VerifyReverseMappable` now refuses `:read_from_new` for any twin
    column that no mapping writes and that is not retired, naming the columns and the options. A
    retired column renders as `NULL` cast to its PostgreSQL type, in the twin's column position.
    **Breaking for a resource at `:read_from_new`:** map or retire every twin column. An
    `:identity` key on a resource with no `legacy_id` attribute is no longer refused by the
    reverse view; it exposes the owned key. A reverse view an earlier version deployed has its
    columns sorted by name, and `CREATE OR REPLACE VIEW` cannot reorder them, so drop it in the
    same migration.

- **`mix ash_strangler.check` compares a twin with the live catalog:** for each column a twin
  declares, the check re-derives what `mix ash_strangler.gen.twin` would write today and compares.
  A value set that grew (an enum label or `CHECK` value the twin's `one_of` lacks) fails, naming the
  mappings that read the column; a changed coarse Ash type fails; a narrowed set, a `one_of` the
  catalog no longer yields, and a differing `allow_nil?` warn. Value sets compare as sets, a
  hand-written twin is held only to what it declares (by its `source:` column names), and a relation
  that is absent stays a failure of the freshness check. A new warning-level "column types" step
  asks Postgres for the type each mapping yields, without executing it, and compares it with the
  type the attribute stores; a Postgres enum and a type with no Ash type are reported, not
  collapsed, and `--strict` counts them, because nothing was compared for them. A passing type does
  not show that every row casts.
- **`AshStrangler.Twin.Introspection`:** what the twin generator decides about a relation (the
  columns with their Ash types and value sets, the identities and unique sets, the coarse type
  comparison), callable from a task that does not load Igniter. `mix ash_strangler.gen.twin` writes
  the same files through it. `AshStrangler.Snapshot.Catalog.read/2` reads the catalog through any
  function that runs SQL, and `AshStrangler.Snapshot.Types.ash_type/1` exposes the type table.

- **Union write-through:** a `legacy` union branch takes `not_written_back [...], because:` (the
  columns a `:dual_write` update drops, which no longer count as writers of a shared legacy
  column), `extension [...]` (columns stored in `<view>_extension`, joined into the view and
  upserted by the update trigger, never written to the legacy table) and `refuse_delete because:`
  (a `:dual_write` delete raises `BranchWriteRefused`). A union takes `security_definer true`
  (trigger functions `SECURITY DEFINER SET search_path = pg_catalog`) and `functions_schema`.
  `AshStrangler.Migration.render_move/2` renders the move of an installed union: extension tables,
  `CREATE OR REPLACE VIEW` and `CREATE OR REPLACE FUNCTION`, no owned table and no trigger, and it
  refuses a changed view column list. `Union.Info.lens_kinds/2` gains the kind `:extension`.

- **`mix ash_strangler.check --strict`:** exits non-zero on every outcome that could not be
  measured, not only on a failed assertion: every `????` line (including a repo that could not be
  resolved or started), the two warnings that say nothing was measured (a required attribute no
  mapping accounts for; an identity key with no mapping), and no resource found, which includes a
  `--domain` that names no domain. Without it a gate could go green having measured nothing.
  `--strict` together with `--no-data` is refused at startup (see Fixes).

- **Union branch `filter`:** a `legacy` branch takes `filter expr(...)`, an expression over its
  twin's columns printed as the `WHERE` of the branch's select, so a relation that mixes kinds of
  row can feed several branches or only the rows a resource is about. The filter's columns are
  claimed as read in an estate, and `VerifyUnion` refuses a filter over a column the twin lacks.

- **Predicate inversion (L7):** a union with a `tenant` column exposes the tenant
  key's integer parts as hidden last view columns `__tenant_p<i>` (uncast on a
  legacy branch, `NULL` on the owned one). `AshStrangler.Inversion.filter/3` and
  `where_sql/2` rewrite `tenant = $1` into per-branch comparisons on them, so the
  legacy table's existing index serves the read instead of a scan evaluating the
  packing expression. The owned branch keeps the original predicate, and a branch
  whose kind does not decode the key contributes nothing. Plan-shape tests on
  PostgreSQL 18.
- **Derived rows:** `use AshStrangler.Derived` presents zero or more canonical
  rows per row of one legacy relation as a read-only view: `slot`s (a fixed
  place in the legacy row), `synthesized` rows (computed values) and
  `element`s of a jsonb array. A `filter` applies to a source or to all of
  them. An integer element is accepted only when it is a JSON number with an
  integer value in the 32-bit range (`12.5`, `1e10`, `"12"` are refused, never
  cast), a text element only when it is a JSON string, and a repeated element
  yields one row. `VerifyDerived` refuses unanswered columns, reads of columns
  the twin lacks and an unknown logical kind. Derived views are generated by
  `Migration.statements/1` (`config :ash_strangler, deriveds: [...]`) and claim
  the twin columns they read in an estate.
- **Logical keys:** `logical :name, 0x010` in a key-kind registry declares a
  kind for rows derived from others. `KeyKinds.logical/3` is a UUID version 5
  over the components, in a namespace made from the estate tag and the kind's
  tag; `logical_sql/3` is the same in SQL, and the two agree.
- **Tenant kinds and `tenant_of`:** `kind ..., tenant?: true` marks a packed
  kind as naming a tenant; `tenant_of :column, kind: {Registry, :kind}, from: ...`
  answers a union branch's or derived source's column with it.
- **Estate check E5:** tenant closure (`AshStrangler.Estate.Tenancy`). A union
  or derived view that declares a `tenant` column must derive it on every legacy
  branch or source through a tenant key kind, and the column must be
  `null?: false`.
- **Obligation registry and report:** `AshStrangler.Estate.Obligation` and
  `AshStrangler.Estate.Obligations` collect an estate's obligations (the
  assertions a resource's mappings could not decide, the census of elements a
  derived view refuses, and a plug-in's `obligations/1`) and measure them.
  `mix ash_strangler.check --estate [Estate] --report FILE` writes the result
  as canonical JSON (`ash_strangler.obligations/1`, keyed by the catalog's
  sha256, sorted, no timestamp) and exits 1 on a failed or unmeasurable
  obligation or an estate problem.
- **Union sources:** `use AshStrangler.Union` declares one canonical relation
  over one or more legacy branches (each a twin with its own phase and a
  declared `refused_because`) and one owned branch. It generates the owned
  table, a key index per branch, a `UNION ALL` view with a `__branch` column,
  and `INSTEAD OF` insert, update and delete triggers: inserts land in the
  owned branch with a correct `RETURNING`; a write to a legacy branch in
  `:read_from_legacy` is refused as `AshStrangler.Error.BranchWriteRefused`
  with the declared reason; in `:dual_write` updates and deletes are carried
  to the legacy table. `AshStrangler.Union.Info` exposes the branch phases and
  the lens kind of each column (`:column`, `:expression`, `:constant`,
  `:null`, `:owned`) for host verifiers. `VerifyUnion` refuses unanswered or
  unknown columns, missing or shared keys, a twin that is not one and a mapping
  over a column the twin lacks. See the unions guide for the concurrency
  behaviour.
- **Estate check E8:** the phase lattice and the carry rule
  (`AshStrangler.Estate.Phases`). A resource or legacy branch at
  `:read_from_new` or later may not leave a column of its relation `deferred`
  or `legacy_only`, and nothing may read a relation a branch has
  decommissioned. Unions listed in an estate claim their twin columns.

- **Pinned schema snapshots:** `mix ash_strangler.snapshot capture|derive|verify|drift|load`.
  A snapshot directory holds a normalised `pg_dump --schema-only`
  (`schema.sql`), an optional `extensions.sql` preamble, a `catalog.json`
  derived deterministically from them on a scratch database
  (`ash_strangler.catalog/1`), and a `lock.json` of hashes, migration heads and
  provenance (`ash_strangler.lock/1`). `verify` (G-SNAP) re-derives and compares
  byte for byte; `drift` (G-DRIFT) diffs a live database against the catalog,
  with an allow-list, and ignores this package's own `strangler_*` triggers.
- **`gen.twin --from-snapshot`:** twins generated from a catalog with no live
  database. Live generation now goes through the same catalog, so both paths
  type columns identically (`AshStrangler.Snapshot.Types`).
- **V-SNAPSHOT:** a twin may declare `twin do snapshot "…/catalog.json" end`.
  The catalog becomes an `@external_resource`, and compilation fails, naming
  each column, when the twin's attributes, types, value sets, nullability or
  primary key disagree with it.
- **Secret columns:** `twin do secrets [...] end` (or `gen.twin --secret
  schema.table.column`). A secret is never a twin attribute, a mapping that names
  one does not compile, and `gen.twin` preserves the declaration across
  regeneration.
- **Watched twins:** `twin do watch "channel" end` installs a notify-only,
  key-only trigger through `gen.migration` (`AshStrangler.Sql.Watch`).
- **Packed keys (`{:uuid_v8, Registry, :kind}`):** an invertible key
  strategy. A key-kind registry (`use AshStrangler.KeyKinds`, `key_kinds do
  estate ...; kind :name, 0x001, parts: [{"schema.table.column", 32}] end`)
  gives each kind a 12-bit tag, and `AshStrangler.UuidV8` packs one or more
  16/32/64-bit integer parts (94 bits at most) into a version 8 UUID behind a
  16-bit estate tag. The Elixir encoder and the SQL printer agree, and the SQL
  is immutable, so the view's id has an expression index. Ids sort in legacy
  key order within a kind. `VerifyKeyKinds` refuses reused, reserved or
  out-of-range tags, over-wide kinds, and, against a snapshot, nullable,
  non-integer or wider-than-declared parts.
- **Composite keys:** `key :id, from: [:a, :b], strategy: {:uuid_v8, ...}`,
  for resources in `:read_from_legacy` without `notify?` or `ledger?`.
- **V-KEY (`VerifyKey`):** a packed key must name exactly its kind's columns on
  a pinned twin, each a `NOT NULL` integer no wider than its part, holding a
  non-partial unique key. An `:identity` key on a pinned twin must be a unique
  `NOT NULL uuid`.
- **References:** `reference :member_id, kind: {Registry, :member}, from:
  :member_id` (or a list of columns) maps a legacy foreign key to the packed
  id of the row it names. Writes decode it back to the legacy integers, and an
  id of another kind fails the write. **V-REF (`VerifyReferences`)** proves
  closure from a validated foreign key in the snapshot, or requires `soft:
  "reason"`, which becomes a `reference_closure` assertion counting dangling
  rows in `mix ash_strangler.check`.
- **Twin authorizer:** `twin do system_actor Check end` (with
  `authorizers: [Ash.Policy.Authorizer]`) adds a policy that only the system
  actor passes. A twin with a `bypass`, or without the authorizer, does not
  compile. `gen.twin --system-actor Check` writes both and keeps them on
  regeneration.
- **Fixture writers:** `AshStrangler.Twin.Fixture.insert!/3` and
  `insert_all!/3` write legacy rows through a twin's columns, under the
  database's constraints, for seeds and tests.
- The "Keys and references" guide and the `AshStrangler.KeyKinds` DSL
  reference.
- **`AshStrangler.Twin` DSL reference** (`documentation/dsls/DSL-AshStrangler.Twin.md`)
  and the "Snapshots" guide.
- **Estates:** `use AshStrangler.Estate` declares one disposition for every
  relation and column of a snapshot catalog. `mapped` and `secret` are computed
  from the listed resources' mappings and their twins; `carried`, `deferred`
  (`wave:`, `target:`), `legacy_only` and `dead` are declared with `because:`;
  `residue` lists live-only relations and `open_reference` accepts a foreign
  key that is not closed. `VerifyEstate` checks declarations against the
  catalog at compile time. The `:ash_strangler_estate` Mix compiler checks
  coverage (exactly one disposition per column), whole-relation consistency,
  writer linearity across resources and foreign-key closure from mapped
  columns, and runs plug-ins. `AshStrangler.Estate.Plugin` lets a host claim
  columns its own machinery reads and add its own checks.
  `mix ash_strangler.estate --manifest` exports the `ash_strangler.estate/1`
  manifest; `AshStrangler.Estate.drift_allow/1` turns residue into drift allow
  patterns. The "Estates" guide and the `AshStrangler.Estate.Dsl` reference.

### Fixes

- **Writes name a legacy column the way reads do:** a twin attribute that carries `source:` (the
  generator writes it for a camel-case column or a name an atom cannot be) was read through
  `AshStrangler.Twin.column!/2` but written under its attribute name, so the generated `INSTEAD OF`
  triggers inserted into, assigned to and located rows by a column that does not exist
  (`column "approved_at" of relation "loans" does not exist`), on the key column as well as the others.
  Every statement now spells the column through the new `AshStrangler.Sql.Printer.column/2`
  (`Twin.column!/2`, quoted by `Printer.identifier/1`, now public). A lowercase column stays bare, so
  the SQL generated for an ordinary column is byte for byte what it was. The same mistake is fixed
  where it was repeated: the notify trigger and the change ledger (both read `affected.<attribute>`
  inside a savepoint, so a camel-case key skipped the notification or the event with only a
  `WARNING`), the ledger's `primary_key` payload, which is now keyed by the column's real name and
  read that way by the observation projector, the baseline and the generated ingestion module, the
  reconciler's legacy key, the watch trigger and the twin fixture writer (a quote in a column name),
  the `touch()` and hold renderings, and the SQL assertions `mix ash_strangler.check` measures.
  `AshStrangler.Backfill` quotes a column instead of refusing one that is not a plain identifier.
  **The ledger's `primary_key` key changes for a key column whose name differs from its attribute's:**
  events written before the upgrade carry the attribute name. Ordinary columns are unaffected.

- **A column with no forward expression is typed:** `unmapped [...], as: :null` rendered a bare
  `NULL` in the view, which PostgreSQL types as `text`, so `created_by_id = other.id` on a `uuid`
  attribute failed with `operator does not exist: text = uuid`. It now renders `NULL::uuid` (the
  attribute's Postgres type). A type the printer's table does not name keeps the bare `NULL`.
  **Existing installs with such a column of a type other than `text` need a `DROP VIEW` and
  `CREATE VIEW`:** `CREATE OR REPLACE VIEW` cannot change a column's type, so re-running a
  regenerated migration over a view built by an earlier version fails with
  `cannot change data type of view column`. A `:string` attribute was `text` already and replaces
  in place.

- **`ash_strangler.check` reads a twin identity's backing index by its key columns:** an
  expression index (`UNIQUE (tenant_id, lower(email))`) no longer reads as a unique `tenant_id`, and
  `INCLUDE` columns no longer count towards the set an index enforces.

- **Docs:** "regenerating is safe" now says what it covers. Re-running unchanged statements is safe;
  a change of shape (rename, retype, drop, reorder) is refused at migrate and needs a written
  `DROP VIEW` and `CREATE VIEW`.

- **`mix ash_strangler.check` now evaluates its casts.** The cast query was
  `SELECT count(*) FROM (SELECT <projections> ...) projection`, and Postgres removes projected
  expressions nothing reads from the plan, so no cast was ever run: a row holding `'abc'` under
  `(note)::int` counted as one row and passed. It now counts the whole projected row, so a stored
  value that cannot be cast raises, and the per-attribute retry names each attribute that holds one.
  `--no-data` still skips it. **A run that was green can turn red.** That is the check doing what it
  always said it did. The pass line and the docs ("the rows that will not cast") are now true.
- **`mix ash_strangler.check` no longer counts an invalid unique index as enforcing a twin
  identity.** The `pg_index` read now requires `indisvalid`, so the index a failed
  `CREATE UNIQUE INDEX CONCURRENTLY` leaves behind is reported as an identity Postgres does not
  enforce.
- **`mix ash_strangler.check` reads a twin's unique indexes by schema and relation name,** not
  through `$1::text::regclass`. A mixed-case relation is found, and a relation that has been dropped
  is a plain `FAIL` of the freshness check, with no `????` and no second line for twin identities
  beside it.
- **`mix ash_strangler.check --strict --no-data` is refused.** One says to fail on anything that was
  not measured and the other says to measure nothing. The task now raises at startup, before any
  check runs, and exits non-zero. It used to exit 0. The moduledoc and the docs said so and now say
  the opposite.
- **`documentation/topics/what-it-refuses.md` agrees with the code on an unreachable database:** it
  fails the task. The page said a check that could not run for want of a database did not.

- **`mix ash_strangler.check` names an unreachable database as one.** A connection error in the
  cast check used to be retried per attribute and reported as `cast <attribute>` failing for every
  mapped attribute. It is now reported once per resource, as `database could not be reached`, and
  still fails the task in the default mode. The moduledoc no longer says an unreachable database
  reports `????` and passes.

- **Union `:dual_write` updates no longer fail for every row.** The trigger
  casts each value to the legacy column's own type (a declared `:string` over an
  integer column used to raise), and `VerifyUnion` refuses two columns mapped
  from one legacy column on a `:dual_write` branch (the update would assign it
  twice). A column read from the legacy column that forms the key is read-only
  on that branch, so an update can no longer re-key a row, and the trigger
  raises if the re-read finds no row.
- **A union's owned insert refuses a supplied key that is already in the view**,
  so an id stays unique across branches.
- **Estate check E5 checks tenant closure.** The columns a `tenant_of` packs
  must be the tenant kind's own home columns or have a validated foreign key
  onto them in the estate's catalog; before, any column passed.
- **Estate check E8's carry rule counts whose column it is.** A column that only
  another module maps (a derived view over the same twin, say) no longer lets a
  resource or branch move to `:read_from_new`.
- **The obligation report counts what an assertion counts.** A `count(*)`
  assertion reports its number (not one), and an undecoded value of `0` is no
  longer read as no violations. `Obligation` has a new `:count` shape.
- **The element census counts a non-array value at the path** (a number, a
  string, an object) as one refused element, instead of dropping it unseen.
- **Logical keys include the twin's relation and escape their separator.** Two
  derived views of one kind no longer give the same id to equal parents, and a
  backslash or unit separator inside a text component cannot move a boundary.
  Ids of derived rows change with this release.
- **The ledger trigger builds its row image inside the savepoint.** A legacy
  migration that renamed or dropped a column the twin still names made every
  write to that table fail with `42703`; the event is now skipped with a
  `WARNING` and the legacy write commits.
- **An IN-list `CHECK` is read as a value set only when it is nothing else.**
  A constraint that combined the list with `OR`, `AND` or `NOT VALID` used to
  yield every quoted literal in it, so twins got a wrong `one_of` and drift
  missed a narrowed constraint.
- **A `NOT VALID` `NOT NULL` (PostgreSQL 18) is not `not_null`.** The column is
  recorded as nullable and the constraint is listed among the checks, unvalidated.
- **A domain's `NOT NULL` is no longer listed as one of its checks** on
  PostgreSQL 17 and later, so a catalog is the same on every major.
- **`strangler_*` objects are the strangle's on both sides:** drift skips them
  in the locked catalog as well as the live one, and `capture` leaves them out
  of `schema.sql`.
- **A 16-bit packed-key part raises in SQL when the value does not fit**, as
  the Elixir encoder does, rather than wrapping onto another key.
- **Generated SQL quotes a legacy column that is not a lowercase identifier**
  (`"effectiveDate"`), which PostgreSQL would otherwise fold to lowercase.
- **gen.twin:** two foreign keys to one table get two relationship names,
  taken from their attributes, and an unparsed `CHECK` is quoted in a note
  wrapped at 72 characters.
- The catalog moduledoc lists what drift cannot see.

### Changes

- **Ledger row images come from the twin's columns**
  (`AshStrangler.Sql.Ledger.image_columns/1`), not `to_jsonb(OLD/NEW)`, so a
  column the twin does not declare is no longer written to
  `legacy_change_events`. V-LEDGER refuses a ledger whose image would include a
  declared secret.
- **Trigger failure isolation:** the ledger's insert and wake, and the notify
  trigger's `pg_notify`, run in a savepoint. A failure, such as a dropped
  ledger table, raises a `WARNING`, and the legacy write commits.
- **Drift compares an IN-list `CHECK` on its value set:** a `CHECK` that is
  exactly `column IN (...)` no longer reports a change when only its text
  differs. A database built by migrations prints some IN lists (a varchar list
  cast to `text[]`) differently from the same constraint after a dump and
  reload, which is how the locked catalog is made.

## [0.4.0] - 2026-10-29

The single release containing shared rows, out-of-resource mappings, extension
stores, lifecycles over `collapse`, durable observations and the platform
conventions. Baseline tag `v0.1.0` remains the pre-expansion reference point.

### Features added in 0.4.0

- **Shared rows:** one resource over the live legacy relation and an owned
  extension table in the same PostgreSQL database and transaction. External
  Spark fragments (`use AshStrangler.Mapping, resource: ...`), the extension
  store, host/legacy key allocation, and a structural tenant derivation.
- **Lifecycles over `collapse`:** extension, refuse, lossy and derived answers
  for legacy-unrepresentable states; `AshStateMachine` is verified against the
  collapse, and the trigger carries the declared backward `set:`.
- **Observation beside materialisation:** a versioned envelope projected from
  the ledger's old/new images; repeatable-read baseline; per-consumer receipts,
  retry/quarantine/replay; joined-read invalidations; transaction-local
  correlation; the `AshStrangler.Observer` behaviour and generated Oban worker.
- **Platform conventions:** provenance in the extension store, archival
  mapped-or-refused, AshEvents replay refused on shared rows, and a read-only
  events-bridge resource that keeps action events distinct from observations.

### Breaking changes:

- **The mapping DSL is typed.** The transform inside a mapping was a raw SQL
  string in `from:`, with a *separately hand-written* inverse in `to:`/`into:`
  that nothing compared to it. One transform was consequently represented six
  times — forward string, backward string, trigger body, reverse-view body, a
  regex-guessed lineage, and a third mini-language in the reconciler's
  `normalize:` — with nothing relating any of them to any other.

  That let a wrong inverse ship, in this package's own fixtures: legacy `state`
  ranged over `passive | pending | active | suspended | deleted`, the forward
  direction sent every non-`active` value to `1`, and the backward direction sent
  `1` to `'suspended'`. Measured on PostgreSQL 17.10, a single `UPDATE` through
  the view assigning **only the email** rewrote three of five lifecycle states.
  No error, correct row count. All nine verifiers passed, because the one that
  claimed to check reversibility only checked that `to:` and `into:` were
  *present*.

  The replacement is `Ash.Expr` over a generated legacy **twin** resource, plus a
  closed grammar of invertible combinators from which both directions are derived.
  It is a clean break rather than a deprecation, and the reasoning is in
  `documentation/topics/the-transform-layer.md` §11 — the short version being that
  desugaring `from: "sql"` to `expr(fragment("sql"))` would classify every v1
  mapping *opaque*, which is the one tier that can be neither proven, inverted,
  tiered nor drawn, so the compatibility path would have bought nothing while
  keeping all six representations alive.

  Removed: `map`'s positional column and its `from:` (string), `to:`, `into:`,
  `cast:`, `from_zone:` and `writable?`; `constant`'s SQL string; the `index`
  entity; the `join` entity; `source "relation"` as a string, and `source`'s
  `as:`. A resource written against 0.1 does not compile, and the error names its
  replacement.

- **Derived-key creates that send an id cannot use `writes: :auto`.** An
  auto-updatable view rejects a value for its expression-backed id column.
  `VerifyKeyAllocation` now refuses that shape. Migration: set `writes:
  :triggers` so the legacy sequence allocates and the trigger re-reads the
  derived id, or make the primary key non-writable with no default so the
  create omits the id and PostgreSQL can allocate it through the view. The
  latter is measured working; host-created rows that need to choose their own
  id use `strategy: :identity`.

- **Partial collapse `set:` clauses now hold omitted columns.** They used to
  write NULL for a column omitted by a state; they now preserve the stored
  value on UPDATE and use the `:otherwise` state's value on INSERT. This is
  required for the handoff lifecycle, where `:archived` stamps `archived`
  without changing `processed`/`verified`. Migration: review every `set:` that
  relied on omission meaning NULL and write `column: nil` explicitly.

- **Security dependency floors.** Ash now requires at least `3.37.2` and
  AshPostgres at least `2.15.2`, which contain upstream fixes for tenant-scope
  bypasses in upserts and relationship loading. Migration: run
  `mix deps.update ash ash_postgres`; projects pinned below these versions must
  raise their constraints.

### Bug Fixes:

- **The ledger follows the host's owned schema instead of `public`.** The
  `legacy_change_events` table, its index and the ledger trigger function were
  written as `"public".…` literals, so a host migrating into its own schema
  still got a ledger in `public`. They are now unqualified and land in the
  migrating session's `current_schema()`, and the function is created with
  `SET search_path FROM CURRENT` so the trigger keeps inserting there from the
  legacy application's session. A host on the default layout still gets
  `public`. An existing deployment keeps its table where it is: no migration
  moves it, and the unqualified reads find it through `search_path`.

- **`ledger?` remains valid in `:read_from_new`.** The v0.1 verifier refused
  it because the legacy name is a reverse view, but the trigger now follows
  the authoritative owned table (the view's source) while any compatibility
  writer remains. Legacy writes through the reverse view fire no Ash notifier;
  the claim that Ash's own events cover writes past cutover is true only if
  every writer goes through Ash. `Sql.Notify` remains refused there because
  PostgreSQL rejects row-level triggers on views.

### Features:

- **The legacy relation is a resource.** `mix ash_strangler.gen.twin` introspects
  a legacy relation into a private, read-only, `migrate? false` Ash resource, and
  `source` takes that module. This is what makes `expr(first_name)` resolve to a
  typed column, and it collapsed four DSL constructs into things Ash already has:
  `cast:` is derived by comparing the twin's column type to the target attribute's,
  `index` is an `identity`, `join`/`on:` is a relationship, and the diagram's
  column-guessing regex is a fact. Reading `CHECK (col IN (...))` into a `one_of`
  constraint is what makes the totality obligations decidable at compile time.

- **A closed combinator grammar** — `AshStrangler.Lens`. Total bijections
  (`map from: :column`, a derived cast, `zone:`, `negate`, `affine`, `decode`),
  partial isomorphisms needing exactly one declared datum (`coalesce`, `concat`,
  `collapse`), and one opaque tier reached through `fragment(...)`. Both
  directions come from one declaration, so they cannot disagree.

  `collapse` is the case 0.1 could not express at all: four legacy columns and one
  attribute, where each clause carries a forward guard *and* the backward
  assignment. Because `set:` names every column the table touches, the reverse is
  total and canonical by construction. `touch()` marks the one deliberate loss.

- **Proof obligations, decided by finite-domain enumeration** —
  `AshStrangler.Obligations`. `GetTotal`, `PutTotal`, `PutGet`, `GetPut`, DMN
  completeness, masked rules, non-overlap, surjectivity, linearity, type agreement
  and redundancy, each reported as a **counterexample** rather than a verdict.
  Where an obligation cannot be decided — an unbounded value space, a `fragment`
  that cannot be evaluated in the BEAM — the same obligation is re-emitted as SQL
  and `mix ash_strangler.check` measures it against the real legacy data. Proven,
  or measured; never asserted.

  `writable?` is gone as a declaration: writability is derived from whether a
  reverse can be constructed, `read_only?: true` is an explicit opt-out that still
  requires `because:`, and a `because:` without one is refused.

- **Mechanism tiering** — `AshStrangler.Mechanism`. PostgreSQL's `CREATE VIEW`
  updatability rule is per **column**, so a view may hold a mix of updatable and
  read-only columns and a computed column errors only if something assigns to it.
  Measured on 17.10: such a view keeps upserts, `RETURNING` and
  `WITH CHECK OPTION` with no triggers at all. So each column is classified
  separately and the weakest mechanism that works is chosen, where 0.1 charged
  `INSTEAD OF` triggers to the whole resource for any writable computed mapping.

  `:generated` and `:base_trigger` are classified but not emitted, because both
  need `ALTER TABLE` on a relation this package does not own;
  `mix ash_strangler.check` reports both the ideal tier and the emitted one so the
  gap is a decision rather than a surprise.

- **One printer** — `AshStrangler.Sql.Printer`. The view, the triggers, the
  reverse view, the expression index, the reconciler and the check task all render
  through it, where they previously used five different string paths. The
  reference frame is a parameter, which is what replaced both
  `String.replace(to, "$NEW.", …)` sites and the `$NEW.` sigil authors had to type.
  All SQL literal escaping is one function, property-tested against PostgreSQL as
  a differential oracle.

- **Lineage as a model** — `AshStrangler.Lineage`, with Mermaid and OpenLineage as
  exporters. The diagram notation is now a projection of
  `AshStrangler.Lens.classify/1` rather than a second language invented to
  describe the first, and the "source columns not resolved" node is not
  expressible: lineage is read off an expression that was constructed rather than
  guessed out of a string. That regex had two consumers, and the second one
  degraded a failure to `[]`, so a column it could not parse vanished silently
  from every entity-relationship diagram the application drew.

- `unmapped [...], as: :default` is implemented. It was a documented option that
  raised *"not yet implemented"*, because nothing turned an Ash default into a SQL
  literal. A default that is a zero-arity function is refused rather than called:
  evaluating it would freeze one instant into the view definition.

- `on_update: :full_row | :changed_columns`, because `INSTEAD OF UPDATE` forbids a
  column list *and* forbids `WHEN` and `NEW` arrives fully populated, so nothing
  distinguishes "absent from the `SET` clause" from "set to its current value".
  There is no third option that is right, only a documented choice.

### Features:

- **The change ledger** — `ledger? true` beside `notify? true` on a source
  records every legacy write durably and drains it. One trigger on the legacy
  relation, in the legacy write's own transaction, inserts an event into a
  shared `legacy_change_events` table (full row before/after as jsonb, changed
  columns, `txid_current()`, the mapped primary key) and then notifies
  `wake:<event id>` — the wake replaces the JSON envelope on a ledger source,
  because the consumer of a ledger write is the drain, which re-reads the
  durable row anyway.

  `notify?` alone is at-most-once: a listener that is down misses writes with
  nothing to recover from. The ledger flips the guarantee to **at-least-once**
  — the event commits with the legacy write or not at all — at the price every
  synchronous audit trigger pays: the legacy application's write path now
  depends on the ledger's health. One ledger table serves every relation, keyed
  by `source_schema`/`source_table`, and the trigger names derive from
  `schema.table`, so resources mapping the same twin share it by construction.

  The table ships as plain DDL and stays plain: no Ash resource over it, on
  purpose. The drain policy — which events matter, who acts, what happens on
  failure — is host code, and the package generates its skeleton instead.

- **`mix ash_strangler.gen.ingester MyApp.Resource`** generates that skeleton
  into the host's `lib/`: an ingestion module performing ordinary Ash actions
  with `actor:` from a `resolve_actor/1` stub (`{:ok, actor} | :unattributed`)
  and `metadata:` carrying the source envelope, plus an idempotent Oban worker
  draining the ledger by cursor (`WHERE processed_at IS NULL ... FOR UPDATE
  SKIP LOCKED`, `processed_at` marked on success). The wake nudges the worker
  through `config :ash_strangler, ledger_drain: {Worker, :nudge}`; the periodic
  cron sweep documented in the worker's moduledoc is the recovery net for
  missed wakes. The insert/update branch of the ingestion raises rather than
  guessing which legacy column becomes which action input — the one fact no
  generator can derive.

- `mix ash_strangler.check` reports the unprocessed ledger backlog per relation
  when any mapped source carries `ledger? true`. A backlog is not a failure —
  it is the drain's pulse, and a number growing between sweeps is the early
  warning that it has stopped keeping up.

### Features (0.1):

- `AshStrangler.Resource`, a Spark DSL extension for describing how an Ash
  resource maps onto a pre-existing ("legacy") Postgres schema: the source
  table, per-attribute column mappings with optional casts, constants,
  deliberately unmapped columns, and the migration `phase` the resource is
  currently in.

- Verification for strangler-fig migrations onto legacy Postgres. A set of
  Spark verifiers refuses to compile a mapping that cannot hold up in
  production, rather than letting it fail at runtime — complete mapping,
  identities backed by real legacy indexes, no upserts against a mapping that
  cannot support them, legal phase transitions, timestamp zone agreement, and
  reversibility of every writable mapping.

- Generation of the compatibility view for the `:read_from_legacy` phase, so
  the Ash resource reads through a view over the legacy table instead of
  requiring the data to move first.

- Generation of `INSTEAD OF` triggers for the `:dual_write` phase, so writes
  through the compatibility view land in the legacy schema. `from_zone` became
  required for timestamp mappings as part of this — the trigger has to write an
  unambiguous value.

- Elixir-side key derivation (`AshStrangler.KeyDerivation`), covering the legacy
  key shapes that do not map onto an Ash primary key directly.

- `mix ash_strangler.check`, a pre-flight task that runs the verifiers over a
  set of resources without compiling a migration.

- Diagrams generated from the mapping, since it is already declared in one
  place and a picture maintained separately is a second description with
  nothing keeping it honest. `mix ash_strangler.gen.diagram` renders either a
  column-level `AshStrangler.Diagram.Mapping` per resource — legacy columns,
  the transformations between, and one edge per mapping carrying its cast, its
  writability and its `because:` — or an `AshStrangler.Diagram.Overview` of
  which relations feed which resources, which is the one that stays readable
  for a whole application. Plain 1:1 mappings collapse into a single node by
  default, because a rename is not a transformation and a dozen of them drawn
  out buries the ones that are; `--verbose` expands them.

- `AshStrangler.Resource` now implements `AshDiagram.Data.Extension`, so a
  strangled resource carries its legacy source into any entity-relationship
  diagram drawn of the application — including those produced by
  `mix ash.generate_resource_diagrams` and Clarity, neither of which knows this
  package exists. A Clarity content provider surfaces the mapping directly.

- `:ash_diagram` moved from a dev-only dependency to an optional one, so
  consumers can reach the diagram modules. They are guarded with
  `Code.ensure_compiled/1` and are simply not compiled without it.

### Fixed:

- HexDocs rendered every Mermaid diagram in the documentation as raw source.
  ex_doc has no built-in Mermaid support; the renderer script it documents is
  now injected via `before_closing_body_tag`.

### Testing:

- A round-trip property harness backed by a real Postgres server: a legacy
  fixture schema, generators that exercise the cases where `citext` folding,
  whitespace, and collation actually change the answer, and properties that read
  values back through the generated view.

- **Round-tripping is checked over the *legacy* value space.** The property that
  should have caught the corruption above generated
  `state_code <- member_of([0, 1])` — the one value set on which the broken
  mapping *is* a bijection — and its legacy-row helper never set `state`, so every
  row in the entire suite carried the column default `'active'`. It now generates
  over `passive | pending | active | suspended | deleted` and asserts that writing
  only the email leaves the lifecycle alone. Run against the v1 mapping before
  being ported, it failed on the first shrink with `passive` becoming `suspended`.

  The rule that follows, and that the whole design is built around: the legacy
  value space is the only one containing rows the tool did not create.

- `AshStrangler.MechanismTest` measures the tiering claim rather than restating
  it: `pg_column_is_updatable` per column, an `UPDATE` of a plain column
  succeeding and of a computed one erroring with PostgreSQL's own message, and
  `INSERT … ON CONFLICT DO UPDATE … RETURNING` working on the insert *and* the
  conflict — against the same legacy table whose trigger-backed sibling view
  rejects the identical statement.

- `AshStrangler.ObligationsTest` writes out a mapping that violates each
  obligation and asserts it is refused. Two spellings of that assertion do not
  work and both look like they should: Spark verifiers run post-compile, so
  `assert_raise` around `defmodule` catches nothing, and `Code.compile_string/1`
  emits the `DslError` as a compiler *warning* rather than raising it into the
  caller. The tests run the verifiers themselves over `spark_dsl_config/0`.

### Chores:

- Adopted REUSE/SPDX license headers across the repository.
