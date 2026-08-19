<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Rules for working with AshStrangler

AshStrangler maps an Ash resource onto a legacy Postgres relation for a
strangler-fig migration. From one declaration it derives a compatibility view,
`INSTEAD OF` triggers where a write genuinely needs them, an expression index, a
backfill, a reconciler, a notification bridge, column-level lineage, and the
compile-time checks that refuse a mapping it cannot prove.

**There is no slot for a hand-written inverse anywhere in this DSL.** If you find
yourself wanting to write one, you are looking for a combinator. That is the
single most important thing on this page.

## The two modules

A mapping is always two modules, and only one of them is written by hand.

```elixir
# 1. The TWIN — generated, never typed:
#      mix ash_strangler.gen.twin --relation legacy.users --module MyApp.Legacy.Users
defmodule MyApp.Legacy.Users do
  use Ash.Resource,
    domain: MyApp.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "users"
    schema "legacy"
    repo MyApp.Repo
    migrate? false            # Ash does not own this table and never will
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :login, :string
    attribute :email, :string
    attribute :first_name, :string
    attribute :last_name, :string
    attribute :deleted_at, :naive_datetime

    attribute :state, :atom do
      constraints one_of: [:passive, :pending, :active, :suspended, :deleted]
    end
  end

  identities do
    identity :index_users_on_login, [:login]
  end
end

# 2. The RESOURCE, mapped onto it:
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "users"             # the VIEW this creates
    schema "strangler"
    repo MyApp.Repo
    migrate? false            # Ash owns the view, not the legacy table
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :full_name, :string, public?: true
  end

  strangler do
    phase :read_from_legacy

    source MyApp.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :email, from: :email
      map :archived_at, from: :deleted_at, zone: "UTC"

      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
    end
  end
end
```

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

---

## Rules

### The twin

1. **Generate the twin; never type one by hand.** `mix ash_strangler.gen.twin`
   reads `pg_attribute`, `pg_index` and `pg_constraint`, so the columns, types,
   primary key, unique indexes and foreign keys come from the database rather than
   from somebody's memory of it. Typing it restates a schema the database already
   knows, which is the defect the whole typed layer exists to remove.

2. **A twin is a snapshot, so run `mix ash_strangler.check`.** A column the legacy
   application's next migration adds is invisible to every mapping until the twin
   is regenerated. `check` diffs each twin against `information_schema.columns` and
   its unique sets against `pg_index`, and exits non-zero on a mismatch so it can
   gate CI. Without that, the typed layer inherits exactly the staleness problem it
   was built to remove.

3. **A `CHECK (col IN (...))` becomes `:atom` with `one_of`, and that is
   load-bearing.** It is what gives the compiler a domain to enumerate, which is
   what makes `GetTotal` decidable at compile time instead of measurable only
   against data. If the generator emitted `:string` with a comment about a
   constraint it could not parse, do not hand-edit a `one_of` in — a *wrong*
   `one_of` makes the compiler refuse correct mappings. Fix the constraint or let
   `check` measure it.

4. **`source` takes the twin module.** `source "legacy.users"` is refused with
   `expected module in :twin option`. The relation name, the schema, and the
   column names all come off the twin; there is nowhere to write them twice.

### Writing a mapping

5. **`from:` is a bare column atom or an `expr(...)`. A SQL string is refused**,
   and the error names the three replacements:

   ```
   expected an expression, got the string "coalesce(first_name,'') || ' ' || coalesce(last_name,'')".

   For a plain column:            from: :some_column
   For a projection:              from: expr(first_name <> " " <> last_name)
   For SQL with no combinator:    from: expr(fragment("coalesce(first_name,'') || ...")).

   The last form classifies the mapping opaque, which means no derived write
   path, so it also needs `read_only?: true` and a `because:`.
   ```

   Do not reach for `fragment` first. It is the escape hatch, and it costs the
   mapping its write path, its mechanism tiering and its provability.

