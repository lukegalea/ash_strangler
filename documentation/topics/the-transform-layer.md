<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# The transform layer

**Status: implemented.** This document is the design, and it is now also the description of what the
package does. Every code sample compiles; the DSL reference generated from the entities is at
[`documentation/dsls/DSL-AshStrangler.Resource.md`](../dsls/DSL-AshStrangler.Resource.md), and the
fixtures under `test/support/` are working mappings for every construct described here.

Building it changed eight things about the design, and they are recorded in
[§15](#15-what-building-it-changed) rather than quietly folded in. Six were mistakes in this document;
two were bugs the implementation surfaced that the design had no way to anticipate. The measured
PostgreSQL results in [§7](#7-pick-the-weakest-mechanism-that-works) are unchanged and real.

**§11 is a clean break.** The string-based DSL is removed, not deprecated, and an earlier draft of this
document argued the opposite. That reversal, and why the deprecation argument is wrong, is the substance
of that section.

---

## 1. The declaration is typed at its edges and untyped at its centre

`AshStrangler`'s claim is *declare it once, derive the rest*. The `strangler` block is checked for
shape — is the attribute accounted for, is the cast deterministic, does a joined column claim to be
writable — and from that shape it derives a view, triggers, an index, a backfill, a reconciler, a
notification bridge and two diagrams.

But the *transform* inside the shape is a SQL string. The compiler can see that `from:` exists; it
cannot see inside it. So the one thing every consumer needs — which columns feed this value, and can
the value travel back — is either restated by hand or guessed.

Count the restatements. **One transform is represented six times:**

| # | Where | Representation |
|---|---|---|
| 1 | forward projection | the SQL string in `from:` — `AshStrangler.Sql.View.mapped_expression/1` |
| 2 | backward projection | a *separate, hand-written* SQL string in `to:` plus `into:` |
| 3 | trigger write body | `String.replace(to, "$NEW.", "NEW.")` — `AshStrangler.Sql.Triggers.write_expression/1` |
| 4 | reverse view at `:read_from_new` | `String.replace(to, "$NEW.", "")` — `AshStrangler.Sql.ReverseView.reverse_column/1` |
| 5 | column lineage, for both diagram generators | a regex plus a 60-word SQL keyword denylist — `AshStrangler.Diagram.Sql.columns/2` |
| 6 | reconciler comparison | a hand-passed `columns:` list, plus a third mini-language: `normalize: %{email: :ci_string, archived_at: {:sql, "%s AT TIME ZONE 'UTC'"}}` |

Nothing relates any of these to any other. Representations 1 and 2 are supposed to be inverses and are
never compared. Representation 5 is a *guess* at what 1 says. Representation 6 restates information
that is already in the resource's Ash types.

The README admits the gap without naming it: the mapping diagram needed **a second notation** — four
shapes and four line styles — to describe what the first notation does. Needing a second language to
talk about the first is the symptom, not the disease.

### The one transform whose inverse is derived

There is exactly one exception, and it proves the point. `cast: :timestamptz, from_zone: "UTC"` *does*
have a derived inverse — a naive column reads as `col AT TIME ZONE 'UTC'` and writes back as
`NEW.attr AT TIME ZONE 'UTC'`. That rule is hard-coded in four places:
`Sql.View.with_cast/2`, `Sql.Triggers.write_expression/1`, `Sql.ReverseView.reverse_column/1`, and
again as `{:sql, "%s AT TIME ZONE 'UTC'"}` in the reconciler.

So the design already wants a combinator library with derived inverses. It has one combinator, no
framework, and four copies of it.

---

## 2. The bug this design exists to refuse

`Verifiers.VerifyWritableMappingsReversible` checks that `to:` and `into:` are **present**. It never
relates them to `from:`. The consequence is not hypothetical: the mapping below ships in this
repository, in `test/support/dual_write_user.ex` and `test/support/diagram_resources.ex`, and is the
worked example in the reference application's plan.

```elixir
map :state_code do
  from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
  to   "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END"
  into "state"
end
```

The legacy `state` column ranges over `passive | pending | active | suspended | deleted`. Forward sends
every non-`active` value to `1`. Backward sends `1` to `'suspended'`. So the pair is a bijection on
`{active, suspended}` and destroys everything else.

Run against PostgreSQL 17.10, using the SQL the generators actually emit — five legacy rows, then a
single `UPDATE` through the view that assigns **only the email**:

```
-- Legacy state, and what the view projects:
     login      | legacy_state | state_code
----------------+--------------+------------
 passive_user   | passive      |          1
 pending_user   | pending      |          1
 deleted_user   | deleted      |          1
 active_user    | active       |          0
 suspended_user | suspended    |          1

UPDATE strangler.dual_users SET email = 'changed@example.com';

-- Legacy state afterwards. `state` was never assigned:
     login      | legacy_state_now
----------------+------------------
 passive_user   | suspended
 pending_user   | suspended
 deleted_user   | suspended
 active_user    | active
 suspended_user | suspended
```

**Three of five lifecycle states silently rewritten by a write that did not mention the lifecycle.** No
error, no warning, correct row count. This is precisely the failure class
[what-it-refuses.md](what-it-refuses.md) opens by describing — *"the migration runs, the query succeeds,
the row count looks right, and the data is wrong"* — occurring in the package's own reference example,
past all nine verifiers.

It fails from the modern side too. `state_code` is a bare `:integer` with no `one_of` constraint, so
`7` is a legal value:

```
UPDATE strangler.dual_users SET state_code = 7 WHERE login = 'active_user';

    login    | legacy_state | reads_back_as
-------------+--------------+---------------
 active_user | suspended    |             1
```

### Why the tests do not catch it

`test/ash_strangler/dual_write_test.exs` has a round-trip property test. It is named *"an arbitrary row
written through Ash reads back as it was stored"* and it generates
`state_code <- StreamData.member_of([0, 1])` — the one value set on which the mapping *is* a bijection.
Meanwhile `DataCase.insert_legacy_user!/1` never sets `state`, so every legacy row in the entire suite
carries the column default `'active'`.

The suite tests round-tripping over the **modern** value space. The modern value space contains only
rows this package created. The legacy value space is the one containing rows the old application wrote
over fifteen years, and it is untested.

> **The rule the whole design follows from:** round-tripping must be checked over the **legacy** value
> space, because that is the only space containing rows the tool did not create.

### The second-order failure: lineage is guessed

`Diagram.Sql.columns/2` strips string literals, casts and numbers with regexes, then rejects a
hard-coded keyword list, and treats what remains as column references. When it finds nothing it returns
`:unresolved`.

Its moduledoc argues, correctly, that a diagram which quietly omits edges it could not work out is
worse than no diagram — so the mapping diagram draws a rhombus reading *"source columns not resolved"*.

But it has a **second** consumer that does not get that treatment.
`AshStrangler.Resource.legacy_columns/1` feeds the `ash_diagram` extension hook, and there
`:unresolved` degrades to `[]`. A column the heuristic could not parse silently vanishes from every
entity-relationship diagram the application draws — including the ones `mix
ash.generate_resource_diagrams` and Clarity produce. The README says of that diagram: *"Only the
columns the mapping actually names appear: `is_active` is absent because nothing reads it, which is the
sort of thing you want to find out from a picture."* That guarantee holds only as far as the regex does.

---

## 3. Three principles

**Grammar, not analysis.** Do not accept an arbitrary expression and try to invert it. Every result in
reversible computing points the same way: invertibility is guaranteed by a restricted grammar, never
recovered by post-hoc analysis (Janus; Theseus; Sparcl — Matsuda & Wang, ICFP 2020; surveyed in Glück &
Yokoyama, *TCS* 2022). So `AshStrangler` accepts **combinator constructors** and *emits* expressions
from them. Free-form `expr(...)` stays available, and is classified opaque.

**Prisms, not lenses.** In the general lens formulation `put` reads the original source row. Here it
does not: a column mapping is stateless. That means `PutPut` holds for free, which means these are
*very well behaved* lenses — partial isomorphisms with the semi-iso round-trip laws (Rendel &
Ostermann 2010). Stating this as an invariant removes the need to thread the original row through the
trigger at all. There is exactly one deliberate exception, timestamp preservation, and it is marked in
the DSL rather than buried in the generator.

**Proven or measured, never asserted.** Whatever can be decided at compile time is refused at compile
time. Whatever cannot — because a `fragment` makes evaluation impossible — becomes a SQL assertion that
`mix ash_strangler.check` runs against the real legacy data. Nothing is taken on the author's word.

---

## 4. `Ash.Expr` as the IR, over a generated legacy twin

The transform becomes an `Ash.Expr` tree, and `fragment(...)` — Ash's own escape hatch — becomes the
**single** node kind meaning "opaque". That distinction is the one a string cannot make, because a
string is uniformly opaque.

```elixir
map :full_name, from: expr((first_name || "") <> " " <> (last_name || ""))
```

> **Read that operator carefully, because SQL and Ash disagree about both symbols.** Ash has **no
> `coalesce/2` function** — there is no such module under `Ash.Query.Function.*` and it is not in
> `Ash.Filter.builtin_functions/0`. Null-defaulting is the `||` operator, which `AshSql` renders as SQL
> `coalesce` when the left operand cannot be boolean.
> And SQL's `||` — string concatenation — is Ash's `<>`. So the two symbols a reader coming from SQL is
> most likely to reach for both mean something else:
>
> | Intent | Ash | Renders as |
> |---|---|---|
> | null-default | `a \|\| b` | `coalesce(a, b)` |
> | concatenate | `a <> b` | `a \|\| b` |
>
> This is worth stating in a design document rather than discovering during implementation, because
> `expr(coalesce(first_name, ""))` does not fail as a missing function at the point you write it — it
> parses as an `%Ash.Query.Call{name: :coalesce}` and fails later, during hydration. It is also why the
> combinator table below defines a `coalesce(default)` combinator of *our own*: the grammar has to supply
> the semantics it wants to invert, rather than assuming Ash already named it.

Every mechanism this needs already exists in the pinned dependencies (ash 3.31.3, spark 2.7.2,
ash_postgres 2.11.0, ash_sql 0.6.7):

| Need | Mechanism | Where Ash itself does this |
|---|---|---|
| `expr(...)` inside a Spark entity | `Spark.Dsl.Entity`/`Section` `imports: [Ash.Expr]`, option `type: :any` | `Ash.Resource.Dsl`'s `@filter` entity; the `identities`, `aggregates` and `calculations` sections |
| accept *either* a bare column atom or an expression in one slot | `{:or, [:atom, {:custom, Mod, :fun, []}]}` | `Ash.Resource.Calculation.expr_calc/1` |
| lineage | `Ash.Filter.list_refs/5` — with `expand_calculations?: true` it inlines expression calculations and returns **leaf** attributes | `Ash.Filter.used_aggregates/3` |
| structural rewriting | `Ash.Filter.map/2` | throughout `Ash.Filter` |
| compile-time evaluation | `Ash.Expr.eval/2`, `eval!/2` | calculations evaluated in the BEAM |
| type inference | `Ash.Expr.determine_types/4` | operator/function type resolution |

### The twin

`expr(first_name)` has to resolve `first_name` against something. `Ash.Expr.expr/1` happily builds
`%Ash.Query.Ref{attribute: :first_name, resource: nil}` without consulting a resource — but hydration
(`Ash.Filter.hydrate_refs/2`) looks the name up on one, and `AshSql.Expr` raises *"Unsupported
expression"* for a `Ref` whose `attribute` is still a bare atom.

So **the legacy relation is declared as an ordinary Ash resource**: private, read-only,
`migrate? false`, generated by introspecting the live database. Call it the *twin*.

```elixir
# generated by `mix ash_strangler.gen.twin --relation legacy.accounts`
defmodule MyApp.Legacy.Accounts do
  use Ash.Resource, data_layer: AshPostgres.DataLayer, domain: MyApp.Legacy

  postgres do
    table "accounts"
    schema "legacy"
    migrate? false          # we do not own this table and never will
  end

  attributes do
    attribute :id,           :integer, primary_key?: true, allow_nil?: false
    attribute :first_name,   :string
    attribute :last_name,    :string
    attribute :is_deleted,   :boolean
    attribute :cancelled_at, :naive_datetime
    attribute :approved_at,  :naive_datetime
  end

  identities do
    identity :index_accounts_on_email, [:email]   # read from pg_index, not typed by hand
  end
end
```

```elixir
strangler do
  source MyApp.Legacy.Accounts do
    key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-…"}
    map :email, from: :email
  end
end
```

This is the only route that yields **both** real SQL generation and real lineage, and it is what
collapses most of the restatement:

| 0.1 | With a twin |
|---|---|
| the `Diagram.Sql` regex, and the `known_columns:` option that exists to compensate for it | legacy columns are typed attributes; lineage is `list_refs/1`. Both **deleted** |
| `cast: :citext` | derived by comparing the twin's column type to the target attribute type. `cast:` survives only as an override |
| `join "legacy.addresses", as: "addr", on: "addr.account_id = accounts.id"` — arbitrary SQL | a relationship on the twin; the mapping reads `expr(address.city)`, and fan-out becomes a property of a declared relationship rather than of an opaque predicate |
| `index "index_users_on_login", unique: true, columns: ["login"]` | an `identity` on the twin, checked against `pg_index` |
| `mix ash_strangler.check` cannot run the model's assertions | they are ordinary Ash reads over the twin — see below |
| reconciler `columns:` and `normalize:` | `Reconciler.diff(resource)`; both sides read through Ash, so normalisation *is* the type |

The `check` row deserves its own note, because it closes a **documented feature that does not exist**.
`README.md` and the reference application's plan both describe `mix ash_strangler.check` as running the
new model's assertions against legacy data — NULLs where `allow_nil? false`, duplicates under a new
identity, values that will not cast. The task does no such thing today: it reports the mapping,
measures join fan-out, and prints three checks it tells you to make yourself. With a twin, each
assertion is a query the model already implies:

| Model assertion | The check it becomes |
|---|---|
| `allow_nil? false` | `Ash.count(twin, filter: is_nil(^source))` |
| `identity [:email]` on a `:ci_string` | an aggregate grouped by the normalised expression |
| a cast | project the mapping over the twin and count the failures |
| `collapse` totality | the guards are `Ash.Expr`; count rows matching no clause |

### One sequencing constraint

`Ash.Expr.expr/1` yields `%Ash.Query.Call{}` for operators *and* for `fragment` — not `Operator` and
`Fragment` structs — until `hydrate_refs/2` runs, and that needs a resource. So the DSL **stores the
unhydrated tree** and hydrates later: in a verifier, where the module exists, or at
migration-generation time, where a repo exists. Both `AshStrangler.Info` and `AshStrangler.Sql.View`
already accept "a compiled module *or* the mid-transform `dsl_state`", so the pattern is established.

---

## 5. The combinator grammar

Three tiers. Ship tiers 1 and 2; make tier 3 loud and narrow.

### Tier 1 — total bijections. The reverse is mechanical; no annotation.

| Combinator | Forward | Reverse | Note |
|---|---|---|---|
| `from: :col` | `col` | `col` | a rename. **Needs no trigger at all** — see §7 |
| `cast:` | `col::citext` | `col::text` | delegates to `Ash.Type.cast_input/2` + `dump_to_native/2`, which is *already* a lens pair |
| `negate` | `NOT is_deleted` | `NOT active` | |
| `affine` | `a*x + b` | `(y-b)/a` | restricted to `a = ±1` or a numeric type — integer division is not invertible |
| `zone:` | `col AT TIME ZONE 'UTC'` | `attr AT TIME ZONE 'UTC'` | replaces `cast: :timestamptz, from_zone:` and its four copies |
| `decode` | a lookup | the inverse lookup | below |
| `compose` | `f ∘ g` | `g⁻¹ ∘ f⁻¹` | reverse-order composition |

`zone:` is best built as an `Ash.CustomExpression` rather than a raw fragment: it then renders per data
layer, carries its own inverse, and is walked by `list_refs/1` and `Ash.Filter.map/2`, which descend
into a custom expression's `.expression`.

### Tier 2 — partial or defaulted. The reverse needs exactly one more datum.

| Combinator | Reverse | What must be declared |
|---|---|---|
| `coalesce(default)` | `NULLIF(v, default)` | an iso only if the default is not otherwise a legal value; otherwise a declared semi-iso |
| `drop(default)` | `INSERT … VALUES (default)` | the default, checked against the column's own `NOT NULL`/`CHECK`. This is the relational-lens side condition `{A = a} ∈ P[A]` (Bohannon, Pierce & Vaughan, PODS 2006) |
| `concat(sep)` | `split_part` | a separator provably absent from both operands — the degraded form of Boomerang's regex-ambiguity condition (POPL 2008) |
| `collapse` | a per-clause assignment | below |
| `synthesize` | none | today's `writable? false`, narrowed to an explicit escape hatch |

### Tier 3 — opaque

`expr(fragment("…"))`. No derivation, `because:` required, classified `{:opaque, reason}`. Every real
project needs this; the point is that it is now *one* node kind rather than the only kind.

### `decode` — a declared bijection

```elixir
decode :state_code, from: :state, %{
  "active"    => 0,
  "passive"   => 1,
  "pending"   => 2,
  "suspended" => 3,
  "deleted"   => 4
}
```

Both directions come from one declaration. Checked at compile time: injectivity, exhaustiveness against
the attribute's `one_of` constraint or `AshStateMachine` state list — **read from the resource, not
restated** — and totality.

The cautionary tale is Rust's `strum` against `serde`: `serialize_all` and `rename_all` disagree by
default, so one enum acquires two non-matching encodings and round-tripping quietly breaks
([strum#278](https://github.com/Peternator7/strum/issues/278)). **Derive both directions from one
declaration, never two.** That is the whole thesis, and it is the thesis `map … from …/to …` violates.

### `collapse` — a decision table

The four-columns-into-one-lifecycle case. Today it can only be written as an irreversible `CASE`; the
README's own example concedes this with *"Four legacy columns with no single inverse. Supply
`to:`/`into:` before enabling dual-write"* — which is an invitation to write the bug in §2.

This is not an invention. It is Sparcl's `case … of { p → e with e′ }` (rule **T-RCase**, ICFP 2020)
and HOBiT's bidirectional `case` (ESOP 2018): each branch carries a forward pattern *and* a backward
exit condition. The DMN vocabulary supplies the rest — a **hit policy**, and *completeness* as a
separate property (OMG DMN; analysis algorithms in Calvanese, Dumas, Laurson, Maggi, Montali &
Teinemaa, BPM 2016).

```elixir
collapse :status, hit_policy: :first do
  state :archived,  when: expr(is_deleted),
                    set: [is_deleted: true,  cancelled_at: nil,     approved_at: nil]
  state :cancelled, when: expr(not is_nil(cancelled_at)),
                    set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]
  state :active,    when: expr(not is_nil(approved_at)),
                    set: [is_deleted: false, cancelled_at: nil,     approved_at: touch()]
  state :pending,   when: :otherwise,
                    set: [is_deleted: false, cancelled_at: nil,     approved_at: nil]
end
```

Because `set:` names **every** legacy column the table touches, the backward direction is total and
canonical by construction — there is no "which of the four do I write" question left to get wrong.

From that one block: the forward `CASE` for the view, the backward multi-column assignment for the
trigger, the reverse-view columns, the diagram's fan-in, and the four proofs in §6.

`touch()` is the one declared `PutPut` violation, and it is explicit for that reason: write `now()` only
on an actual transition (comparing `OLD.status`), otherwise preserve the stored timestamp. Round-tripping
`:cancelled` cannot recover the original instant, so the alternative to declaring the loss is
pretending it does not happen.

---

## 6. The proof obligations

Named after the literature, so an error message is searchable. Decided by **finite-domain enumeration**,
not by a solver.

The reason to prefer enumeration is not implementation cost, it is diagnostics, and Calvanese et al.
state it directly: a solver *"leads to a boolean output (is the set of rules satisfiable?), and cannot
natively highlight specific sets of rules that need to be added to a table (missing rules), nor
specific overlaps between pairs of rules"*. `unsat` is not a next step. "You have no clause for
`:pending`" is. And the input space is small: guards range over booleans and `is_null` abstractions of
a handful of columns, so it is 2ⁿ with n around six. Enumerate it.

| Obligation | Source | The failure it refuses |
|---|---|---|
| `GetTotal` | PODS 2006 | a legacy value the forward direction cannot turn into a valid attribute value |
| `PutTotal` | PODS 2006 | an attribute value with **no** legal legacy encoding — this is what catches `state_code: 7` |
| `PutGet` | lens laws | forward ∘ backward ≠ identity — **this is what catches §2** |
| `GetPut` | lens laws | backward ∘ forward ≠ identity; genuine loss must be a declared semi-iso |
| completeness | DMN / Calvanese et al. | an uncovered cell in the guard lattice — a *missing rule* |
| non-overlap, masked rule | DMN hit policies `UNIQUE` / `FIRST` | a clause no input can ever reach |
| surjectivity | — | a declared state no clause can produce, so reads never show it |
| linearity | the relevance condition from reversible languages | two mappings both writing `is_deleted`; two mappings producing one attribute |
| type agreement | `Ash.Expr.determine_types/4` | the forward expression's type is not the target attribute's |
| redundancy | pgroll's `ColumnMigrationRedundantError` | a declared transform that is the identity — the direct anti-restatement check |

`PutGet` on the §2 mapping, stated as the enumeration the verifier would run:

```
 legacy_value | projects_to | writes_back_as |     verdict
--------------+-------------+----------------+------------------
 active       |           0 | active         | ok
 suspended    |           1 | suspended      | ok
 deleted      |           1 | suspended      | PUTGET VIOLATION
 passive      |           1 | suspended      | PUTGET VIOLATION
 pending      |           1 | suspended      | PUTGET VIOLATION
```

Two rules for how these are reported. **Name the counterexample, not the verdict** — BIRDS generates
concrete counterexamples for exactly this reason. And where a `fragment` makes BEAM evaluation
impossible, emit the *same* obligation as a SQL assertion for `mix ash_strangler.check`:

```sql
SELECT count(*) FROM legacy.accounts
WHERE <forward(backward(forward(row)))> IS DISTINCT FROM <forward(row)>;
```

Compile-time where possible, against real data where not. Nothing merely asserted.

### `writable?` stops being a declaration

A mapping is writable when the tool can construct and verify its inverse. So:

- `writable?` is **derived**, and reported by `mix ash_strangler.check` rather than typed.
- `writable? false` becomes an explicit **opt-out**, still requiring `because:` — that text is quoted
  verbatim in the runtime trigger error, which is the reason it was ever mandatory.
- `because:` becomes **forbidden** on a mapping proven invertible, so the prose cannot drift from the
  fact. Today a mapping can say "not decomposable" about something perfectly decomposable and nothing
  objects.

### An acknowledgement this design owes the reader

**BIRDS** (Tran, Kato & Hu, *PVLDB* 13(12), 2020) is the closest existing work — a DSL that compiles to
PostgreSQL views plus `INSTEAD OF` triggers and verifies well-behavedness with Z3 — and it went the
*other way*. In BIRDS the programmer writes the **putback** direction and `get` is derived, because
`put` determines `get` uniquely while `get` does not determine `put`.

This design derives `put` from `get`. That is sound **only** because the grammar is restricted to
(semi-)isomorphisms and demands an explicit choice — `set:`, `default:`, or an opt-out — at every point
where invertibility genuinely fails. If the grammar is ever widened to accept arbitrary expressions in
the invertible position, this reasoning collapses and BIRDS's choice becomes the correct one.

---

## 7. Pick the weakest mechanism that works

This section is the largest practical win, and it comes from the PostgreSQL manual rather than from any
of the theory above.

`CREATE VIEW` documents a **column-level** rule that is easy to read past:

> A column is updatable if it is a **simple reference to an updatable column of the underlying base
> relation**; otherwise the column is read-only, and an error will be raised if an `INSERT`, `UPDATE`,
> or `MERGE` statement attempts to assign a value to it.

So an automatically updatable view may contain a **mix** of updatable and read-only columns. A computed
column does not force a trigger. It forces an error only if somebody assigns to it.

`AshStrangler.Info.derive_writes/1` assumes otherwise: any writable computed mapping forces
`:triggers`, for the whole resource. Measured against PostgreSQL 17.10 on a view with two plain
references and two computed columns, **no triggers**:

```
   column   | pg_column_is_updatable
------------+------------------------
 id         | t
 email      | t
 full_name  | f
 state_code | f

UPDATE mixed_v SET email = 'b@example.com';        -- succeeds
UPDATE mixed_v SET full_name = 'Nope';
  ERROR:  cannot update column "full_name" of view "users_v"
  DETAIL:  View columns that are not columns of their base relation are not updatable.
DELETE FROM mixed_v WHERE id = 1;                  -- succeeds
INSERT INTO mixed_v (email) VALUES ('c@example.com')
  ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email
  RETURNING id, email, full_name, state_code;      -- works, on both the insert and the conflict
```

**Upserts, `RETURNING` and `WITH CHECK OPTION` all survive a view with computed columns.** They are lost
to the *trigger*, not to the computation. pgroll exploits exactly this: its versioned views are pure
rename projections, it emits **no `INSTEAD OF` triggers at all**, and the transformation lives in a
`BEFORE` trigger on the base table plus a shadow column.

So classify each mapping and pick the weakest mechanism:

| Mapping shape | Mechanism | Cost |
|---|---|---|
| simple reference or rename | plain auto-updatable view | **none** |
| immutable, single-row derivation | `GENERATED ALWAYS AS (…) STORED` on the base table | declarative DDL, indexable, no trigger, no backfill |
| row-local derivation that must be written back | `BEFORE` trigger on the **base table** plus a shadow column | one trigger on the legacy table; the view stays auto-updatable |
| multi-table write, or non-invertible | `INSTEAD OF` trigger | loses upserts, correct `RETURNING`, `WITH CHECK OPTION` |

### This corrects a load-bearing conclusion elsewhere

The reference application's plan concludes that **authentication must cut over first**, because
`state_code` is computed-but-writable, which drags in an `INSTEAD OF UPDATE` trigger, which costs
upserts across the whole resource, which breaks `ash_authentication`'s OAuth2 strategies. The reasoning
is sound; the premise is not. With mechanism tiering, a `decode`d `state_code` is a candidate for a
generated column or a base-table `BEFORE` trigger, the view stays auto-updatable, and upserts survive.
That changes the recommended *order* of a real migration.

### Three techniques worth lifting from pgroll

- **`%TYPE` locals aliasing `NEW.*`.** Declaring `name legacy.users.name%TYPE := NEW.name` is how a
  bare-column-name expression compiles with no parser, and it gets type checking from PL/pgSQL for
  free.
- **`search_path` as the writer-identity signal.** Direction detection with no session GUC and no
  cooperation from the legacy application.
- **The `needs_backfill` interlock.** The trigger sets the flag `false` when it does the work, so the
  backfill never redoes a row the trigger already handled. `AshStrangler.Backfill` already borrowed the
  flag column from pgroll — and credits it — but not the interlock, so the backfill/trigger race is
  still open.

### Seven Postgres facts that become verifiers

Each has a silent-failure mode, which is why each belongs in a verifier rather than a guide.

**1. `WITH CHECK OPTION` is ignored on a trigger-updatable view.** The manual says so; measured, it is
worse than ignored. The same view definition, the same violating `INSERT`:

```
-- auto-updatable, WITH CASCADED CHECK OPTION:
INSERT INTO active_only (email, state) VALUES ('e@example.com', 'suspended');
  ERROR:  new row violates check option for view "active_only"

-- identical view + an INSTEAD OF INSERT trigger:
INSERT INTO active_only_trig (email, state) VALUES ('f@example.com', 'suspended');
  INSERT 0 1

-- did the violating row land in the base table?
     email     |   state
---------------+-----------
 f@example.com | suspended
```

Adding a trigger turned an enforced constraint into a no-op and wrote the row. So a mapping that has
both a source filter and `INSTEAD OF` triggers must re-implement the predicate as an explicit guard in
the trigger body, and a verifier must refuse the combination otherwise.

**2. `information_schema` cannot be trusted about updatability — but only for the shape that matters.**
`information_schema.views.is_updatable` is defined to pass `include_triggers = false`. Measured on a
two-table join view, which is *not* auto-updatable:

```
                       | excl_triggers | incl_triggers | information_schema
 no triggers           |             0 |             0 | NO
 + INSTEAD OF UPDATE   |             0 |             4 | NO      <-- and the UPDATE now succeeds
```

So introspect with `pg_relation_is_updatable(oid, true)` and `pg_column_is_updatable/3`.

> **Correction.** An earlier draft of this plan claimed the two answers disagree as soon as an
> `INSTEAD OF` trigger exists. They do not, for a *mixed single-table* view: that view is already
> auto-updatable on its own merits, so both report writable, trigger or no trigger — both returned the
> same bitmask `28`, and `information_schema` said `YES`, before and after. The disagreement is
> specific to views Postgres would otherwise refuse. Bitmask, measured: `4` = UPDATE, and a plain base
> table also reports `28`, so `28` is the fully-writable answer.

**3. Partial updates are undetectable.** `INSTEAD OF UPDATE` forbids a column list *and* forbids `WHEN`,
and `NEW` arrives fully populated from the view row. Nothing distinguishes "this column was not in the
`SET` clause" from "this column was explicitly set to its current value";
`OLD.x IS DISTINCT FROM NEW.x` conflates them. That changes observable behaviour — whether
`updated_at` bumps, whether a target-side trigger fires — so it must be an explicit DSL choice,
`on_update: :full_row | :changed_columns`, not a generator detail.

**4. `ON CONFLICT` is rejected once an `INSTEAD OF` trigger exists.** Measured: `ERROR: there is no
unique or exclusion constraint matching the ON CONFLICT specification`. Corroborates `VerifyNoUpserts`,
and is another reason to avoid the trigger rather than verify around it.

**5. Generated columns cannot be chained, and cannot be read from a `BEFORE` trigger.** So composed
mappings must be **inlined** by the compiler into one flat expression — possible only because the layer
is structured — and exactly one mechanism must be chosen per column, then verified.

**6. The `from_zone` design is not just deterministic, it is indexable — and the cast it refuses is
neither.** Measured:

```
 uuid_generate_v5(uuid, text)           IMMUTABLE   -> index created
 uuid_generate_v4(), gen_random_uuid()  VOLATILE
 (naive AT TIME ZONE 'UTC')             -> index created
 (aware AT TIME ZONE 'UTC')             -> index created
 (naive::timestamptz)
   ERROR:  functions in index expression must be marked IMMUTABLE
```

The reason is the function resolution: `timezone(text, timestamp without time zone)` is `IMMUTABLE`,
while the one-argument `timezone(timestamp without time zone)` that a bare `::timestamptz` resolves to
is `STABLE`. So `VerifyTimestampZones` is not only preventing 10.5 hours of drift; the form it demands
is the only one that can carry an index.

> **Correction.** An earlier draft listed `AT TIME ZONE` with a text zone among the
> `STABLE`-not-`IMMUTABLE` traps. That is wrong, and the correction matters because it means the
> `zone:` combinator can be pushed into an expression index or a generated column. The genuine traps
> measured here are the bare `::timestamptz` cast, `date(timestamptz)`, `to_char(timestamp*, text)`, and
> the zero-argument timezone forms — all `STABLE`.

And the expression index is genuinely used through the view, which is the whole point of emitting it:

```
EXPLAIN SELECT * FROM stamps_v WHERE id = uuid_generate_v5(ns, 'c1.stamps:4242');
 Index Scan using c1_v5 on stamps
   Index Cond: (uuid_generate_v5('6b1e…'::uuid, ('c1.stamps:'::text || (id)::text)) = '3d711ffa-…'::uuid)
```

That only holds while the index expression and the query expression are byte-identical.
`Sql.View.key_index_statement/3` already protects this by building both from one function, and warns
why. **One printer generalises that protection to every mapping** — which is §8.

Never resolve an `IMMUTABLE` complaint with `ALTER FUNCTION … IMMUTABLE`. A mismarked function produces
an index that disagrees with the heap, and the symptom is wrong rows with no error. Name the offending
function — `pg_proc.provolatile` is one query — and refuse.

**7. Prefer `security_invoker = true` on compatibility views, and never backfill *through* the view.**
A `security_barrier` view blocks qualifier pushdown, which is exactly what a batched keyset backfill
depends on.

---

## 8. One printer

Delete both `String.replace(to, "$NEW.", …)` sites and the `to:`/`into:` options. Add two modules:

- **`AshStrangler.Lens`** — `forward/1`, `backward/1`, and `classify/1` returning
  `{:identity | :transformation | :masked, invertible: :yes | :semi | :no}`.
- **`AshStrangler.Sql.Printer`** — one `Ash.Expr` → literal-inlined SQL renderer, used by the view, the
  triggers, the generated columns, the reverse view, the expression index, the reconciler's checksum
  expressions and the check task.

Today those six emit SQL by five different string paths. Fact 6 above is why that matters beyond
tidiness: two restatements of one expression can drift, and when the index expression drifts from the
query expression the planner stops using the index, silently.

### How to render it, and the one hard part

There is a shipped precedent inside `ash_postgres`. `AshPostgres.Merge` assembles a statement Ecto
cannot express by rendering each clause with `Ecto.Adapters.SQL.to_sql/4` and a `:counter` offset so the
`$n` placeholders line up across concatenated fragments, then slicing clauses back out. Its moduledoc
states the strategy: *"To avoid re-implementing SQL generation, each piece is still produced by
Ecto."* A `CREATE VIEW` needs the whole `SELECT`, so there is no slicing to do — strictly easier than
what already ships.

The hard part is **parameters**. `AshSql` parameterises every literal, and DDL cannot be parameterised.
The fix: **one `Ash.Filter.map/2` pass rewriting each literal leaf into
`%Ash.Query.Function.Fragment{arguments: [raw: literal_sql]}`** before compiling, so the rendered
statement has zero parameters. Hand-building `Fragment` structs is established in-tree
(`AshPostgres.Extensions.ImmutableRaiseError` does it), and it confines literal escaping to a single
auditable function.

Rejected: post-substituting `$n` in the rendered string, which re-owns SQL escaping at the text level
and gets `$10` versus `$1` wrong; and wrapping the DDL in a plpgsql `EXECUTE format()` block, which
relocates the same escaping problem into PL/pgSQL.

A started repo is required for `to_sql/4`, though no connection is checked out and no query runs.
Without one, `Ecto.Adapter.Queryable.plan_query/3` plus `Ecto.Adapters.Postgres.Connection.all/2` is the
documented path, and `AshPostgres.DataLayer` already reaches into that `Connection` module for
`to_constraints/2`.

**Worth saying plainly: `ash_postgres` has no expression-to-DDL path of its own.**
`AshPostgres.CheckConstraint` keeps `check:` as a string, and `calculations_to_sql` /
`identity_wheres_to_sql` are keyword lists of hand-written SQL. This would be the first. The last mile
is ours to build — and it is plausibly worth upstreaming.

---

## 9. What stops being restated

- **`unmapped [...], as: :default`** — implemented via `Ash.Type.dump_to_native/3`, replacing the
  `raise "not yet implemented"` that has stood in `Sql.View` since the option was documented.
- **`Reconciler.diff(resource, opts)`** derives `columns:` from the mapping, and the normaliser from the
  Ash type plus the `zone` combinator. The hand-passed form stays, because the moduledoc's defence of
  the emergency path — an operator reconciling a table the model does not describe yet — is right.
- **`Backfill.plan(resource)`** derives `relation:`, `key:` and `set:` from the `key` and `constant`
  entities, which are today retyped by hand as raw SQL. Take pgroll's batch statement as it stands —
  row-tuple keyset comparison on the composite key, `FOR NO KEY UPDATE`, last key returned as the
  cursor — and the `needs_backfill` interlock with it.
- **Named, reusable derivations.** The PRQL and Malloy *pattern*, not the dependency: a named
  intermediate becomes a calculation on the twin. This is why `expand_calculations?: true` matters —
  lineage resolves *through* the name to leaf columns, so sharing a derivation does not blind the
  diagram. Prefer Malloy's bare-name scoping to Cube's and LookML's `${}` interpolation: we have a real
  AST, and string substitution would discard the structure this redesign exists to gain.
- **A capability lattice.** Every semantic layer enforces a locality rule — a dimension may not contain
  a measure. The analogue here: classify each named mapping `pure` (usable in an expression index or a
  generated column), `row_local` (usable in a trigger), or `cross_table` (backfill and reconciler only),
  and refuse its use in a context it does not qualify for. This is what makes one `status` derivation
  safely shareable across the backfill, the trigger, the diagram and the check task, while catching at
  compile time the cases where it cannot be.
- **Shared sources.** `Spark.Dsl.Fragment` already exists for this. Three resources over one legacy
  table repeat the relation, the key and the namespace — `test/support/demo.ex` does it three times.
  Declare the source once in a fragment module and list it in `fragments: [...]`.
- **Phase declared once.** Resources over one table must change phase together, and nothing checks that
  they do. A migration group owns `phase`, the namespace and the source; resources inherit.
  `VerifyPhaseTransition` gains the cross-resource agreement check it cannot currently make.
- **Generic assertions.** Following dbt and SQLMesh: a closed set of named, parameterised assertions —
  `not_null`, `unique`, `accepted_values`, `relationships`, `row_count_matches` — plus one raw-SQL
  escape, and a generator that freezes expected outputs sampled from live legacy data.

One property worth claiming explicitly, because it is a genuine advantage and it is easy to lose.
Skeema's published argument against declarative data migration is that accreted incremental DML breaks
environment setup: old statements reference columns that no longer exist once the schema is flattened.
`AshStrangler` is immune, because the backfill is **derived from the current declaration** rather than
stored as a history of statements. Keeping the backfill derived is therefore not a convenience; it is
what keeps that property.

---

## 10. The diagram becomes a projection

`Diagram.Sql` is deleted. In its place, one lineage model — nodes `{side, relation, column}`, edges
carrying `{type, subtype, description, invertible}` — folded out of the combinator tree with
`Ash.Filter.list_refs/5`, and renderers behind it. That is Structurizr's separation of model, view
selection and exporters, and it makes Mermaid *an* exporter rather than the model.

Take OpenLineage's `columnLineage` facet vocabulary directly: `DIRECT` / `INDIRECT`, with subtypes
`IDENTITY | TRANSFORMATION | AGGREGATION` and `JOIN | GROUP_BY | FILTER | SORT | WINDOW | CONDITIONAL`,
plus `masking`. `IDENTITY | TRANSFORMATION | MASKED` *is* a three-way invertibility classification, so
the diagram and the writability decision compute from one source. Emitting the facet as JSON is then
nearly free, and it makes the model readable by existing lineage tooling — which is worth something for
a tool whose job is proving to somebody that nothing was lost.

The notation stops being a language and becomes a rendering of `Lens.classify/1`:

| | 0.1 | v2 |
|---|---|---|
| rectangle | a legacy column | unchanged — but a *typed* twin attribute, so the label can carry its type |
| rhombus, "source columns not resolved" | the heuristic gave up | **gone**; not expressible |
| hexagon | any `from:` string, truncated to 64 characters | a transform node labelled with the *combinator* |
| `<-->` | `writable?: true`, asserted | `IDENTITY`, or `TRANSFORMATION` with `invertible: :yes` |
| `<-.->` | — | `invertible: :semi` — invertible modulo a default or a fold |
| `-.->` with `because:` | `writable?: false` | `MASKED` — the explicit opt-out |
| `-.-` | — | opaque `fragment`; proven neither way |

Two constraints to record so they are not rediscovered. Mermaid's `erDiagram` cannot draw an edge to an
individual attribute, so column-level flow must be a `flowchart` with a `subgraph` per relation — which
is what `Diagram.Mapping` already does, and it is right. And D2, despite supporting
`table.column -> other.column`, routes column-level arrows only under its proprietary TALA engine, so it
is not an option for a shipped library.

`test/ash_strangler/diagram_test.exs` asserts the README's Mermaid blocks are byte-identical to
generator output. That test is the mechanism that keeps the README from drifting, so the README is
updated in the same change, and the test is the proof it was.

---

## 11. The v1 syntax is removed, not deprecated

This is a **clean break**. There is no desugaring path and no deprecation window. Every construct below
is deleted from the DSL, and a resource still using one fails to compile with an error naming its
replacement.

| Removed | Replacement |
|---|---|
| `map`'s positional column, `map :email, "email"` | `map :email, from: :email` |
| `from: "sql string"` | `from: :column`, `from: expr(...)`, or an explicit combinator |
| `to:` and `into:` | derived from the combinator; `inverse:` only where the grammar cannot decide |
| `cast:` | derived from the twin's column type against the target attribute's type |
| `from_zone:` | `zone:` |
| `writable?` as an author declaration | derived; `read_only?: true, because: "…"` is the opt-out |
| `constant`'s SQL string | `constant :attr, expr(...)` |
| the `index` entity | an `identity` on the twin |
| `join`'s `relation`/`on:`/`as:` strings | a relationship on the twin, read as `expr(address.city)` |
| `source "legacy.users"` | `source MyApp.Legacy.Users` — the twin module |

### Why a break, when deprecation was the earlier plan

An earlier draft of this document argued for retaining `from: "sql string"` as deprecated sugar
desugaring to `expr(fragment("sql string"))`, on the grounds that a string genuinely *is* an opaque node
and that adopting v2 would then *find* the §2 bug rather than requiring a rewrite before it could look.

That argument is wrong in a way worth recording, because it is attractive.

**The sugar is not sugar.** `from: "CASE state WHEN 'active' THEN 0 ELSE 1 END"` desugared to a
`fragment` classifies as **opaque**, and an opaque mapping is exactly the one the design cannot prove,
cannot invert, cannot tier to a weaker mechanism and cannot draw lineage for. So the desugaring does not
carry a mapping into v2; it carries it into v2's worst tier and stops. The `state_code` mapping in §2
would not be *found* by adopting v2 — it would be reclassified from "asserted invertible" to "opaque,
`because:` required", which is an improvement in honesty and no improvement at all in the data.

**Two grammars is the disease.** §1's whole complaint is that one transform is represented six times
with nothing relating the representations. Keeping the string form keeps `Sql.View.with_cast/2`, both
`String.replace(to, "$NEW.", …)` sites, `Diagram.Sql`'s regex and the reconciler's `normalize:` alive to
serve it — every one of the six representations survives, beside the new one, and the printer becomes
the *seventh*. A compatibility path here does not cost a deprecation warning; it costs the deletion the
redesign exists to perform.

**The package is 0.x with fifteen call sites, all inside its own repository.** There is no external
caller to protect. The cost of the break is a rewrite of `test/support/` and the README examples, which
had to be rewritten anyway — the fixtures *contain* the bug.

So: `from:` as a string is gone. A mapping that genuinely needs raw SQL says so, loudly, in the one slot
that means it:

```elixir
map :legacy_score, from: expr(fragment("legacy_score_udf(?)", raw_score)),
  read_only?: true,
  because: "Scoring lives in a PL/pgSQL function the finance team owns."
```

### The one rule that changes shape rather than being deleted

Requiring `to:`/`into:` on every computed writable mapping was never right, and the two tools closest to
this problem both do it conditionally: pgroll's validator requires both directions for `change_type`,
only `up` for `set_not_null`, neither for `set_default`, and `add_column` has no `down` field at all;
Reshape derives the obligation from the schema — *"the `down` setting must be provided when the removed
column is `NOT NULL` or doesn't have a default value"*. Direction requirements are **computed** from the
combinator, which is why the options carrying them by hand could be deleted rather than renamed.

---

## 12. Sequencing

Each step is independently shippable, and each deletes something.

| Step | Adds | Deletes |
|---|---|---|
| 1 | `mix ash_strangler.gen.twin`; `source <Twin>`; `from:` taking an atom or `expr(...)` | `from:`/`to:`/`into:`/`cast:`/`from_zone:` as strings; the positional column; `known_columns:`; the `index` entity; `join`'s SQL |
| 2 | `AshStrangler.Lens`; Tier 1 and Tier 2 combinators; `zone:` as an `Ash.CustomExpression` | `Sql.View.with_cast/2` and the four hard-coded `AT TIME ZONE` inversions |
| 3 | `decode`, `collapse`, and the §6 obligations | `VerifyWritableMappingsReversible`; `writable?` as an author declaration |
| 4 | mechanism tiering: generated columns and base-table `BEFORE` triggers | `Info.derive_writes/1`'s "any computed mapping forces triggers" |
| 5 | `AshStrangler.Sql.Printer` | both `String.replace(to, "$NEW.", …)` sites; `unmapped as: :default`'s `raise` |
| 6 | the lineage model, the Mermaid exporter, the OpenLineage exporter | `Diagram.Sql` entirely |
| 7 | derived reconciler, derived backfill, real assertions in `check` | `normalize:`'s raw-SQL contract |

Step 5 is the one with a spike in it, and it is §8's parameter inlining. Everything else follows from
mechanisms that already exist.

Because §11 is a clean break, "independently shippable" means shippable in sequence within one
unreleased version — not that a user can adopt step 3 and skip step 1. Step 1 deletes the old option
slots, so every later step is working against a DSL that has only one way to say things.

---

## 13. What is genuinely hard

- **Literal inlining in the printer.** The `AshPostgres.Merge` precedent covers rendering; it does not
  cover producing parameter-free SQL. Get the escaping wrong once and it is a SQL injection in DDL
  generated at compile time. It belongs in one function, with property tests, and with
  `AshSql.Expr.dynamic_expr/6` used as a differential oracle.
- **Hydration timing.** Expressions are stored unhydrated and hydrated later. A verifier has the module
  but no repo; migration generation has both. Anything needing types must run after hydration, and the
  boundary has to be explicit or it will be crossed by accident.
- **`Ash.Filter.map/2` does not descend into `Parent`, `Exists` or `Ref`** — each clause says so, and
  says the caller must handle the internals. `list_refs/5` does handle `Exists`. So a mapping containing
  `exists(...)` needs its own clause in the lineage walk, and forgetting it means silently missing
  edges — the exact failure the regex has now.
- **Guard overlap can be data-dependent.** Enumeration over the `is_null`/boolean abstraction decides
  completeness soundly, but two guards that overlap only for values the data never contains are a
  warning, not an error. Reporting them as errors would refuse correct mappings.
- **The twin can drift from the database.** It is generated by introspection, so it is a snapshot. A
  column added to the legacy table by the old application's next migration is invisible until the twin
  is regenerated. This needs a `check` that diffs the twin against `information_schema` and a CI hook,
  or the typed layer inherits the staleness problem it was built to remove.
- **`INSTEAD OF UPDATE` partial-update ambiguity** (§7 fact 3) has no clean answer, only a documented
  choice.
- **`collapse` timestamp columns are not injective.** `touch()` names the loss; it does not remove it.
  Round-tripping `:cancelled` cannot recover the original instant, and any code that assumed it could
  is wrong.

---

## 14. What was considered and rejected

| Option | Why not |
|---|---|
| **Relational lenses**, implemented (PODS 2006; Links) | Their combinators are `select`, `join` and `drop` — set-of-tuples algebra with **no** value-level transforms. There is no cast, no concat, no `CASE`. Every hard case here is value-level. Their `drop` side conditions require Lossless Join Decomposition, which is NP-hard, so Links ships sound-but-incomplete syntactic approximations. Borrow the law names and the default-value discipline; implement none of it. |
| **Substrait** | A cross-engine IR for exchanging relational plans between execution engines. This is one Postgres schema and view/trigger DDL. Wrong problem. |
| **PRQL or Malloy as a dependency** | Standalone compilers with their own toolchains. PRQL's Elixir binding is a Rustler NIF over `prqlc`, and its own documentation groups it with the nascent bindings. A Rust SQL compiler invoked during macro expansion is a large liability for syntax `Ash.Expr` already provides. Take the patterns — orthogonal invariant-carrying transforms, `let`-style naming — not the code. |
| **SMT-based inverse synthesis** | Returns `sat`/`unsat`, not "you have no clause for `:pending`". Calvanese et al. reject it for exactly this reason. The input space here is finite and small; enumerate it. |
| **`bff`-style bidirectionalization** (Voigtländer, POPL 2009) | Derives `put` from a *polymorphic* `get` by exploiting relational parametricity. Monomorphic scalar column transforms have no parametricity to exploit. |
| **Declaring legacy columns inline** instead of generating a twin | Self-contained, but it restates the legacy schema by hand — the thing this document is about — and joins would still need raw SQL `on:` predicates. |
| **Keeping SQL strings and improving the parser** | A better regex is still a guess, and the guess would still feed the ER diagram with `[]` on failure. Parsing SQL properly means shipping a SQL parser; the industrial tools that do (SQLGlot, SQLMesh) document that column lineage degrades to nothing on `SELECT *` and unknown schemas. Constructing the structure is strictly better than recovering it. |
| **Leaving `writable?` asserted, with the round-trip result as a warning** | It preserves the exact gap that let §2 ship. A warning in a build log is not a refusal. |

## Reading order, for anyone implementing this

1. PostgreSQL, [`CREATE VIEW`](https://www.postgresql.org/docs/current/sql-createview.html) — the
   column-level updatability rule in §7 is the highest-leverage paragraph in this whole design.
2. [BIRDS](https://dangtv.github.io/BIRDS/) — the closest existing system, and the opposite choice.
3. Sparcl (ICFP 2020), rule T-RCase — `collapse`, already published.
4. Calvanese et al., *Semantics and Analysis of DMN Decision Tables* (BPM 2016), §3.3 and §4 — the
   completeness and overlap algorithms, and the argument against a solver.
5. [pgroll](https://github.com/xataio/pgroll), `pkg/backfill/templates/` — the trigger and backfill
   templates, and the `needs_backfill` interlock.
6. `AshPostgres.Merge` — the `to_sql` assembly precedent, in a dependency already on disk.

---

## 15. What building it changed

Eight corrections, kept as a section rather than folded silently into the text above, because a design
document that quietly matches its implementation teaches nothing about which of its claims were load
bearing. Six of these were mistakes here; two were bugs the implementation surfaced.

### 1. The printer is written directly, not assembled through Ecto

[§8](#8-one-printer) named `Ecto.Adapters.SQL.to_sql/4` as the primary strategy, with the
`AshPostgres.Merge` precedent behind it, and a direct printer as the stated fallback. The fallback is
what shipped, and the reason is not the parameter problem the section anticipated. It is **reference
frames**.

One forward expression has to be rendered four ways: as legacy columns for the view, as
`alias.column` when a join makes a bare name ambiguous, as `NEW.<attribute>` inside a trigger, and as
bare attributes for the `:read_from_new` reverse view. Ecto's renderer knows exactly one frame —
`s0."deleted_at"` — and no option changes that. So the frame is a *parameter* of
`AshStrangler.Sql.Printer.to_sql/2`, and the four consumers differ by one function where 0.1 had four
string paths. That was not visible from the read side alone, which is why the design got it wrong.

Two lesser reasons were confirmed along the way: Ecto's `s0.`-prefixed aliasing makes generated view DDL
unreadable and makes it churn across `ash_postgres` versions, which would break byte-identical golden
tests for no gain; and `to_sql/4` needs a started repo, which a Spark verifier does not have.

`Printer.inline_literals/1` — the `Ash.Filter.map/2` pass the section describes — exists, and is used as
the **differential oracle** in the printer's tests rather than as the renderer.

### 2. Lineage walks the unhydrated tree, so `list_refs/5` is not used

[§4](#4-ashexpr-as-the-ir-over-a-generated-legacy-twin) proposed `Ash.Filter.list_refs/5` for lineage,
and [§13](#13-what-is-genuinely-hard) correctly warned that `Ash.Filter.map/2` does not descend into
`Parent`, `Exists` or `Ref`.

Neither is needed. Hydration is only required for *types*, and lineage needs names — so
`AshStrangler.Expr` walks the stored, unhydrated tree, and `AshStrangler.Lens.hydrate/2` is the single
place the hydration boundary is crossed. That removes the sequencing hazard the design flagged rather
than managing it.

`exists/2` still needs its own clause, and for a sharper reason than the section gives. It is not that a
walker might *miss* the columns inside it: it is that `expr(exists(payments, amount > 0))` gives
`amount` an **empty** `relationship_path`, because it is relative to `payments`. A uniform walk finds it
and attributes it to the wrong relation, which is worse than missing it. `refs/1` re-roots.

Four node kinds `expr/1` builds are not `%Ash.Query.Call{}`, and every one was found by rendering
something and watching it fail: `and`/`or` are `%BooleanExpression{}`, `not` is `%Not{}`, `exists` is
`%Exists{}`, and `cond` is desugared into nested `if` calls before it ever reaches storage.

### 3. `Ash.Type.Integer` has no `one_of`, and an integer code is the common `decode` target

[§5](#5-the-combinator-grammar) says a `decode`'s exhaustiveness is checked "against the attribute's
`one_of` constraint … read from the resource, not restated". `Ash.Type.Integer` accepts only `min` and
`max`, so a `decode` onto an integer code — the shape a legacy `state varchar` is usually mapped *to* —
had no readable value space at all, and `PutTotal` was undecidable for exactly the case it exists for.

`AshStrangler.Obligations` therefore enumerates a **bounded integer range** as a value space too, capped
at 256 values. Past that, `min`/`max` stop describing a value set and start describing a sanity bound:
`min: 0, max: 2_000_000_000` on a counter is not a claim that every value in it is a legal encoding.

### 4. The notation Mermaid does not have

[§10](#10-the-diagram-becomes-a-projection) specifies `<-.->` — a dotted bidirectional edge — for
`invertible: :semi`. Mermaid has no such edge, and `AshDiagram.Flowchart.Edge` accordingly does not offer
one. `--o` (a circle head) is used instead, and the edge label always names the combinator, so the caveat
is legible either way. Recorded rather than substituted quietly, because a reader comparing the document
to the output deserves to know why they differ.

### 5. Mechanism tiering: two tiers are classified and not emitted, and a join escalates all of them

[§7](#7-pick-the-weakest-mechanism-that-works) is right about PostgreSQL and overstates what a generator
should do about it. `:plain` and `:instead_of` are emitted; `:generated` and `:base_trigger` are
classified and fold up to `:instead_of`, because both need a shadow column and therefore
`ALTER TABLE` against a relation this package does not own. pgroll does exactly that and is right to — it
is also an interactive tool driven by a person, not a `mix` task that runs in CI.

So the correction to *authentication must cut over first* stands as a **classification** result: the
premise really is wrong, a `decode`d `state_code` does not require a trigger, and closing the gap
requires a shadow column that somebody has to decide to add. `AshStrangler.Mechanism.report/1` prints
the ideal tier beside the emitted one so that decision is informed rather than a surprise.

And the per-column rule has a boundary the section does not mention. Automatic updatability requires
exactly **one base relation**, so a join makes the whole view non-updatable regardless of how each
column classifies. Without an explicit escalation, a resource whose only writable mapping was a plain
rename alongside a read-only `expr(address.city)` resolved to `writes: :auto` and emitted no triggers at
all — on a view PostgreSQL will not accept a write to, where the only symptom is an error on the first
`UPDATE`. The column rule narrows *which* mappings force a trigger within one relation; it does not
survive a second one.

### 6. Two of the six representations were not the same shape

[§1](#1-the-declaration-is-typed-at-its-edges-and-untyped-at-its-centre) counts six representations of
one transform and implies collapsing them is uniform. Two resisted.

**A `concat` has to null-default its operands.** SQL's `||` propagates NULL, so `first_name || ' ' ||
last_name` is NULL for a row with no surname — the attribute reads as nothing at all, which is the
silent-blanking failure the package exists to refuse. So the forward direction coalesces, and that is
also why `concat` is `invertible: :semi` even when the separator condition holds: `split_part` cannot
tell a NULL operand from an empty one, so a row whose `last_name` was NULL round-trips to `''`.

**`touch()` carries two reference frames inside one expression.** Every other reference in a write
expression is a resource attribute, rendered `NEW.<attribute>`. The column inside a `touch()` is the
legacy column's *stored* value, which on the right-hand side of `UPDATE … SET` is the bare column name.
Rendered through the trigger frame like everything else it became `NEW.cancelled_at` — a column the view
does not have — and the generated plpgsql would not have compiled. The frame cannot be a parameter of the
whole render, so the node carries a column *name* rather than a reference.

### 7. The `collapse` reverse does not mirror the forward guards

Falls out of the grammar and is worth stating, because it is what makes the reverse total. Forward, a
clause is selected by an arbitrary predicate over legacy columns. Backward, it is selected by the
attribute's own value — a *literal* — so the whole reverse is one flat `CASE attr WHEN … END` rather than
a nest of predicates. `set:` names every column the table touches and the attribute's value picks exactly
one row of the table, which is the whole of the claim in
[§5](#5-the-combinator-grammar) that the backward direction is "total and canonical by construction".

### 8. Spark verifiers do not raise where a test expects them to

[§13](#13-what-is-genuinely-hard) discusses hydration timing and not this, and it costs a whole class of
vacuous test. Verifiers run *after* the module compiles, in `Module.ParallelChecker`, so
`assert_raise Spark.Error.DslError, fn -> defmodule Broken do … end end` catches nothing and passes.

`Code.compile_string/1` is worse, because it looks like the fix: the module really is checked, and the
`Spark.Error.DslError` is emitted as a compiler **warning** to standard error rather than raised into the
caller. Measured — a deliberately broken `decode` compiled cleanly, printed the error as a warning, and
the surrounding `assert_raise` failed with *"expected … to be refused, but it compiled"*.

`test/ash_strangler/obligations_test.exs` compiles the module and then runs the verifiers itself, over
`spark_dsl_config/0`. Anything that refuses a mapping needs a test written that way, or the suite
acquires green tests that assert nothing — which is precisely the failure that let the mapping in
[§2](#2-the-bug-this-design-exists-to-refuse) ship past nine of them.
