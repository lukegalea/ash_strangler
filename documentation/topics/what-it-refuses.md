<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# What it refuses to generate

Every check in this guide exists because the mistake it catches **does not fail on
its own**. The migration runs, the query succeeds, the row count looks right, and
the data is wrong.

That is the shape of the whole problem. A compatibility layer sits between two
applications, so when it is subtly wrong the symptom is not an exception — it is a
value that quietly differs from what either side believed. The checks below turn
those into compile errors, which is the only point at which they are cheap.

Each one names the failure it prevents, so the error message is worth reading
rather than working around. The messages quoted are the real ones, produced by
compiling the broken mapping and reading what came out.

## Two layers, and one rule about the boundary

There are **twelve verifiers** and, behind one of them, **ten proof obligations**.
The split is not arbitrary. A verifier answers a question about the *declaration* —
is this attribute accounted for, does this identity exist, is this reference a real
column. An obligation answers a question about the *values*: is there a legacy
value this projection cannot turn into a valid attribute value, is there an
attribute value with no legacy encoding, does reading a row and writing it back
unchanged change it.

Value questions are decided by **finite-domain enumeration**, and the reason is
diagnostics rather than implementation cost. Calvanese, Dumas, Laurson, Maggi,
Montali and Teinemaa put it directly, arguing against a solver for exactly this
job: it *"leads to a boolean output (is the set of rules satisfiable?), and cannot
natively highlight specific sets of rules that need to be added to a table
(missing rules), nor specific overlaps between pairs of rules"*. `unsat` is not a
next step. *"You have no clause for `:pending`"* is. And the input space is small —
guards range over booleans and `is_null` abstractions of a handful of columns, so
it is 2ⁿ with n around six. Enumerate it, and **report the counterexample rather
than the verdict.**

The boundary rule follows from that:

> **Proven, or measured. Never asserted.** Whatever can be decided from the
> declaration is refused at compile time. Whatever cannot — a value space with no
> declared bounds, a `fragment` the BEAM cannot evaluate, a default that may also
> be a legal stored value — is re-emitted as **the same obligation, as SQL**, and
> `mix ash_strangler.check` runs it against the real legacy rows.

That second half is what makes the first half honest, because it is what stops an
undecidable obligation quietly becoming a passing one. And it is why the rule
those obligations follow from can be stated at all:

> Round-tripping has to be checked over the **legacy** value space, because that
> is the only space containing rows the tool did not create.

---

# The verifiers

They run in the order below, and the order matters: `VerifyTwin` is first because
every verifier after it builds mapping lenses, and a lens over a stale twin fails
somewhere that names neither the column nor the fix.

## A column reference that does not resolve

**`VerifyTwin`**

Every column a mapping reads has to exist on the twin — and every step of a
relationship path has to be a relationship on it. There is nothing to guess:
`expr(first_name)` either resolves against a typed attribute or it does not.

```
The mapping for :nickname reads `:nick_name`, which does not resolve.

AshStrangler.Test.Legacy.Users has no attribute :nick_name. It declares: :created_at,
:crypted_password, :deleted_at, :email, :first_name, :id, :last_name, :login, :salt, :state

Either the reference is a typo, or the twin is stale -- it is a snapshot of
the legacy schema, so a column added since it was generated is invisible.
Regenerate it and re-run:

    mix ash_strangler.gen.twin AshStrangler.Test.Legacy.Users
    mix ash_strangler.check
```

Two things about that message are deliberate. It lists what the twin *does*
declare, because the overwhelmingly common cause is a near-miss on a name nobody
remembers exactly. And it names both possible causes, because they need different
fixes and the verifier genuinely cannot tell them apart.

**What this verifier cannot decide, and says so.** It proves the mapping agrees
with the twin. It cannot prove the twin agrees with the database — a twin is a
snapshot, and a column the legacy application's next migration added is invisible
to both. That half is `mix ash_strangler.check`, which diffs every twin against
`information_schema.columns`. Saying so plainly matters: a verifier that appeared
to check the legacy schema but only checked a snapshot of it would be trusted for
something it does not do.

If `source` is handed something that is not a usable twin at all, the refusal
names the generator:

```
MyApp.Legacy.Accounts is not usable as a strangler `source`.

`source` takes a **twin**: the legacy relation declared as an ordinary Ash
resource on `AshPostgres.DataLayer`, with a `table`. […]

Generate one from the live database rather than typing it:

    mix ash_strangler.gen.twin --relation legacy.users --module MyApp.Legacy.Accounts
```

Handing it a *string* — `source "legacy.users"` — never reaches the verifier at
all; the option's own type check refuses it with
`expected module in :twin option, got: "legacy.users"`.

---

## A column nobody mapped

**`VerifyCompleteMapping`**

The convenient behaviour would be to select `NULL` for any attribute the mapping
does not mention. That is also exactly how a strangler migration loses data
quietly: somebody adds an attribute to the resource, the view keeps compiling, and
the column reads `NULL` for every legacy row — in production, for months, until
somebody notices a report is wrong.

