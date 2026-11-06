<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Estates

Each strangled resource is checked from the new model's side. Every attribute
must be mapped, constant, unmapped or a key, or the resource does not compile.
Nothing checks the other direction: which legacy columns no mapping reads. A
column nobody mapped and nobody decided about is invisible to every verifier.
It is still invisible on the day the legacy application is switched off and
its data goes with it.

An estate checks that direction for the whole legacy schema at once. It names
a snapshot catalog (see the [Snapshots](snapshots.md) guide) and accounts for
every relation and every column in it, exactly once.

```elixir
defmodule MyApp.Legacy.Estate do
  use AshStrangler.Estate

  estate do
    snapshot "priv/legacy/snapshot/catalog.json"
    resources [MyApp.Lending.Book, MyApp.Lending.Member, MyApp.Lending.Loan]
    plugins [MyApp.Legacy.EstateRules]

    carried "lending.books.shelf_note", because: "free text the new model does not read"
    dead "lending.branches.fax", because: "no fax machine since 2019"
    deferred "lending.fines", wave: :billing, target: "Lending.Fine", because: "billing moves later"
    legacy_only "lending.sessions", because: "the old application's own sessions"
    dead "lending.fax_log", because: "nothing has written it since 2019"

    residue "lending.old_reservations", because: "dropped by a migration; old restores keep it"

    open_reference "lending.loans.loans_member_id_fkey",
      because: "NOT VALID: old loans name deleted members"
  end
end
```

## Dispositions

A column's disposition is either **computed** from compiled declarations or
**declared** in the estate. It is never both.

| Disposition | Computed from | Meaning |
|---|---|---|
| `mapped` | the mappings of `resources` | a mapping reads it: a mapped value, the key, the tenant derivation, or either side of a join |
| `secret` | the `secrets` of every twin involved | it never leaves the legacy database |
| a plug-in kind | `c:AshStrangler.Estate.Plugin.claims/2` | the host's own machinery reads it |
| `carried` | declared | the new model does not use it, but it travels opaquely beside the row so the legacy application keeps it after cutover (columns only) |
| `deferred` | declared, with `wave:` and `target:` | a later wave strangles it |
| `legacy_only` | declared | stays with the legacy application |
| `dead` | declared | nothing reads or writes it |

`deferred`, `legacy_only` and `dead` may name a whole relation
(`"lending.fines"`), which covers every column the relation has, including
columns a later capture adds. A relation that any mapping or claim reads can't
be declared as a whole. Its columns are dispositioned one by one, so a column
added to it fails the build until somebody decides what it is.

Computed dispositions are computed so that the estate can't claim a column is
mapped when no mapping reads it. Deleting a mapping turns its column into an
unaccounted-for column, and the build fails.

## The checks

`AshStrangler.Estate.evaluate/1` returns an `AshStrangler.Estate.Report`. Its
`problems` come from these checks:

| Check | Fails when |
|---|---|
| declarations | a declaration names a relation or column the catalog doesn't have; `carried` names a relation; something is declared twice; a column is declared inside a relation declared as a whole; a `residue` is in the catalog; an `open_reference` names a foreign key the catalog doesn't have |
| resources | a listed module is neither a strangled resource nor a twin, or a mapping reads a column the catalog doesn't have |
| claims | a plug-in claims a missing column, or uses a reserved kind |
| coverage | a column has no disposition, or has a declaration and a computed claim |
| consistency | a relation declared as a whole has computed claims |
| writers | two resources write one legacy column |
| references | a foreign key whose columns are mapped is `NOT VALID`, or references columns nothing maps or claims, and is not declared as an `open_reference`; or an `open_reference` is not needed |
| phase | a resource or branch at `:read_from_new` or later leaves a column `deferred` or `legacy_only`, or something reads a decommissioned relation (E8) |
| tenant | a tenant-scoped union or derived view has a branch or source that doesn't derive its tenant through a tenant key kind (E5, below) |
| plugin | a plug-in's `check/1` returned a message |