6. **Ash has no `coalesce/2`, and the two symbols you want are inverted relative
   to SQL.** This trips up everyone who has written SQL:

   | Intent | Ash | Renders as |
   |---|---|---|
   | null-default | `a \|\| b` | `coalesce(a, b)` |
   | concatenate | `a <> b` | `a \|\| b` |

   `expr(coalesce(a, b))` does not fail where you write it — it parses as a call to
   a function that does not exist and fails later — so the printer refuses it by
   name. Write `expr(first_name || "")`.

   Null-default every operand of a concatenation. SQL's `||` propagates NULL, so
   one absent `last_name` blanks the whole value and the attribute reads as nothing
   for that row.

7. **Never write an inverse. Pick a combinator.** Both directions come from one
   declaration, which is the only way they cannot disagree:

   | You want | Use | Reverse |
   |---|---|---|
   | a rename | `map :attr, from: :col` | the same column, and **no mechanism at all** |
   | a naive timestamp read as an instant | `map :attr, from: :col, zone: "UTC"` | `AT TIME ZONE` the other way |
   | a coded value | `decode :attr, from: :col, values: %{...}` | the inverted table |
   | a boolean read inverted | `negate :attr, from: :col` | itself |
   | a scaled number | `affine :attr, from: :col, multiply: 100` | `(y - add) / multiply` |
   | a NULL read as a default | `coalesce :attr, from: :col, default: 0` | `NULLIF` — *semi*-invertible |
   | several columns joined | `concat :attr, from: [:a, :b], separator: " "` | `split_part` — *semi*-invertible |
   | several columns collapsed into one lifecycle | `collapse :attr do state ... end` | the per-clause `set:` |
   | an attribute with no legacy source | `constant :attr, expr(...)` | none — read-only by construction |
   | an attribute deliberately unmapped | `unmapped [:a], as: :null, because: "..."` | none |

   A `collapse` clause's `set:` must name **every** legacy column the table
   touches, in every clause. That is what makes the reverse total and canonical,
   and it is why there is no "which of the four do I write" question left.

8. **Writability is derived. `read_only?: true` requires `because:`, and
   `because:` without `read_only?` is refused.** The `because:` text is quoted
   verbatim in the runtime error the trigger raises, so "not writable" is not an
   acceptable reason — say what to do instead. Prose asserting a limitation the
   mapping does not have is exactly the drift the check exists to remove.

9. **Every attribute must be accounted for.** Mapped, `constant`, `unmapped ...
   because:`, or the key. An unmentioned attribute would read NULL for every legacy
   row — silent data loss, not a failure. Adding an attribute to a
   strangler-backed resource is therefore a schema change: regenerate.

10. **Do not put a `zone:` on an already-aware column**, and **do state `zone:`
    whenever a naive legacy `timestamp` feeds an aware attribute.** The first is
    refused: `AT TIME ZONE` on a `timestamptz` converts it *back* to naive, which
    is the opposite of the intent. The second is not yet refused and needs
    discipline — a bare `map :archived_at, from: :deleted_at` between a
    `:naive_datetime` twin column and a `:utc_datetime_usec` attribute derives
    `(deleted_at)::timestamptz`, which reads the value as wall-clock time in the
    **session's** `TimeZone`. Measured at 10.5 hours of drift between two
    connections reading the same row, with no error anywhere. Which zone a naive
    column is recorded in is a fact about the *old application*; there is nothing
    in the database to read it from, so state it.

11. **Never restate what the twin already says.** `cast:` is gone — the cast is
    derived by comparing the twin's column type to the attribute's type. An
    `index` entity is gone — uniqueness is an `identity` on the twin. A `join`
    entity is gone — a join is a relationship on the twin, read as
    `expr(address.city)`. And a redundant transform is refused by name: an identity
    `decode`, `affine multiply: 1, add: 0`, a single-column `concat`.

12. **Every Ash identity must be backed by an `identity` on the twin.** Otherwise
    Ash plans upserts and reports "has already been taken" against a constraint
    PostgreSQL does not enforce, and duplicates are accepted with no error. If the
    constraint really exists on the legacy table, the twin is stale — regenerate
    it rather than typing the identity in by hand, because the generator reads
    `pg_index`, which is the only thing that actually knows.

### Joins