```
These attributes are neither mapped nor declared unmapped:

  :nickname

An unmentioned attribute would read NULL for every legacy row, which is a
silent data loss rather than a failure. Either map it:

    map :nickname, from: :legacy_column

or declare the omission and say why:

    unmapped [:nickname], as: :null,
      because: "..."
```

The reason is required rather than optional. It ends up in the generated
documentation and it is what a reviewer reads in eighteen months when deciding
whether the omission is still deliberate.

`unmapped ..., as: :default` projects the attribute's declared default instead of
`NULL`, and that option now does what it says — the printer's `literal/1` is what
turns an Ash default into a SQL literal. One default is refused rather than
rendered: a zero-arity function like `&DateTime.utc_now/0`. Evaluating it at
migration-generation time would freeze one instant into the view definition, so
every legacy row would read the moment the migration was written. That is a wrong
answer that looks like a right one, and nothing downstream ever notices, so the
error points at `constant :attr, expr(now())` instead.

Generating the view is *stricter still*: it requires every attribute including
private ones, because a `SELECT` list has no notion of privacy.

---

## Building the view on a resource Ash would try to create

**`VerifyNotMigrated`**

A strangler resource's `table` names a view, so `migrate? false` is required in
the first two phases.

```
A resource in phase :read_from_legacy must set `migrate? false`.

    postgres do
      table "users"
      schema "strangler"
      repo MyApp.Repo
      migrate? false
    end

Its `table` names a VIEW. Left at the default, `mix ash.codegen` emits a
`create table` for that name and the view DDL then fails to create a view
over it, so the migration cannot run.
```

The error explains the second half too, which is less obvious: `migrate? false`
*also* stops the resource producing a snapshot, and `custom_statements` are read
only from snapshots. There is no setting in which ordinary codegen can carry this,
which is why `mix ash_strangler.gen.migration` exists.

At `:read_from_new` the direction flips and so does this rule: the resource's
table is then a genuine Ash-owned table, and `migrate? true` is required.

---

## A declared transform that is not one

**`VerifyNotRedundant`**

This is pgroll's `ColumnMigrationRedundantError`, and it is the one check aimed at
restatement rather than at data loss.

A redundant transform is not harmless. It is a claim that something happens,
written where a reader will believe it, and it **costs a real mechanism**: a
`decode` classifies as `:base_trigger` rather than `:plain`, which is the
difference between a resource that keeps upserts and one that does not. So an
identity `decode` buys a trigger and changes nothing.

Four shapes are caught:

| Shape | Why it is the identity |
|---|---|
| `decode` whose value table maps every key to itself | the table *is* `fn x -> x end` |
| `affine` with `multiply: 1, add: 0` | `1 * x + 0` |
| `concat` over a single column | there is nothing to join it to |
| `map ... zone:` on a column that is already `timestamptz` | see below — this one is not merely redundant |

```
The mapping for :state declares a transform that is not one: every entry in its
`values:` table maps a value to itself, so the decode is the identity function
written out longhand.

It is not free: `AshStrangler.Mechanism` classifies a `decode` as
`:base_trigger` rather than `:plain`, which is the difference between a
resource that keeps upserts and one that does not. Use a plain rename:

    map :attribute, from: :legacy_column
```

The last row is the valuable one, and it is *wrong* rather than redundant:

```
The mapping for :seen_at declares a transform that is not one: `zone: "UTC"` is
applied to :seen_at, which the twin already declares as an aware timestamp
(Ash.Type.UtcDatetimeUsec).

This is worse than redundant. `AT TIME ZONE` on a `timestamptz` yields a
`timestamp WITHOUT time zone` — it converts an aware value back to a naive
one, which is the opposite of what `zone:` is for. The mapping would strip
the zone it was trying to establish.
```

The `concat` case earns its refusal for a second reason, and the message says it:
a `concat`'s reverse is `split_part`, which is only correct while the separator is
provably absent from every operand — a condition only real data can settle. Paying
that for a single column buys nothing.

---

## A timestamp cast the session can move

A naive legacy timestamp feeding an aware attribute is refused unless the mapping
says which zone the column is recorded in.

```elixir
map :archived_at, from: :deleted_at            # refused
map :archived_at, from: :deleted_at, zone: "UTC"   # accepted
```

The twin says `deleted_at` is `:naive_datetime` and the attribute says
`:utc_datetime_usec`, so a cast is *derived* from those two type facts — and the
derived cast is `(deleted_at)::timestamptz`, which reads the stored value as
**wall-clock time in the session's `TimeZone`**. That is a per-connection setting.
Measured against PostgreSQL 17.10, one stored value:

| session `TimeZone` | resulting instant |
|---|---|
| `UTC` | `2024-06-15 12:00:00+00` |
| `America/New_York` | `2024-06-15 12:00:00-04` |
| `Australia/Lord_Howe` | `2024-06-15 12:00:00+10:30` |

Fourteen and a half hours of spread, with no error anywhere: a background job, a
`psql` session, a replica with a different default, or a pooled connection that
inherited a `SET TimeZone` each read something different. The reverse direction
writes `(NEW.archived_at)::timestamp`, session-dependent in the mirrored way.