The reference rule closes the strangled part of the schema. If a mapped
column points at a row, that row must be reachable in the new model too. When
that is deliberately not yet true, `open_reference` records the decision. When
it becomes true, the `open_reference` turns stale and fails until it is
removed.

### Tenant closure (E5)

A union or a derived view that declares a `tenant` column is tenant-scoped, and
every row it can show must name its tenant, derived from the legacy row alone.
Otherwise a join in some mapping could put a row of one tenant behind another.
E5 holds each legacy branch of a union, and each source of a derived view, to
three rules:

- It answers the tenant column with `tenant_of`, the packed key of a registry
  kind declared `tenant?: true`
  (`tenant_of :clinic, kind: {MyApp.Keys, :clinic}, from: :clinic_id`). A
  `map`, an expression, a `constant` or an `unmapped` answer is refused.
- The kind exists in its registry and is a tenant kind.
- The column is declared `null?: false`, so the owned branch can't hold a row
  with no tenant.

Each problem names the module, the branch or source and the column.

## Where the checks run

`AshStrangler.Verifiers.VerifyEstate` runs the declaration checks when the
estate module compiles. They need only the estate and its catalog, which is an
`@external_resource` of the estate, so a new capture recompiles it.

The other checks read other modules' compiled mappings, so they run after
everything is compiled, in the `:ash_strangler_estate` Mix compiler:

```elixir
# mix.exs
def project do
  [compilers: Mix.compilers() ++ [:ash_strangler_estate], ...]
end

# config/config.exs
config :my_app, ash_strangler_estates: [MyApp.Legacy.Estate]
```

The compiler runs on every `mix compile`. A check that ran only when the
estate module recompiled would miss a mapping edited somewhere else. It reads
files and compiled modules only; it never touches a database. Each problem
becomes an error diagnostic. A problem about a declaration points at the
declaration's line, and any other problem points at the `estate` block.

## The manifest

```bash
mix ash_strangler.estate MyApp.Legacy.Estate --manifest priv/legacy/estate-manifest.json
```

The task evaluates the estate, prints every problem and exits 1 if there are
any. `--manifest` writes `AshStrangler.Estate.manifest/1` as canonical JSON
(format `ash_strangler.estate/1`):

```json
{
  "catalog": {"path": "priv/legacy/snapshot/catalog.json", "sha256": "…"},
  "counts": {"columns": {"carried": 1, "mapped": 12}, "relations": {"columns": 4, "dead": 1}},
  "drift_allow": ["relation lending.old_reservations"],
  "estate": "MyApp.Legacy.Estate",
  "format": "ash_strangler.estate/1",
  "open_references": {"lending.loans.loans_member_id_fkey": {"because": "…"}},
  "problems": [],
  "relations": {
    "lending.books": {
      "kind": "table",
      "disposition": "columns",
      "columns": {
        "title": {
          "disposition": "mapped",
          "claims": {"mapped": ["MyApp.Lending.Book", "MyApp.Lending.Loan"]},
          "written_by": ["MyApp.Lending.Book"]
        },
        "shelf_note": {"disposition": "carried", "because": "…"}
      }
    },
    "lending.fines": {"kind": "table", "disposition": "deferred", "wave": "billing", "target": "Lending.Fine", "because": "…"}
  },
  "residue": {"lending.old_reservations": {"because": "…"}}
}
```

The manifest is what the legacy side can read: which columns the new
application depends on, and which it writes. Commit it next to the snapshot if
the legacy repository's CI should check a migration against it.

## Residue and drift

A live legacy database can carry relations the catalog doesn't have, such as
tables an old migration dropped that old restores still contain. List them as
`residue`. They are dead by declaration, they must not be in the catalog, and
`AshStrangler.Estate.drift_allow/1` turns them into allow patterns for the
drift gate:

```elixir
AshStrangler.Snapshot.drift(dir, MyApp.Repo.config(), AshStrangler.Estate.drift_allow(MyApp.Legacy.Estate))
```

The manifest carries the same patterns under `drift_allow`, so a script can
write them to a file for `mix ash_strangler.snapshot drift --allow-file`.

## Plug-ins

The estate knows only what this package knows: the catalog, the declarations
and the mappings. A host usually has more. It may project legacy rows into
owned tables, read legacy rows to build an access context, keep a stored
legacy verdict as a test oracle, or follow a house vocabulary rule. A plug-in
brings both halves:

```elixir
defmodule MyApp.Legacy.EstateRules do
  @behaviour AshStrangler.Estate.Plugin

  alias AshStrangler.Estate.Claim

  @impl true
  def claims(_estate, _catalog) do
    for column <- ["id", "name"] do
      %Claim{relation: "lending.branches", column: column, kind: :projected, by: MyApp.BranchDirectory}
    end
  end

  @impl true
  def check(report) do
    for {_name, %{declared: %{kind: :deferred, target: target}}} <- report.relations,
        not String.starts_with?(target, "Lending."),
        do: "deferred target #{inspect(target)} is outside the Lending namespace"
  end
end
```

A claimed column is computed, like a mapped one. A claim may not use a kind the
estate computes or declares itself (`AshStrangler.Estate.Claim.reserved_kinds/0`).
`check/1` sees the finished report: every relation, every column's claims,
declaration and writers, and the problems found so far. All three callbacks are
optional. `claims/2` and `check/1` run on every compile, so they must not touch a
database; `obligations/1` (below) only runs when the report is measured.

## The obligation report

Some things about an estate are facts about rows: how many elements a guard
refuses, whether a stored verdict agrees with a derived one. A plug-in's
`obligations/1` returns `AshStrangler.Estate.Obligation`s, each a query with
the denominator it is measured over. The estate adds its own: the assertions
that `AshStrangler.Obligations` couldn't decide at compile time for each
strangled resource, and a census of the elements each `element` source of a
derived view refuses (`AshStrangler.Estate.Obligations.registry/1`).

```
mix ash_strangler.check --estate MyApp.Legacy.Estate --report obligations.json
```

measures them against the legacy database and writes JSON in the
`ash_strangler.obligations/1` format. `--no-data` skips the queries. The task
exits 1 when an obligation fails or can't be measured, or when the estate has a
problem.

| Key | Meaning |
|---|---|
| `format` | `"ash_strangler.obligations/1"` |
| `estate` | the estate module |
| `catalog` | `path` and `sha256` of the snapshot the run is keyed by |
| `measured` | `false` when no query ran |
| `summary` | counts: `total`, `pass`, `warn`, `fail`, `error`, `skipped` |
| `problems` | the estate's own checks: `check`, `subject`, `message`, sorted |
| `obligations` | one object each, sorted by `id` |

An obligation object has `id`, `source` (the module that contributed it),
`summary`, `denominator` (what the count is over, in words), `severity`
(`"error"` or `"warning"`), `status`, `violations` and `total` (integers, or
`null` when not measured or when the obligation has no denominator count) and
`detail` (the error message, or at most ten offending rows).

`status` is `pass` (no violations), `warn` (violations of a warning), `fail`
(violations of an error), `error` (the query couldn't run) or `skipped`. An
obligation that couldn't be measured is not green. The report holds no
timestamp, so the same estate over the same rows gives the same bytes.

## What it proves, and what it doesn't

The estate proves, at compile time, that every relation and column of the
pinned catalog has exactly one disposition, and that the computed ones agree
with the mappings and claims that exist. It doesn't prove the catalog matches
the live database. That is the drift gate. It also doesn't prove a `dead`
column is really dead. That is a measurement against real rows, and the
`because:` is where the evidence is recorded.
