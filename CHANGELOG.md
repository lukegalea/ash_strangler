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

### Features:

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

### Chores:

- Adopted REUSE/SPDX license headers across the repository.