`zone:` is the deterministic form. It renders `deleted_at AT TIME ZONE 'UTC'`,
where the zone lives in the view rather than in session state, and it is also the
only form that can carry an index — `timezone(text, timestamp without time zone)`
is `IMMUTABLE`, while the one-argument form a bare cast resolves to is `STABLE`,
and PostgreSQL refuses a `STABLE` function in an index expression.

**Why not default to UTC?** Because defaulting would be right for most legacy
systems and silently wrong for the rest, moving every timestamp by a fixed
offset — the worst available outcome. Which zone a naive column is recorded in is
a fact about the *old application*, not about its schema, so there is nothing in
the database to read it from and it is not guessed.

If the column is already `timestamptz`, omit `zone:` entirely; `AT TIME ZONE` on
an already-aware value converts it *back* to naive, which `VerifyNotRedundant`
refuses.

> #### Why a derived layer still needs this {: .info}
>
> Deriving the cast from the two types is what removed `cast:` from the DSL, and it
> is the right move. But a derivation does not inherit the **judgement** a
> hand-typed declaration carried: the type system can see that a cast is *needed*
> and cannot see that one particular cast is *non-deterministic*. Every derivation
> in this design needs the refusals its declared form would have carried, and this
> is the one that shows why.

## A mapping whose prose disagrees with its reverse

**`VerifyDerivedWritability`**

Writability is **derived**, not declared. A mapping is writable when the reverse
can be constructed from the combinator; `read_only?: true` is an explicit opt-out
that requires a `because:`; and `because:` on a mapping that *does* have a reverse
is refused. Three rules, each covering a way the author's prose can disagree with
the fact.

**A mapping with no constructible reverse must say so.** A free-form `expr(...)`
that is not a simple column reference has no reverse, because the grammar does not
attempt to invert an arbitrary expression — every result in reversible computing
says invertibility has to be guaranteed by construction rather than recovered by
analysis (Janus; Theseus; Sparcl, Matsuda & Wang ICFP 2020; surveyed in Glück &
Yokoyama, *TCS* 2022). So the alternative offered is a **combinator**, not a
hand-written inverse:

```
Mapping for :full_name: it has no constructible reverse, and does not say so.

`from:` is an expression that is not a simple column reference,
and the grammar does not attempt to invert an arbitrary expression -- every
result in reversible computing says invertibility has to be guaranteed by
construction rather than recovered by analysis, which is why there is no `to:`
slot to fill in.

Two ways forward.

If the transform *is* invertible, say which combinator it is, and both
directions come from that one declaration:

    decode :full_name, from: :legacy_column, values: %{"a" => 1, "b" => 2}
    negate :full_name, from: :legacy_column
    affine :full_name, from: :legacy_column, multiply: 100
    coalesce :full_name, from: :legacy_column, default: 0
    concat :full_name, from: [:first_name, :last_name], separator: " "
    collapse :full_name do ... end

If it genuinely is not, declare that, with a reason the person attempting the
write will read:

    read_only?: true,
    because: "..."

Writability is derived here, not declared. `AshStrangler.Lens` classifies this
mapping as `expression` — masked, invertible: no.
```

That closing line is the anti-drift mechanism in miniature: the claim and the
derived fact, printed next to each other.

**`read_only? true` requires `because:`.** That text is not documentation — it is
quoted verbatim in the runtime error the trigger raises when something tries to
write the attribute, so it has to exist before the write path does. "Not writable"
tells the person nothing; *"Password changes must not be written back into a SHA1
scheme — cut over first"* tells them what to do.

**`because:` without `read_only? true` is refused.**

```
Mapping for :login: it gives a `because:` but is not `read_only?: true`.

`because:` explains an absent write direction. This mapping has one --
"Map" carries its own reverse -- so the prose is asserting a limitation the
mapping does not have.
```

### What this deliberately does *not* refuse

`read_only? true` on a mapping whose reverse the grammar could have built. That is
a legitimate policy decision rather than a factual claim — "do not write password
hashes back into the old scheme" is about the migration, not about invertibility —
so refusing it would refuse correct mappings.

Instead the fact is computed and **reported next to the prose**:
`mix ash_strangler.check` prints these mappings with the reverse that was
available, and the lineage model draws them as `MASKED` rather than as opaque.
Putting the claim and the derived fact side by side where they can be compared is
stronger than a refusal that would have to guess at intent.

---

## A gathered column that claims to be writable

**`VerifyJoinedWritesRefused`**

Writes go back through `__legacy_id`, the primary relation's key. It identifies
exactly which row of the primary table a view row came from.

It does not identify anything in a joined relation. The row that should be updated
depends on the relationship, and on whether a matching row exists at all — the
join is a `LEFT JOIN`, so quite possibly it does not. A "write" would have to
choose between updating nothing, inserting a row into a table the mapping never
said it owned, and failing. No choice is right for every schema, and making one
silently is how a tool like this corrupts data.

For a plain `map ... from: expr(address.city)` the previous verifier gets there
first — such an expression has no constructible reverse either way. This one
catches the case that *does* have a reverse and still reads across a relation: a
`collapse` whose guard reads through one.