13. **A join is a relationship on the twin, and gathered columns are read-only.**
    Only `belongs_to` and `has_one` resolve; a `has_many` is refused by name
    because it would multiply view rows. The join is always `LEFT` and there is no
    option — a relationship says which rows *relate*, not which rows survive. A
    cross join is not expressible, because there is no `on:` predicate to leave
    out.

    Writes key off `__legacy_id`, which identifies a row in the *primary* relation
    only, so a mapping reading through a relationship must be `read_only?: true`
    with a reason. If you need to write those columns, give the joined relation its
    own resource and its own view — that is usually what the model wanted anyway.

    Run `mix ash_strangler.check` after adding one. A `has_one` the database does
    not actually enforce as unique makes the view return duplicates for a single
    primary key, and only real data can reveal that.

### Generating and migrating

14. **The DDL comes from `mix ash_strangler.gen.migration`, NOT `mix
    ash.codegen`.** A strangler resource must declare `migrate? false` in
    `:read_from_legacy` and `:dual_write`, and the compiler enforces it: left at
    the default, codegen emits a `create table` for the view's own name and the
    view DDL then fails against it. But `migrate? false` also stops the resource
    producing a snapshot, and `custom_statements` are only read from snapshots — so
    there is no configuration in which codegen can carry this. Never hand-edit a
    generated migration; edit the mapping and regenerate.

15. **Never compute a modern id by querying for it.** Use
    `AshStrangler.KeyDerivation.derive/3` (or `uuid_v5/2` + `name/2`), which is a
    pure function asserted to agree byte-for-byte with the SQL the view uses. Do
    not reimplement the hashing or re-spell the `"<relation>:<id>"` name format
    anywhere — both sides go through `name_prefix/1` precisely so they cannot
    drift, and a drift produces `Ash.get/2` returning nothing for rows that exist.

16. **The mapped primary key must not be declared with a default, and does not
    need `generated? true` written by hand** — the extension sets it, because the
    view computes the id and Ash would otherwise reject every create with
    `attribute id is required`. Declare it plainly:
    `attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false`.

17. **`upsert?: true` needs `writes: :auto`.** Against a view with an `INSTEAD OF`
    trigger, `ON CONFLICT DO UPDATE` errors and `ON CONFLICT DO NOTHING` is
    accepted and silently does nothing. If the compiler rejects an upsert, look at
    **which** mapping forced the triggers — `mix ash_strangler.check` prints the
    classification per attribute — and see whether it can be a combinator that
    needs a weaker mechanism, or read-only. Do not work around the verifier.

    PostgreSQL's `CREATE VIEW` updatability rule is per *column*: a view may hold a
    mix, and a computed column errors only if something assigns to it. So a
    **read-only** computed column costs nothing — a view of plain references plus
    read-only computed ones stays `writes: :auto` and keeps upserts. A **writable**
    row-local computed column (a derived cast, a `zone:`, a `decode`) classifies as
    `:base_trigger` but is *emitted* as `:instead_of`, because the cheaper mechanism
    needs `ALTER TABLE` against the legacy table. `AshStrangler.Mechanism.report/1`
    prints both columns, so the gap is visible rather than assumed.

18. **`oauth2` and `oidc` cannot be strangled with triggers.** Their
    `ash_authentication` transformer requires `upsert? true`; it is not
    configurable. The `password` strategy is fine.

### Phases

19. **Run `mix ash_strangler.check` before every phase change. No exceptions.** It
    reports what compile-time verification cannot know: NULLs where you declared
    `allow_nil? false`, duplicates under a new identity, values that will not cast,
    twin staleness, join fan-out, and every proof obligation the compiler could not
    decide — re-emitted as SQL and run against the real rows. Proven, or measured;
    never asserted.

20. **`:read_from_new` is a one-way door and the compiler treats it as one.** Every
    mapping must be fully reversible, because the legacy name becomes a view over
    the new table and the old application still reads those columns.
    `invertible: :semi` is refused there as well as `invertible: :no` — a
    `coalesce`, a `concat` or a `collapse` carrying `touch()` reverses only
    *modulo* something, which is fine while the legacy row still exists to compare
    against and not fine once it stops existing. Do not work around
    `VerifyReverseMappable`; carry the legacy columns across instead.

21. **The resource needs a stored `legacy_id` before cutover.** The uuid derivation
    runs one way, so the reverse view cannot recover the legacy key — it has to
    have been carried across by the backfill and stored.

