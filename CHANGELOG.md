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

### Testing:

- A round-trip property harness backed by a real Postgres server: a legacy
  fixture schema, generators that exercise the cases where `citext` folding,
  whitespace, and collation actually change the answer, and properties that read
  values back through the generated view.

### Chores:

- Adopted REUSE/SPDX license headers across the repository.