```
These mappings read through a relationship on the twin but still have a write
direction:

  :status — reads address.void

Writes reach the primary relation through `__legacy_id`, which identifies
exactly one row there. Nothing identifies the corresponding row in a joined
relation -- and the join is a LEFT JOIN, so there may not be one -- so there is
no write to generate that would be right for every schema.

Declare the intent:

    map :status, from: expr(address.void),
      read_only?: true,
      because: "Read through a relationship; write it through its own resource."

If you need to write these columns, give the joined relation its own resource
and its own view. That is usually what the model wanted anyway.
```

The rule is unchanged from the string-based DSL. What changed is that it is
detected **structurally**. The old check looked for a join's alias as a substring
of the mapping's SQL — `String.contains?(expression, "addr.")` — a heuristic with
two failure modes: a column named `addr_line1` in a schema with a join aliased
`addr` is a false positive, and an alias reached through a subquery is a false
negative. Now the reference carries its relationship path as data. There is
nothing to match.

The advice in that message is the real answer. If `legacy.addresses` has its own
rows and its own lifecycle, it is an `Address` resource with an `Address` view —
not a few columns bolted onto `Customer`. Read them together through a
relationship; write them separately.

---

## A mapping that fails a proof obligation

**`VerifyObligations`**

The thin layer that decides which of the obligations stop a compile. **Errors
stop it; warnings do not, and are not emitted here at all.** A warning in this
design means one of two things — the guard lattice is a propositional abstraction
that can suspect an overlap no real value produces, or the obligation was
undecidable and has been re-emitted as SQL. Neither is something to fail a build
on, and both are reported by `mix ash_strangler.check`, where the database is
available to settle them.

Which is also why they are not `IO.warn`ed. A warning in a build log is not a
refusal, and treating one as though it were is precisely the gap that lets a wrong
inverse ship.

The obligations are named after the literature so an error message is searchable.

| Obligation | Source | The failure it refuses |
|---|---|---|
| `GetTotal` | PODS 2006 | a legacy value the forward direction cannot turn into a valid attribute value |
| `PutTotal` | PODS 2006 | an attribute value with **no** legal legacy encoding |
| `PutGet` | lens laws | forward ∘ backward ≠ identity |
| `GetPut` | lens laws | backward ∘ forward ≠ identity; genuine loss must be declared |
| completeness | DMN / Calvanese et al. BPM 2016 | an uncovered cell in the guard lattice — a *missing rule* |
| masked rule | DMN hit policy `FIRST` | a clause no input can ever reach |
| non-overlap | DMN hit policy `UNIQUE` | two clauses that can both match |
| surjectivity | — | a declared state no clause can produce, so reads never show it |
| linearity | the relevance condition from reversible languages | two mappings writing one legacy column |
| type agreement | `Ash.Expr.determine_types/4` | the projection's type is not the target attribute's |

Redundancy is the tenth in the literature's sense and lives in
`VerifyNotRedundant` above instead, because it is decidable from the declaration
alone with no enumeration.

### `GetTotal` — a legacy value with nowhere to go

The obligation that catches the mapping this whole design exists to refuse. A
`decode` states a bijection between a legacy value set and an attribute value set;
if the twin says the column ranges over five values and the table lists two, three
legacy states have no attribute value to project to.

```
GetTotal violation on :state_code.

`decode :state_code, from: :state` is not total.

The twin says :state ranges over [:passive, :pending, :active, :suspended, :deleted], and the
`values:` table has no entry for:

  :passive
  :pending
  :deleted

A legacy row holding one of those has no attribute value to project to. The
tempting fix -- a catch-all `ELSE` -- is exactly the bug this obligation
exists to refuse: it produces a value that is *wrong* rather than absent,
and then writes that wrong value back. Reading a :passive
row and saving it unchanged would rewrite it.

Add an entry for each.
```

The paragraph about the `ELSE` is the whole point, and it is worth reading as
history rather than advice. The mapping this replaced was
`CASE state WHEN 'active' THEN 0 ELSE 1 END`, with a separately hand-written
inverse sending `1` back to `'suspended'`. Forward it was total, so nothing looked
wrong; three of five lifecycle states were silently rewritten by an `UPDATE` that
assigned only an email. A `decode` has no `ELSE`, so the same mistake is a missing
table entry — and a missing table entry is decidable, because the twin declares
the domain.

When the twin does *not* declare a domain — the column is a plain `:string` with
no `CHECK` constraint behind it — this degrades to a warning carrying SQL, and
`mix ash_strangler.check` answers it against the rows that actually exist:

```sql
SELECT DISTINCT state AS value_with_no_decode_entry
FROM legacy.users
WHERE state IS NOT NULL
  AND state NOT IN ('active', 'suspended')
```

That is the stronger answer, not the weaker one: it reports what fifteen years put
in the column rather than what the schema permits. It just arrives later.

### `PutTotal` — an attribute value with no encoding

The other direction, and what catches a value the write path cannot store.

