<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Codegen

`mix ash.codegen` is the gate a host already runs in CI, and by itself it cannot see the
compatibility layer: a strangled resource declares `migrate? false`, so AshPostgres writes no
snapshot and no DDL for it. A mapping change that leaves the installed view stale is then caught
only later, by `mix ash_strangler.check --strict` against a database.

`AshStrangler.Codegen` closes that gap without a database. It renders the current statements from
the compiled resources (the same function `mix ash_strangler.gen.migration` writes migrations
from) and compares them with a committed snapshot of what the installed layer contains.

## Adopting it

1. Attach the extension to each domain whose strangled resources it should cover:

   ```elixir
   use Ash.Domain, extensions: [AshStrangler.Codegen]
   ```

2. Seed the snapshots from the layer you have already installed:

   ```bash
   mix ash.codegen --snapshots-only
   ```

   Commit `priv/strangler_snapshots/`. Check the diff is empty against your installed DDL first:
   `mix ash_strangler.check --strict` says whether the database agrees with the render.
3. Delete any hand-written `codegen/1` hook of your own. `mix ash.codegen` would otherwise run two.
4. From now on `mix ash.codegen --check` fails when the mapping and the snapshots disagree, and
   `mix ash.codegen <name>` writes the migration and refreshes the snapshots together.

## Opt-in by attachment

`mix ash.codegen` runs every extension defined in every dependency that depends on `ash`,
attached or not. `AshStrangler.Codegen` therefore runs in every host that depends on this package,
and does nothing but print one `info` line unless at least one domain in the application's
`:ash_domains` attaches it. Only resources of attaching domains are covered, plus the
`unions:` and `deriveds:` named in `config :ash_strangler`, which are application-wide. A host
that upgrades without attaching it sees no change.

## Flags

| Invocation | Effect |
| --- | --- |
| `--check` | Raises `Ash.Error.Framework.PendingCodegen` naming each stale resource. |
| `--dry-run` | Prints the pending statements. |
| `<name>` | Writes `<version>_<name>_strangler.exs` in each repo's migrations directory and refreshes the snapshots. |
| `--snapshots-only` | Writes the snapshots and no migration. This is how an existing host seeds them. |
| `--dev` | Refuses while anything is pending; a no-op when clean. |

### Why `--dev` refuses

AshPostgres uses `--dev` so its final named run can roll back the dev migrations and squash them
against resource snapshots. The strangler layer has no such squash, and its statements are
idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`), so a dev migration would only add a second
name for DDL the final run rewrites, and leave a `schema_migrations` row orphaned. Run
`mix ash.codegen <name>` directly while developing. An iteration that changed nothing in the
mapping still passes through `--dev`.

## Snapshots

`priv/strangler_snapshots/<repo underscored>/<resource modules underscored and joined with _>.json`,
one file per resource, with the keys `resource` and `statements: [{name, up}]`. `down` is not
recorded because the renderer derives it from `up`.

Statements are compared in order, including the view reshape guard. The snapshot records what the
renderer produces, not what a migration file once contained, and the guard's `up` embeds the
view's expected column list, so it changes whenever the view changes shape.

`AshStrangler.Codegen.pending/1` returns one entry per stale resource with a status of `:missing`
(no snapshot), `:invalid` (unreadable or wrong shape) or `:changed`, a summary, and the pending
statements.

## Versions and the migration counter

`next_migration_version/1` allocates a version strictly after the newest file in the repo's
migrations directory and after AshPostgres's last allocated version. The latter is read from, and
published into, the process key `:ash_postgres_last_migration_timestamp`, which AshPostgres does
not document. If AshPostgres renames it, a collision becomes possible only when this extension runs
before AshPostgres in the same run; the directory scan still covers running second.

## More than one repo

Covered resources are grouped by the repo their `AshPostgres.DataLayer` declares. Each group gets
its own migration in that repo's `priv` directory and its own snapshot directory, because a
migration is executed by one repo. Resources that declare no repo use the first `ecto_repos` entry.

## Configuration

```elixir
config :ash_strangler, AshStrangler.Codegen,
  snapshot_root: "priv/strangler_snapshots",
  migration_suffix: "strangler"
```

## `mix ash_strangler.gen.migration`

The dedicated task still works. When the resource's domain attaches the extension it refreshes the
snapshots of the resources it writes, so the two ways of writing the DDL cannot disagree.
