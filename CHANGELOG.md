<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

Nothing has been released yet. Everything below is the initial body of work,
summarised from the commit history.

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