```
PutTotal violation on :state_code.

`decode :state_code` declares a bijection onto an unbounded value space.

:state_code has no `one_of` constraint, so nothing stops a value the
`values:` table cannot encode. The write path would then either fail at 3am or,
worse, fall through to whatever the last branch happens to say -- which is how
`state_code: 7` came to write `'suspended'` and read back as `1`.

Constrain the attribute. The table already knows what the values are:

    attribute :state_code, :integer do
      constraints one_of: [0, 1, 2, 3, 4]
    end

An `AshStateMachine` state list counts too -- it is read from the resource, not
restated here.
```

An unbounded target is itself the finding, and an **error** rather than a warning,
because a `decode` is a declared bijection and a bijection onto an unbounded set is
not one. Two forms of bound are enumerable: `one_of`, which is where an
`AshStateMachine` state list lands without this code knowing that extension
exists; and `min`/`max` on an integer, because `Ash.Type.Integer` has no `one_of`
at all and an integer code is the common target for a `decode`. A range wider than
256 is not enumerated: past that, `min`/`max` has stopped describing a value *set*
and started describing a sanity bound, and treating `min: 0, max: 2_000_000_000`
as a claim that every value in it is a legal encoding would produce an unreadable
finding.

### `PutGet` — reading a row and writing it back changes it

A `decode` built from a map is a bijection exactly when the map is injective. If
two legacy values share an attribute value, the write direction has to pick one,
and round-tripping the other loses it. The finding is the enumeration, not the
verdict:

```
PutGet violation on :state_code.

`decode :state_code` is not injective, so it is not a bijection.

 legacy_value | projects_to | writes_back_as | verdict
--------------+-------------+----------------+------------------
 :pending     | 1           | :deleted       | PUTGET VIOLATION
 :suspended   | 1           | :deleted       | PUTGET VIOLATION
 :passive     | 1           | :deleted       | PUTGET VIOLATION
 :deleted     | 1           | :deleted       | ok

Reading one of the colliding legacy values and writing the row back unchanged
rewrites it to the other. That is a `PutGet` violation: forward ∘ backward is
not the identity.

If the collapse is deliberate -- several legacy values genuinely meaning one
modern state -- then the mapping is not a bijection and should say so:

    map :state_code, from: expr(...), read_only?: true, because: "..."
```

Printing the table rather than the boolean is deliberate, and BIRDS (Tran, Kato &
Hu, *PVLDB* 13(12), 2020) generates concrete counterexamples for the same reason.
"Not a bijection" is a verdict; a row saying `:passive` becomes `:deleted` is a
decision.

### completeness — a missing rule

A `collapse` is a decision table, so DMN's vocabulary applies: *completeness* is
whether every combination of guard truth values is covered by some clause. Each
distinct atomic proposition across the guards becomes a variable, and the lattice
is 2ⁿ assignments over them. If any assignment matches no clause, a legacy row in
that state projects to `NULL`.

```
completeness violation on :status.

`collapse :status` has a missing rule.

No clause matches when:

      (deleted_at IS NULL)
  NOT (state = 'suspended')

A legacy row in that state projects to NULL, and :status
would read as nothing at all. Add a clause, or add the fallback -- which
is what `:otherwise` is for and is almost always the right answer, because
the old application was never stopped from writing whatever it liked:

    state :some_value, when: :otherwise, set: [...]
```

The uncovered assignment is printed as the guards it falsifies, in SQL, by the
same printer that renders the view — so what you read is what the projection will
actually evaluate.

The abstraction is **sound for completeness**: if every assignment is covered, no
row can miss. That direction only needs the abstraction to admit *more* than
reality, which it does.

When a guard falls outside the abstraction — a `fragment`, a subquery, anything
beyond a column against a literal — there is no finite lattice, and the obligation
becomes a warning carrying SQL:

```sql
-- rows `collapse :status` has no clause for
SELECT count(*) AS rows_matching_no_clause
FROM legacy.users
WHERE NOT ((deleted_at IS NOT NULL)
   OR (state = 'suspended'))
```

That assertion is emitted for the *decidable* case too — an uncovered assignment
is an error and carries the SQL that counts how many rows are actually in it, so
the answer to "how bad is it" does not need a second query written by hand.

### masked rule, and non-overlap

The same lattice answers two more questions, and the hit policy decides which of
them is an error.

A clause **no assignment can reach** is a *masked rule* — DMN's term — and it is
an error under either policy, because a clause that can never fire is dead code a
reader will believe:

```
masked_rule violation on :status.

`collapse :status` has clauses that can never be reached:

  :also_gone

Every input matching one of them matches an earlier clause first, so
:also_gone is a state reads will never show. Either reorder the
clauses, or narrow the earlier guard.
```

Two clauses that *can both* fire is an **overlap**. Under `hit_policy: :first` it
is legal by construction — that is what "first match wins" means — and is not
reported at all. Under `hit_policy: :unique` it is reported as a **warning**, and
the reason is the one asymmetry in the abstraction: it is coarse in the direction
that matters here. It admits combinations no actual value can produce, such as
`col == 'a'` and `col == 'b'` both true, so an overlap it finds may hold for no row
that will ever exist. Reporting that as an error would refuse correct mappings, so
`mix ash_strangler.check` settles it against the data instead.