### Backfill and reconciliation

22. **Derive both from the resource.** `AshStrangler.Backfill.plan/2` and
    `AshStrangler.Reconciler.plan/2` are pure, so print them and read them before
    running anything. Retyping the arguments has one quiet failure mode each: a
    hand-typed key expression that differs from the view's by a byte, and a
    `columns:` list that omits a column — **a comparison that skips a column
    reports agreement.** The hand-passed forms exist for the table no resource
    describes yet, not for the one that has a mapping.

23. **Backfill with the flag column, never `WHERE new_col IS NULL`.** An `IS NULL`
    predicate cannot terminate once a target column's correct value may legitimately
    be null, which `unmapped ..., as: :null` guarantees. The failure is a hung job,
    not an error: every pass does real work and reports real progress, and the job
    simply never finishes.

24. **There is no `{:sql, template}` normalizer.** The reconciler derives its
    normalizers from the attribute's own Ash type (`:ci_string`, `:downcase`,
    `:trim`), and a time zone is part of the forward expression rather than a
    normalizer of its own — stated once in `zone:`, printed into both sides of the
    comparison. A hand-passed `normalize:` still takes the three shorthands plus a
    one-arity function, and an unrecognised value raises rather than being ignored.

25. **Expect Ash's own casting to differ from what the legacy app writes.**
    `Ash.Type.CiString` trims by default, so during `:dual_write` a value written
    through Ash may not be byte-identical to the same value written directly by the
    old application. Both are correct. That is what the derived normalizer is for;
    it is not a bug to fix in the mapping.

26. **`:ci_string` folds differently depending on the database collation.** citext
    folds by calling SQL `lower()`, which follows `LC_CTYPE`. Under `C` only ASCII
    folds; under a UTF-8 locale non-ASCII case folds too. The same mapping
    therefore gives a *different uniqueness answer* on two servers — and a
    strangler migration has two servers in it by definition. Check the collation on
    both before relying on a citext identity. It never folds whitespace, and never
    normalizes NFC against NFD, under any collation.

### Documentation and observability

27. **Never hand-draw a diagram of a mapping.** `mix ash_strangler.gen.diagram`
    renders it from the declaration — per resource, or `--type overview` for the
    whole application, `--format json` for OpenLineage. A drawing made by hand is a
    second description of the mapping with nothing keeping it honest, which is the
    exact failure the `strangler` block exists to prevent. If a diagram in a README
    or a document is wrong, regenerate it; do not edit the picture.

28. **Notifications are opt-in (`notify? true`) and at-most-once.** Never build a
    `pg_notify` payload from row data: the ceiling is 7999 bytes and exceeding it
    aborts the *legacy application's* transaction. Never use them to count writes —
    PostgreSQL collapses duplicates within a transaction. `LISTEN` does not work
    under pgbouncer transaction pooling.

29. **Give `AshStrangler.Listener` read options if the resource has policies.**
    The listener re-reads the affected row through `Ash.get/3`, and it is not
    acting for a person — a legacy write has no Ash actor behind it. With no
    `:actor` and no `:authorize?` the read is forbidden, `notify/2` returns `:ok`
    having dispatched nothing, and the only symptom is a page that stops
    updating. `authorize?: false` is usually right: the notification announces
    that a row changed, and consumers re-read under their own actor.

30. **A `:read_from_legacy` resource's notifications carry a synthesized
    `:legacy_write` action.** There is no real one to name — nothing writes at
    that phase — so `publish_all :create, [...]`, which matches on the action's
    *type*, fires; `publish :some_action, [...]`, which matches on its *name*,
    does not. Write publications for a strangled read model with `publish_all`.

---

## What the verifiers cannot check

They see one version of the code and have no memory of the previous one, so they
validate the *current state*, never the *transition*. Whether `:read_from_new` is
safe depends on the state of the data. That is `mix ash_strangler.check`.

When a check refuses something, read the message rather than working around it.
Each one names the mapping responsible, what the failure would have cost, and the
replacement — and where the answer is a counterexample rather than a verdict, it
prints the counterexample. See
[what it refuses to generate](documentation/topics/what-it-refuses.md) for every
check and the failure it prevents.
