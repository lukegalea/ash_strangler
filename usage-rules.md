# Rules for working with AshStrangler

AshStrangler maps an Ash resource onto a legacy Postgres relation for a
strangler-fig migration. Version 0.1 verifies mappings and generates the
compatibility view for `:read_from_legacy`. It does not yet generate
`INSTEAD OF` triggers, the reversed `:read_from_new` view, backfill, or
notifications.

## The phase model

`phase` is the single control knob. An agent that does not know which phase a
resource is in cannot judge whether a change is safe.

| Phase | Reads from | Writes to | Safe to change |
|---|---|---|---|
| `:read_from_legacy` | legacy, via the view | nothing | freely |
| `:dual_write` | legacy | both | after backfill starts |
| `:read_from_new` | new tables | both | **only when backfill is complete** |
| `:decommissioned` | new tables | new tables | only when nothing writes legacy |

Phase changes are **one-way in practice**. Moving to `:read_from_new` with an
incomplete backfill produces missing rows, not an error.

## Rules

1. **Never hand-edit a generated migration statement.** Edit the mapping and
   regenerate. A hand-edited statement is invisible to the diffing generator and
   is reverted on the next codegen. This applies now: `:read_from_legacy`
   already generates the compatibility view via `custom_statements`.

2. **`writable? false` requires `because:`, and the text is user-facing.** It
   appears in the runtime error raised when something tries to write the
   attribute. "not writable" is not an acceptable reason; say what to do instead.

3. **Every attribute must be accounted for.** Mapped, `constant`, or listed in
   `unmapped ... because:`. An unmentioned attribute would read NULL for every
   legacy row — silent data loss, not a failure.

4. **`upsert?: true` is available only on `writes: :auto` mappings.** Against a
   view with an `INSTEAD OF` trigger, `ON CONFLICT DO NOTHING` is accepted and
   silently does nothing. If the compiler rejects an upsert, change the mapping
   or do not strangle that resource — do not work around the verifier.

5. **`oauth2` and `oidc` cannot be strangled with triggers.** Their
   `ash_authentication` transformer requires `upsert? true`; it is not
   configurable. The `password` strategy is fine.

6. **Adding an attribute to a strangler-backed resource is a schema change**,
   because the view's `SELECT` list must grow. Regenerate.

7. **Every Ash identity needs a declared `index ... unique: true`.** Otherwise
   Ash reports "has already been taken" for a constraint Postgres does not
   enforce, and duplicates are accepted with no error.

8. **Run `mix ash_strangler.check` before every phase change.** No exceptions.
   It reports what compile-time verification cannot know: whether the backfill is
   complete, whether the legacy write path is dead, whether the reconciler is
   clean.

## What the verifiers cannot check

They see one version of the code and have no memory of the previous one, so they
validate the *current state*, never the *transition*. Whether `:read_from_new` is
safe depends on the state of the data. That is `mix ash_strangler.check`.