### surjectivity

A **warning**: the attribute declares a value no clause yields, so a read will
never show one. That is usually a clause somebody meant to write. Occasionally it
is a state only the new application creates, in which case it is correct and the
finding is noise — which is why it is not an error.

### linearity

The relevance condition from reversible languages: a value is produced once and
consumed once.

```
linearity violation on :login.

Legacy column :login is written by more than one mapping:

  :login
  :handle

The generated trigger's `SET` clause would carry two assignments for one
column. One of them silently wins, and which one depends on declaration
order -- so a reordering of the DSL changes what is stored, with nothing
reporting it.
```

The failure mode is the reason this is an error rather than a preference:
reordering the DSL block would change what is stored, and nothing anywhere would
report the change.

### type agreement

A `decode` whose table produces values that will not cast to the attribute's own
type is refused, with the offending values listed. This is the one obligation that
needs types, and therefore the one place the hydration boundary is crossed —
expressions are otherwise stored and walked unhydrated, because nothing else needs
them.

### `GetPut` — the two side conditions the schema cannot decide

Two combinators are *partial* isomorphisms by construction, and both know it. They
produce no compile error; they produce a warning and a measurement.

**`coalesce`** reverses with `NULLIF`, which is an isomorphism only if the default
is not *otherwise* a legal value in the column. If it is, a real stored value maps
back to `NULL` and a row round-trips from the default to nothing. This is the
relational-lens side condition `{A = a} ∈ P[A]` (Bohannon, Pierce & Vaughan, PODS
2006), and it is a fact about the data rather than the schema. For
`coalesce :attempts, from: :login_attempts, default: 0`:

```sql
SELECT count(*) AS rows_where_the_default_is_a_real_value
FROM legacy.users
WHERE login_attempts = 0
```

**`concat`** reverses with `split_part`, which is correct only while the separator
is absent from every operand — the degraded form of Boomerang's regex-ambiguity
condition (Bohannon, Foster, Pierce, Pilkiewicz & Schmitt, POPL 2008):

```sql
SELECT count(*) AS rows_whose_operands_contain_the_separator
FROM demo_legacy.accounts
WHERE position(' ' in coalesce(first_name, '')) > 0
   OR position(' ' in coalesce(last_name, '')) > 0
```

`concat` carries a second, unconditional loss, and it is why the combinator is
*semi*-invertible even when that count is zero. Each operand is null-defaulted on
the way out, because SQL's `||` propagates NULL and a single absent operand would
otherwise blank the whole value. `split_part` cannot tell a NULL operand from an
empty one on the way back, so a row whose `last_name` was NULL round-trips to
`''`.

If the count is not zero, the honest mapping is read-only. That is what
`full_name` is in this package's own fixtures: `'de la Cruz'` splits wrong and no
separator fixes it.

---

## Upserts on a trigger-backed mapping

**`VerifyNoUpserts`**

Attaching an `INSTEAD OF` trigger to a view removes upsert support, and does so
quietly. `ON CONFLICT DO UPDATE` starts raising *"there is no unique or exclusion
constraint matching the ON CONFLICT specification"* — measured. Worse,
`ON CONFLICT DO NOTHING` is **accepted and then inert**, and PostgreSQL does not
warn about it, so it surfaces as rows that quietly fail to appear.

So an `INSTEAD OF` trigger is a **trade, not an addition**, and this is where the
cost becomes visible:

```
This resource writes through `INSTEAD OF` triggers, but these actions are upserts:

  :upsert

`INSERT … ON CONFLICT` does not work against a view with an INSTEAD OF
trigger. `DO NOTHING` is accepted and silently does nothing; `DO UPDATE`
errors. Postgres does not warn about the first, so this would surface as
rows that quietly fail to appear.

  These are generated by ash_authentication and CANNOT be made non-upsert —
  the strategy's own transformer requires `upsert? true`:

    :upsert — the user_identity resource

  Removing the upsert is not available to you. Option 1 or 2 below is.

Options:

  1. Look at WHICH mapping forced the triggers, and see whether it can be
     expressed as a combinator that needs a weaker mechanism.
     `mix ash_strangler.check` prints the classification per attribute.
     `AshStrangler.Mechanism` only reaches `:instead_of` for a mapping that
     writes across relations or writes more than one legacy column — a
     `decode`d status column, which 0.1 would have charged triggers for, does
     not.

  2. `writes: :auto` — rely on view auto-updatability, which keeps upserts,
     correct RETURNING and WITH CHECK OPTION. An override, so the mapping
     still has to be one Postgres considers auto-updatable.

  3. Do not strangle this resource. Cut it over directly instead.
```

Option 1 is the one worth trying first, and reading the mechanism report is what
makes it actionable. Two caveats on the message's own wording, because they
decide whether option 1 will work:

- A **read-only** computed column costs nothing. A view of plain references plus
  read-only computed columns stays auto-updatable, keeps upserts, and is the
  common shape.
- A **writable** row-local computed column — a derived cast, a `zone:`, a
  `decode` — *classifies* as `:base_trigger` and is *emitted* as `:instead_of`,
  because emitting the cheaper mechanism would mean `ALTER TABLE` against the
  legacy table. So it does force triggers today, and the report says so in its
  second column.

