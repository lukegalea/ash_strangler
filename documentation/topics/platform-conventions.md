<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Platform conventions on shared rows

These are generic mechanisms for a host integrating a view-backed resource over
shared PostgreSQL rows. `ash_strangler` does not choose a host's event model,
multitenancy configuration or provenance schema; it states what the shared-row
boundary guarantees, and refuses the conventions that cannot be made true.

## Provenance belongs in the extension store

The legacy schema has no column for host-only provenance. Store it in the
resource's extension table:

```elixir
source MyApp.Legacy.Contracts do
  extension [:created_by_id]
end
```

The extension table is keyed by the canonical id and committed in the same
transaction as the shared legacy row. On create, both rows commit or neither
does. On update, the extension upsert and legacy write are one PostgreSQL
transaction. A legacy row with no extension row yet reads the attribute's
static literal default (or NULL) through `COALESCE`; the first host write makes
the extension row real.

Provenance is asserted only by the host write that supplied it. Nothing
backfills an actor for historical rows, and no context is inferred from the
absence of a value. The `created_by_id` Contract fixture exercises the
round-trip and the rollback path against the real extension table.

## Archival is mapped or refused

`AshArchival` sets an archive attribute on destroy. On a shared-row resource,
that set travels through the compatibility view and must have a **writable
legacy representation** (`map`, `zone`, `collapse`): otherwise the trigger has
nowhere to write it. `VerifyArchival` refuses the resource at compile time with

> archival has no legacy representation: map the archive attribute onto the
> legacy encoding or refuse archival on this resource

The Contract fixture's `archived_at` (`map :archived_at, from: :archived,
zone: "UTC"`) plus its `:archived` collapse state is the positive case. The
extension store is not a substitute: AshArchival's timestamp in an extension
column while the legacy lifecycle says "not archived" is two answers to
"was this archived?".

## AshEvents replay is refused while rows are shared

AshEvents replay clears and rebuilds the resource's data from its event log. On
a shared-row resource, those rows are still live legacy rows: replay would
rewrite or delete the old application's data through the INSTEAD OF triggers.
Call the host hook at the top of the replay path:

```elixir
AshStrangler.AshEvents.refuse_replay!(MyApp.Clm.Contract)
AshEvents.Replay.replay(...)
```

It raises on `:read_from_legacy` and `:dual_write`, before AshEvents touches
anything. It permits replay after `:read_from_new`, when the resource owns its
table and the compatibility layer is gone.

Observations are not action events. `mix ash_strangler.gen.events_bridge`
renders a companion **read-only** resource over `strangler_observations` for a
unified timeline. It has no create/update/destroy, so there is no action path to
replay observations through. "Luke ran `Contract.archive`" (an action event)
stays distinct from "the shared row's `archived` changed in legacy" (an
observation).

## The `:read_from_new` ledger statement, corrected

`ledger? true` remains valid in `:read_from_new`. The ledger trigger now
attaches to the **owned table** (the reverse view's source), where PostgreSQL
accepts a row-level trigger. Capture follows the authoritative base storage for
as long as any compatibility writer exists -- including legacy writers through
the reverse view, which fire **no Ash notifier**. The statement "Ash's own
events cover writes after `:read_from_new`" is true only if every writer goes
through Ash.

`notify?`'s compatibility trigger remains refused in that phase: PostgreSQL
rejects row-level triggers on a view. The durable ledger trigger has a different
target and is not the notify bridge.
