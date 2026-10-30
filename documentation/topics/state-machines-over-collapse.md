<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# State machines over a collapse

`AshStateMachine` checks transitions against the attribute the view computes.
For shared rows that attribute must be a `collapse`: one decision table is the
answer to "what state is this?" for both the machine and the database.
`VerifyStateMachineBacked` refuses a machine over a `map`, `decode`, `constant`
or any other second answer; it also requires a collapse clause for every
machine state.

The Contract fixture is the handoff §5 table. Legacy encodes only
`processed`, `verified`, and `archived`; the other states get an explicit
answer:

```elixir
collapse :lifecycle_state do
  hit_policy :first

  state :negotiating, representation: {:extension, :lifecycle_state}
  state :archived, when: expr(not is_nil(archived)), set: [archived: expr(now())]
  state :expired, when: expr(expiry_date < fragment("CURRENT_DATE")), derived: true
  state :active, when: expr(processed and verified), set: [processed: true, verified: true]
  state :terminated,
    when: expr(processed and not verified),
    set: [processed: true, verified: false]

  state :ready_to_execute,
    representation: {:lossy, to: :draft,
                     loss: "terms finalised but not executed; legacy only knows un-executed contracts as draft"}

  state :cancelled,
    representation: {:refuse,
                     reason: "legacy clm_contracts has no cancelled encoding; cancelling is refused while legacy is authoritative"}

  state :draft, when: :otherwise, set: [processed: false, verified: false]
end
```

## The four answers

| Declaration | Forward read | Backward write |
|---|---|---|
| `{:extension, :column}` | Extension column condition first, before any legacy guard. | Writes the extension column; legacy columns are held (preserved on update, fallback on insert). |
| `{:refuse, reason: "..."}` | Never forward-produced. | Trigger raises P0001 with the reason. The state-machine transition is allowed to reach the trigger: the abort IS the declared answer (`cancel` in the fixture). |
| `{:lossy, to: :state, loss: "..."}` | Never forward-produced; reads collapse to the `to:` state. The loss prints verbatim under `Declared losses` in `mix ash_strangler.check`. | Writes the `to:` state's `set:` values. |
| `derived: true` + `when:` | Forward-only function of legacy data; time-nondeterministic guards are allowed because they render in SELECT, not a generated column. | Trigger refuses a write; the machine verifier refuses transitions to a derived target. |

A `derived:` state takes no `set:`. An extension/refuse/lossy state takes no
`when:` or `set:`. A lossy `to:` must name a state with a `set:`. Those are
`VerifyCollapseRepresentation`'s compile-time checks. Surjectivity exempts the
declared answers; completeness and overlap operate on the legacy `when:`
guards (extension conditions first, `:otherwise` last).

A state whose `set:` omits a legacy column **holds** it: preserved on UPDATE,
and the fallback's value on INSERT. This is why `:archived` stamps `archived`
without changing `processed`/`verified`, and why a negotiating contract can be
edited without its legacy flags jumping to the draft values.

## The machine checks and the lossy-state caveat

The view computes the state before AshStateMachine's guard runs. A transition
then writes through the named update action into the INSTEAD OF trigger, which
writes the declared `set:`. The fixture has no primary generic `:update`: an
executed contract is amended by `amend`, never edited by an arbitrary update.

A lossy state reads back as its declared `to:` state. Therefore a later
transition that follows it must accept that **read-back spelling** too: the
Contract fixture's `ready_to_execute` reads back as `draft`, so `execute` may
start from `:ready_to_execute` (the in-memory transition) or `:draft` (the
shared-row read-back). `AshStateMachine`'s guard still controls all other
origins; the trigger does not invent the state.

`require_atomic? false` on the fixture's named update actions is deliberate:
AshStateMachine's atomic guard expression cannot compile through a
view-backed data layer. Atomicity is the INSTEAD OF trigger's single SQL
statement; AshStateMachine's non-atomic changeset guard still runs before it.