The answer to "which mapping is costing me upserts" is therefore often a single
computed column that could be read-only — and where it is not, the report names
the shadow column that would close the gap rather than leaving the cost assumed.

### This collides with `ash_authentication`

Verified against 4.14.1:

- The **`password`** strategy does not upsert. Password-only authentication is
  migratable on the trigger path — the common case for a legacy monolith.
- The **`oauth2`** and **`oidc`** strategies **cannot be defined without an
  upsert**: their transformer validates `upsert? true` and a non-nil
  `upsert_identity`. No configuration avoids it.
- **`UserIdentity`** upserts unconditionally.

The verifier names the strategy rather than just the action, because "action
`:register_with_oauth2` requires upserts" is true and useless: the author never
wrote `upsert? true` and cannot remove it.

---

## Cutting over when it would lose columns

**`VerifyReverseMappable`**

At `:read_from_new` the legacy name becomes a view over the new table, so the old
application's `SELECT * FROM users` keeps working. That view has to produce every
column the old application reads — and it produces them by running each mapping
**backwards**.

A mapping classified `invertible: :no` has no backward direction; that is why it
carries a `because:` in the first place. **A mapping classified `invertible: :semi`
is refused here too**, and that is a tightening. A `coalesce`, a `concat` or a
`collapse` carrying `touch()` reverses only *modulo* something — a default that may
also be a legal value, a separator that may occur inside an operand, an instant
that cannot be recovered. Modulo-something is fine while the legacy row still
exists to be compared against, which is what dual-write is. It is not fine for the
phase in which the legacy table stops existing.

```
Phase :read_from_new makes the legacy name a view over the new table, so
every legacy column has to be reconstructible. These mappings declared
that they cannot be:

  :attempts -- coalesce, invertible: semi -- reverses only modulo a declared default, separator or `touch()`

The legacy columns behind them would read NULL for the old application,
starting the moment the cutover ran -- which is the point of no return.

Either carry those legacy columns across unchanged as well, or confirm
nothing still reads them and map them explicitly.
```

`:read_from_new` is also refused outright while the source still reads through a
relationship: reversing a gather means scattering one table back across several,
and nothing in the mapping says which joined relation each column belongs to on
the way back, or what to do when a row exists on one side and not the other.

The fix is never to delete the check. The mapping is telling you the truth: that
data was consumed one-way and the old application still wants it. Carry the
original columns across unchanged as well (map them, even if nothing modern reads
them), confirm nothing still reads them and map them explicitly, or stop the old
application first.

---

## An identity the database does not enforce

**`VerifyIdentitiesBacked`**

An `identity` on a view is enforced by nothing. Ash will happily use it to plan
upserts and to report *"has already been taken"* — while PostgreSQL accepts
duplicates, because a view has no unique index. Silently unenforced uniqueness on
a user table is a security defect, not an inconvenience.

Uniqueness is not restated in the mapping. It is an `identity` **on the twin**,
which is vocabulary Ash already has, and this verifier maps the resource's
identity keys through the mapping to legacy columns and compares:

```
Identity :unique_email is not backed by a uniqueness constraint the twin declares.

It maps to legacy columns ["email"], and no `identity` on
AshStrangler.Test.Legacy.Users covers those columns.

Ash will use this identity to plan upserts and to report "has already been
taken". If Postgres does not enforce it, duplicates are accepted with no
error raised — which is worse than having no identity at all.

If the constraint does exist on the legacy table, the twin is stale.
Regenerate it rather than typing the identity in by hand — the generator reads
`pg_index`, which is the only thing that actually knows:

    mix ash_strangler.gen.twin AshStrangler.Test.Legacy.Users

If it does not exist, either add it to the legacy table or remove the identity
from this resource. Do not leave it unbacked.
```

Only mappings that resolve to one real column can contribute a key: an identity
can only be enforced by the database if every key is a real column, and a computed
mapping cannot carry a unique constraint.

The chain from *"Ash believes this is unique"* to *"PostgreSQL enforces it"* takes
two links, and each is checked by whatever can actually check it. This verifier
compares the resource against the twin. `mix ash_strangler.check` compares the
*twin* against `pg_index` — and a **partial** unique index does not count there,
because it makes a column unique among the rows matching its predicate, which is
not what an identity claims.

> **A related trap worth knowing:** constraint violations through a view report the
> **base table's** index name, never the view's. Ash derives the name it expects
> from the resource's configured table, so the two do not match and a raw
> `Postgrex.Error` escapes instead of a friendly `InvalidAttribute`. The twin's
> identity is what lets `AshStrangler` wire up `identity_index_names` for you.

---

## A phase the mapping is not ready for

**`VerifyPhaseTransition`**

The phases are ordered, and each requires more of the mapping than the last:

| Phase | Requires |
|---|---|
| `:read_from_legacy` | a source and a key |
| `:dual_write` | every read-only mapping carrying a stated reason |
| `:read_from_new` | as above, and every mapping fully reversible |
| `:decommissioned` | nothing — the mapping is vestigial and should be deleted |

