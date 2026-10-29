<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Integrating with an existing host

This is the step-by-step path from an Ash-owned table to a shared-row resource.
The Contract fixture is the worked example; follow the steps literally and
replace its names with the host's.

## 1. Generate typed twins

Introspect each legacy relation with `mix ash_strangler.gen.twin`. Keep the
twins `migrate? false`; they describe the legacy schema, they do not own it.
Declare relationships on the twins for every join the mapping reads through.
Regenerate the twins and run `mix ash_strangler.check` whenever the legacy
schema changes: a twin is a snapshot.

## 2. Move the mapping into a fragment

```elixir
defmodule MyApp.Legacy.ContractMapping do
  use AshStrangler.Mapping, resource: MyApp.Clm.Contract

  strangler do
    phase :dual_write

    source MyApp.Legacy.ClmContracts do
      key :id, from: :id, strategy: :identity
      map :name, from: :name
      extension [:negotiating_notes, :created_by_id]
      tenant :organization_id, derive: expr(client_party.organization_id)
    end
  end
end
```

Attach it from the resource with `fragments: [MyApp.Legacy.ContractMapping]`.
The resource keeps its ordinary `postgres`, `attributes`, `relationships`,
and `actions`; it has no `strangler` block and needs no
`extensions: [AshStrangler.Resource]` because the fragment carries the
extension. One source per resource: inline + fragment or two fragments is
refused.

Choose an explicit answer for every lifecycle state legacy cannot encode:
`representation: {:extension, :column}`, `{:refuse, reason: ...}`,
`{:lossy, to: ..., loss: ...}`, or `derived: true`. If the resource uses
`AshStateMachine`, its mapped state attribute must be a collapse.

## 3. Generate the compatibility migration

```sh
mix ash_strangler.gen.migration MyApp.Migrations.InstallContractStrangler
```

Read the generated SQL. It creates the extension table before the view that
joins it, then the write triggers, ledger/notify trigger and observation store.
Run it through the host's normal migration pipeline. One database is the
transaction boundary; do not split the view, trigger and extension table across
databases.

## 4. Check the real data

```sh
mix ash_strangler.check --domain MyApp.Domain
```

This runs the compiled obligations against the real legacy rows: NULLs,
identities, casts, constraint assertions, twin freshness, join fan-out,
mechanism costs, ledger backlog, declared losses, and any
`allow_unproven:` tenant exemptions. Fix the failures; review every warning.
No check can decide whether the backfill is complete -- the backfill and
reconciler are how you earn the next phase.

## 5. Install the ledger before starting observation

Set `notify? true`, `ledger? true`, and the consumers:

```elixir
source MyApp.Legacy.ClmContracts do
  notify? true
  ledger? true
  observers: [MyApp.ContractObserver]
  ...
end
```

The ledger trigger writes an event in the same legacy transaction. Start the
Oban worker rendered by:

```sh
mix ash_strangler.gen.observer MyApp.Clm.Contract MyApp.Repo
```

Then take the watch-start baseline:

```sh
mix ash_strangler.baseline MyApp.Clm.Contract --repo MyApp.Repo
```

The baseline is a snapshot, not a business event. Keep the generated worker's
cron sweep beside the wake listener; a missed wake costs delay, not delivery.

## 6. Correlate host writes

Wrap host commands with `AshStrangler.Context.set/3` when the host knows the
actor/origin/correlation:

```elixir
AshStrangler.Context.set(Repo, [origin: :host, actor: user.id,
                               correlation_id: request_id], fn ->
  Ash.create!(Contract, params)
end)
```

No context means unknown; nothing infers that the write came from legacy.

## 7. Inspect and recover

```sh
mix ash_strangler.observations --resource MyApp.Clm.Contract
mix ash_strangler.observations --quarantined
mix ash_strangler.observations --inspect <uuid>
mix ash_strangler.observations --replay --consumer MyApp.ContractObserver
```

Fix a consumer, replay its receipts, and rely on its `source_event_id`
idempotence. The source ledger is retained: observation replay never truncates
it. For a unified host event timeline, render the read-only bridge:

```sh
mix ash_strangler.gen.events_bridge MyApp.Clm --repo MyApp.Repo
```

Action events remain replayable host commands; observations remain read-only
facts about shared rows.