Every phase needs a `key`, because the whole design rests on the modern id being
*derived* from the legacy one rather than looked up:

```
The source declares no `key`.

Every strangler mapping needs a deterministic derivation from the legacy
primary key, so that SQL and Elixir agree on a row's modern id without a
lookup table:

    key :id, from: :id, strategy: {:uuid_v5, namespace: "..."}
```

Entering a write phase tightens one rule: every `read_only?` mapping must carry a
non-empty `because:`, because in a write phase an unwritable attribute is a value
that will silently not propagate, and that text is what the generated trigger
raises when something attempts the write.

**What this cannot check** is the *transition*, only the current state. A compile
step sees one version of the code and has no memory of the last one. Whether
`:read_from_new` is safe depends on whether the backfill finished and the
reconciler is clean, which are runtime facts. Saying so plainly matters: a
verifier that appeared to validate phase transitions but only validated syntax
would be trusted for something it does not do.

---

# One more refusal, at generation time rather than verification time

The printer's node set is **closed**. Only the nodes the combinator grammar
produces render; anything else is refused by name, listing what is renderable:

```
:string_split/2 is not in the renderable node set.

AshStrangler.Sql.Printer renders only the nodes the combinator grammar produces,
because a printer that guessed at an unrecognised node would emit SQL nobody
wrote. Renderable: :!=, :*, :+, :-, :/, :<, :<=, :<>, :==, :>, :>=, :abs, :and,
:at_zone, :ceil, :cond, :floor, :fragment, :greatest, :if, :in, :is_nil, :least,
:not, :now, :or, :round, :string_downcase, :string_length, :string_trim,
:string_upcase, :today, :type, :||.

To use something outside that set, say so:

    from: expr(fragment("string_split(?)", some_column))
```

Two of those refusals are worth meeting before you hit them.

**`exists(...)` does not render.** A subquery is not part of the invertible
grammar: nothing can write a value back through it, and its fan-out depends on the
data rather than on the declaration. Lineage *does* see the columns inside it —
they are re-rooted onto the relation they belong to — so it is not silently dropped
from the diagram, which is the failure a regex over a SQL string had.

**`coalesce/2` does not exist in Ash, and the printer says so rather than
rendering it.** Ash spells null-defaulting `||`, and concatenation `<>` — both
inverted relative to SQL, which is why they are the two most specific clauses in
the printer:

```
Ash has no `coalesce/2`.

`expr(coalesce(a, b))` parses — it becomes a call to a function that does not
exist, and fails later — so it is refused here by name rather than rendered.
Ash spells null-defaulting `||`:

    expr(first_name || "")

Note that the two symbols are inverted relative to SQL: Ash's `||` is SQL's
`coalesce`, and Ash's `<>` is SQL's `||`.
```

---

# What replaced the checks that are gone

Two verifiers were deleted. Recording where each of their rules went matters,
because a deleted check is otherwise indistinguishable from a forgotten one.

| Deleted | What carries the rule now |
|---|---|
| `VerifyWritableMappingsReversible` — *a computed writable mapping must supply `to:`/`into:`* | Nothing supplies an inverse; the inverse is **constructed** from the combinator. `VerifyDerivedWritability` checks the two ways the prose can disagree with it, and `GetPut`/`PutGet` check that the constructed inverse is actually one. The old check only verified the two strings were *present*, never that they were inverses — which is how a wrong inverse shipped. |
| `VerifyJoinedMappingsReadOnly` — *a mapping qualified by a join alias must be read-only* | `VerifyJoinedWritesRefused`, structurally, over the reference's relationship path rather than over a substring of SQL. |

---

# What the checks cannot know

They see one version of your code and have no memory of the previous one, so they
validate the *current state*, never the *transition*. Whether `:read_from_new` is
safe depends on whether the backfill finished and the reconciler is clean — facts
about data, not about code.

They also cannot see the database. Six things are therefore measured rather than
proven, and `mix ash_strangler.check` is where they happen:

| Measured | Why it cannot be proven |
|---|---|
| `allow_nil? false` against the projection | whether any legacy row projects NULL is a fact about rows |
| an identity, as duplicate groups over the *normalised* expression | likewise — and the normalisation is the attribute's type, not a parameter |
| a cast | which values will not convert depends on what is stored |
| every obligation carrying an assertion | the value space had no declared bound, or a `fragment` blocked evaluation |
| twin freshness, against `information_schema.columns` | a twin is a snapshot |
| twin identities, against `pg_index` | only `pg_index` knows what is enforced |
| join fan-out | a `has_one` the database does not enforce as unique returns several rows |

Two properties of that task are worth knowing. Its **exit code is non-zero when an
assertion fails**, so the twin-staleness diff can gate CI; without that the typed
layer inherits exactly the staleness problem it was built to remove. And a check
that could not *run* — no database reachable — is reported as such and does not
fail the task, because *"could not be measured"* and *"measured clean"* are
different answers and collapsing them is how a green build comes to mean nothing.

Run it before every phase change, without exception. It answers the question that
has to come first: **is my target model even satisfiable by this data?**
