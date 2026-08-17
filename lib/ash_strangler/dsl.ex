# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Dsl do
  @moduledoc """
  The `strangler` DSL section: how an Ash resource maps onto a legacy relation.

  This module defines the vocabulary only. `AshStrangler.Lens` decides what each
  entity *means* in both directions, the verifiers in `AshStrangler.Verifiers.*`
  decide what is *legal*, `AshStrangler.Mechanism` decides *how* Postgres carries
  each write, and `AshStrangler.Sql.*` decides what is *emitted*.

  ## Every mapping is a combinator, and the reverse is derived

  There is no slot for a hand-written inverse. That is the central change from
  0.1, where `map` took a forward SQL string in `from:` and a *separate*
  hand-written backward string in `to:`/`into:`, and nothing compared them —
  which let a wrong inverse ship and rewrite three of five lifecycle states on a
  write that never mentioned the lifecycle. See
  `documentation/topics/the-transform-layer.md` §2.

  So each entity here is a **combinator**: a shape whose reverse this module can
  construct, or which says out loud that it has none.

  | Entity | Tier | Reverse |
  |---|---|---|
  | `map` with `from: :column` | total bijection | the same column |
  | `map` with `zone:` | total bijection | `AT TIME ZONE` again, the other way |
  | `map` with a derived cast | total bijection | the cast the other way |
  | `negate` | total bijection | itself |
  | `affine` | total bijection | `(y - add) / multiply` |
  | `decode` | total bijection | the inverted value table |
  | `coalesce` | partial | `NULLIF` |
  | `concat` | partial | `split_part` |
  | `collapse` | partial | the per-clause `set:` |
  | `map` with a free `expr(...)` | opaque | none — `read_only?: true` and `because:` |

  `writable?` is gone as an author declaration. A mapping is writable when this
  module can build and verify its reverse, and `read_only?: true` is an explicit
  opt-out that still requires `because:` — while `because:` is *forbidden* on a
  mapping whose reverse is proven, so the prose cannot drift from the fact.
  """

  alias AshStrangler.Dsl.Combinators

  # Every entity that takes an expression imports `Ash.Expr`, which is how
  # `Ash.Resource.Dsl`'s own `filter`, `calculate` and `identity` entities accept
  # `expr(...)`. `Combinators` adds `touch/0`, the timestamp-preservation marker.
  @expr_imports [Ash.Expr, Combinators]

  @from_type {:or, [:atom, {:custom, Combinators, :expression, []}]}

  @from_doc """
  Where the value comes from. Either a bare legacy column — `from: :email` — or
  an expression over legacy columns: `from: expr(first_name <> " " <> last_name)`.

  A bare column is a rename, and PostgreSQL needs **no mechanism at all** for it:
  the view column is a simple reference, so it is automatically updatable and
  upserts, `RETURNING` and `WITH CHECK OPTION` all survive. See
  `AshStrangler.Mechanism`.

  An expression is checked against the closed node set
  `AshStrangler.Sql.Printer` can render. `expr(fragment("..."))` is the deliberate
  escape and classifies the mapping opaque.
  """

  @read_only [
    read_only?: [
      type: :boolean,
      default: false,
      doc: """
      Opt out of the write direction.

      This is **not** the declaration `writable?` used to be. Writability is
      derived: a mapping whose reverse can be constructed is writable, and saying
      `read_only? true` about one is refused rather than believed — a mapping that
      claims "not decomposable" about something perfectly decomposable is prose
      drifting from fact, and 0.1 had exactly that in its own fixtures.

      Requires `because:`, because that text is quoted verbatim in the runtime
      error raised when something tries to write the attribute. It is the message
      somebody reads at 3am, not documentation.
      """
    ],
    because: [
      type: :string,
      doc: """
      Why this mapping has no write direction. Required when `read_only? true`,
      and **forbidden** otherwise.
      """
    ]
  ]

  @map %Spark.Dsl.Entity{
    name: :map,
    describe: """
    Maps one resource attribute onto legacy data.

    `from: :column` is a rename and is bidirectional by construction. `from:
    expr(...)` is a projection; it is writable only when the expression is a
    simple reference or carries a `zone:`, and otherwise must declare
    `read_only? true` with a reason.
    """,
    examples: [
      ~S|map :email, from: :email|,
      ~S|map :archived_at, from: :deleted_at, zone: "UTC"|,
      """
      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong."
      """
    ],
    target: AshStrangler.Map,
    args: [:attribute],
    imports: @expr_imports,
    schema:
      [
        attribute: [
          type: :atom,
          required: true,
          doc: "The resource attribute this mapping populates."
        ],
        from: [type: @from_type, required: true, doc: @from_doc],
        zone: [
          type: :string,
          doc: """
          The time zone a naive legacy `timestamp` column is recorded in, e.g.
          `"UTC"`. Renders `col AT TIME ZONE '<zone>'` in both directions.

          This replaces 0.1's `cast: :timestamptz, from_zone:` pair and the four
          places that hard-coded its inversion by hand.

          Why it cannot be defaulted, and why the cast is not offered: a bare
          `(col)::timestamptz` on a `timestamp without time zone` column reads the
          value as wall-clock time in the **session's** `TimeZone`, so the instant
          depends on a per-connection setting the view does not control — measured
          at 10.5 hours of drift between two connections reading the same row.
          Which zone a naive column is in is a fact about the *old application*,
          not about its schema, so it cannot be inferred.

          It is also the only form that can carry an index:
          `timezone(text, timestamp without time zone)` is `IMMUTABLE`, while the
          one-argument form a bare `::timestamptz` resolves to is `STABLE`, and
          PostgreSQL refuses a `STABLE` function in an index expression.

          If the legacy column is *already* `timestamptz`, omit this —
          `AT TIME ZONE` on an aware value converts it back to a naive one, which
          is the opposite of what you want.
          """
        ]
      ] ++ @read_only
  }

  @decode %Spark.Dsl.Entity{
    name: :decode,
    describe: """
    A declared bijection between a legacy value set and an attribute value set.

    Both directions come from **one** declaration, which is the whole thesis. The
    cautionary tale is Rust's `strum` against `serde`, whose `serialize_all` and
    `rename_all` disagree by default, so one enum acquires two non-matching
    encodings and round-tripping quietly breaks.

    Checked at compile time: injectivity, totality over the legacy value space,
    and surjectivity onto the attribute's own `one_of` constraint — read off the
    resource and the twin, not restated here. Where a value space is unbounded the
    check is re-emitted as a SQL assertion for `mix ash_strangler.check` to run
    against real data.
    """,
    examples: [
      """
      decode :state_code, from: :state, values: %{
        "active"    => 0,
        "passive"   => 1,
        "pending"   => 2,
        "suspended" => 3,
        "deleted"   => 4
      }
      """
    ],
    target: AshStrangler.Decode,
    args: [:attribute],
    imports: @expr_imports,
    schema:
      [
        attribute: [type: :atom, required: true],
        from: [type: :atom, required: true, doc: "The legacy column holding the encoded value."],
        values: [
          type: :map,
          required: true,
          doc: """
          `%{legacy_value => attribute_value}`. Read left-to-right for the forward
          direction and inverted for the backward one, so the two cannot disagree.
          """
        ]
      ] ++ @read_only
  }

  @state %Spark.Dsl.Entity{
    name: :state,
    describe: """
    One clause of a `collapse`: a forward guard and a backward assignment.

    This is Sparcl's `case … of { p → e with e′ }` (rule **T-RCase**, ICFP 2020)
    and HOBiT's bidirectional `case` (ESOP 2018) — each branch carries both
    directions, which is what makes the whole table invertible.
    """,
    examples: [
      """
      state :cancelled,
        when: expr(not is_nil(cancelled_at)),
        set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]
      """
    ],
    target: AshStrangler.Collapse.State,
    args: [:value],
    imports: @expr_imports,
    schema: [
      value: [type: :any, required: true, doc: "The attribute value this clause produces."],
      when: [
        type: {:or, [{:literal, :otherwise}, {:custom, Combinators, :expression, []}]},
        required: true,
        doc: """
        The guard, as an expression over legacy columns, or `:otherwise` for the
        fallback clause.

        Exactly one clause may be `:otherwise` and it must be last — a guard after
        the fallback can never be reached, which the DMN literature calls a masked
        rule and `AshStrangler.Obligations` reports as one.
        """
      ],
      set: [
        type: :keyword_list,
        required: true,
        doc: """
        What to write back for this clause: **every** legacy column the table
        touches, so the backward direction is total and canonical by construction.
        There is no "which of the four do I write" question left to get wrong.

        Values are literals, `nil`, or `touch()` — the explicit
        timestamp-preservation marker. `touch()` writes `now()` only on an actual
        transition and preserves the stored value otherwise, which is what real
        triggers do and is the one declared `PutPut` violation in the whole design.
        Round-tripping cannot recover the original instant, so the alternative to
        declaring the loss is pretending it does not happen.
        """
      ]
    ]
  }

  @collapse %Spark.Dsl.Entity{
    name: :collapse,
    describe: """
    Several legacy columns collapsed into one attribute by a decision table.

    The four-columns-into-one-lifecycle case, which 0.1 could only express as an
    irreversible `CASE` — its own README conceded as much, with *"Four legacy
    columns with no single inverse. Supply `to:`/`into:` before enabling
    dual-write"*, which was an invitation to write the bug this design refuses.

    From one block: the forward `CASE` for the view, the backward multi-column
    assignment for the trigger, the reverse-view columns, the diagram's fan-in,
    and four of the obligations in `AshStrangler.Obligations`.
    """,
    examples: [
      """
      collapse :status do
        hit_policy :first

        state :archived,  when: expr(is_deleted),
                          set: [is_deleted: true,  cancelled_at: nil,     approved_at: nil]
        state :cancelled, when: expr(not is_nil(cancelled_at)),
                          set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]
        state :active,    when: expr(not is_nil(approved_at)),
                          set: [is_deleted: false, cancelled_at: nil,     approved_at: touch()]
        state :pending,   when: :otherwise,
                          set: [is_deleted: false, cancelled_at: nil,     approved_at: nil]
      end
      """
    ],
    target: AshStrangler.Collapse,
    args: [:attribute],
    entities: [states: [@state]],
    schema:
      [
        attribute: [type: :atom, required: true],
        hit_policy: [
          type: {:one_of, [:first, :unique]},
          default: :first,
          doc: """
          DMN's hit policies, and they mean different things to the verifier.

          - `:first` — clauses are tried in order and the first match wins, so
            overlap is legal and only an *unreachable* clause is an error.
          - `:unique` — no two clauses may overlap at all. Stricter, and worth it
            when the clauses are meant to be independent facts rather than an
            ordered cascade, because then an overlap is a modelling mistake rather
            than a precedence.
          """
        ]
      ] ++ @read_only
  }

  @coalesce %Spark.Dsl.Entity{
    name: :coalesce,
    describe: """
    A legacy NULL read as a default value. The reverse is `NULLIF`.

    An isomorphism only if the default is not *otherwise* a legal value in the
    column — if it is, `NULLIF` maps a real value back to NULL and the mapping is
    a declared semi-isomorphism rather than a bijection. That cannot be decided
    from the schema, so it is emitted as a SQL assertion for
    `mix ash_strangler.check` to measure against real data.
    """,
    examples: [~S|coalesce :attempts, from: :login_attempts, default: 0|],
    target: AshStrangler.Coalesce,
    args: [:attribute],
    imports: @expr_imports,
    schema:
      [
        attribute: [type: :atom, required: true],
        from: [type: :atom, required: true],
        default: [
          type: :any,
          required: true,
          doc: "The value a legacy NULL reads as, and the value `NULLIF` maps back to NULL."
        ]
      ] ++ @read_only
  }

  @concat %Spark.Dsl.Entity{
    name: :concat,
    describe: """
    Several legacy columns joined by a separator. The reverse is `split_part`.

    Invertible only with a separator provably absent from every operand — the
    degraded form of Boomerang's regex-ambiguity condition (POPL 2008). Absence
    cannot be decided from the schema either, so it becomes a SQL assertion:
    `mix ash_strangler.check` counts the rows in which any operand contains the
    separator, and any count above zero means the reverse is wrong for those rows.

    If that count is not zero, the honest mapping is a `map` with
    `read_only? true` — which is what `full_name` is in this package's own
    fixtures, because `'de la Cruz'` splits wrong and no separator fixes it.
    """,
    examples: [~S|concat :full_name, from: [:first_name, :last_name], separator: " "|],
    target: AshStrangler.Concat,
    args: [:attribute],
    imports: @expr_imports,
    schema:
      [
        attribute: [type: :atom, required: true],
        from: [type: {:list, :atom}, required: true, doc: "The legacy columns, in order."],
        separator: [type: :string, default: " "]
      ] ++ @read_only
  }

  @negate %Spark.Dsl.Entity{
    name: :negate,
    describe: "A boolean legacy column read inverted. Its own inverse.",
    examples: [~S|negate :active?, from: :is_deleted|],
    target: AshStrangler.Negate,
    args: [:attribute],
    imports: @expr_imports,
    schema:
      [attribute: [type: :atom, required: true], from: [type: :atom, required: true]] ++
        @read_only
  }

  @affine %Spark.Dsl.Entity{
    name: :affine,
    describe: """
    A numeric legacy column scaled and shifted: `multiply * col + add`.

    Restricted to `multiply: 1 | -1` unless the attribute's type is a *real*
    numeric — integer division is not invertible, so `multiply: 100` over an
    integer column would round-trip `1` to `0` and report success.
    """,
    examples: [~S|affine :cents, from: :dollars, multiply: 100|],
    target: AshStrangler.Affine,
    args: [:attribute],
    imports: @expr_imports,
    schema:
      [
        attribute: [type: :atom, required: true],
        from: [type: :atom, required: true],
        multiply: [type: {:or, [:integer, :float]}, default: 1],
        add: [type: {:or, [:integer, :float]}, default: 0]
      ] ++ @read_only
  }

  @constant %Spark.Dsl.Entity{
    name: :constant,
    describe: """
    An attribute with no legacy source, given a fixed expression.

    Read-only by construction: there is no legacy column to write to. Ash's own
    `type/2` is how a literal acquires a Postgres type, so the expression carries
    its meaning rather than a hand-spelled `::uuid`.
    """,
    examples: [
      ~S|constant :organization_id, expr(type("00000000-0000-0000-0000-0000000000fe", :uuid))|
    ],
    target: AshStrangler.Constant,
    args: [:attribute, :expression],
    imports: @expr_imports,
    schema: [
      attribute: [type: :atom, required: true],
      expression: [
        type: {:custom, Combinators, :constant_expression, []},
        required: true,
        doc: "An expression over no legacy columns."
      ]
    ]
  }

  @unmapped %Spark.Dsl.Entity{
    name: :unmapped,
    describe: """
    Attributes that exist on the resource and are deliberately not mapped.

    Declaring them is mandatory: an attribute that is neither mapped nor listed
    here is a compile error, because silently selecting NULL for a column
    somebody forgot is how a strangler migration loses data quietly.
    """,
    examples: [
      ~S|unmapped [:created_by_id], as: :null, because: "No provenance for pre-migration rows."|
    ],
    target: AshStrangler.Unmapped,
    args: [:attributes],
    schema: [
      attributes: [type: {:list, :atom}, required: true],
      as: [
        type: {:one_of, [:null, :default]},
        default: :null,
        doc: """
        What the view exposes: SQL NULL, or the attribute's declared default.

        `:default` is implemented. In 0.1 it was a documented option that raised
        *"not yet implemented"*, because nothing turned an Ash default into a SQL
        literal — `AshStrangler.Sql.Printer.literal/1` now does, so the option
        does what it says.

        A default that is a zero-arity function (`&DateTime.utc_now/0`) is refused
        rather than called: evaluating it at migration-generation time would
        freeze one instant into the view definition, so every legacy row would
        read the moment the migration was written.
        """
      ],
      because: [type: :string, required: true, doc: "Why there is no legacy source."]
    ]
  }

  @key %Spark.Dsl.Entity{
    name: :key,
    describe: """
    How the modern primary key is derived from the legacy key.

    Deterministic by requirement, so SQL and Elixir agree without a lookup
    table — a lookup table is a second source of truth and a migration-time join
    on every row.
    """,
    examples: [~S|key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e...71"}|],
    target: AshStrangler.Key,
    args: [:attribute],
    schema: [
      attribute: [type: :atom, required: true, doc: "The resource's primary key attribute."],
      from: [type: :atom, required: true, doc: "The legacy key column, as a twin attribute."],
      strategy: [
        type: :any,
        required: true,
        doc: """
        How to derive it. `{:uuid_v5, namespace: "..."}` hashes the legacy key
        into a stable uuid; `:identity` passes it through unchanged.
        """
      ]
    ]
  }

  @mapping_entities [
    @map,
    @decode,
    @collapse,
    @coalesce,
    @concat,
    @negate,
    @affine,
    @constant,
    @unmapped
  ]

  @source %Spark.Dsl.Entity{
    name: :source,
    describe: """
    The legacy relation this resource is mapped onto, as a **twin module**.

    A twin is the legacy relation declared as a private, read-only,
    `migrate? false` Ash resource — see `AshStrangler.Twin`. Taking a module
    rather than a `"legacy.users"` string is what makes `expr(first_name)` mean
    something, and it is what collapsed `cast:`, `index`, `join`/`on:` and the
    diagram's regex out of this DSL.
    """,
    examples: [
      """
      source MyApp.Legacy.Accounts do
        key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e...71"}
        map :email, from: :email
      end
      """
    ],
    target: AshStrangler.Source,
    args: [:twin],
    entities: [
      mappings: @mapping_entities,
      keys: [@key]
    ],
    schema: [
      twin: [
        type: {:behaviour, Ash.Resource},
        required: true,
        doc: "The twin module for the legacy relation."
      ],
      notify?: [
        type: :boolean,
        default: false,
        doc: """
        Emit an `AFTER` trigger on the legacy table that announces writes over
        `pg_notify`, for `AshStrangler.Listener` to turn into
        `Ash.Notifier.Notification`s.

        Off by default, because it is not free to the *old* system: every legacy
        write pays a `pg_notify`, and a full notify queue fails the transaction
        that issued it — which is the legacy application's transaction, not
        yours.

        Delivery is at-most-once and in-memory. Suitable for cache invalidation
        and LiveView reactivity; not suitable for an audit trail.
        """
      ],
      notify_channel: [
        type: :string,
        doc: """
        The `pg_notify` channel, defaulting to `"ash_strangler"`. One channel
        for every resource, with the resource named in the payload.

        Deliberately not interpolated from anything user-supplied at runtime:
        Postgrex has had channel-name escaping CVEs, and a channel name derived
        from a compile-time DSL literal cannot carry an injection.
        """
      ],
      backfill_interlock?: [
        type: :boolean,
        default: false,
        doc: """
        Make the `INSTEAD OF` triggers clear
        `AshStrangler.Backfill.flag_column/0` on every row they write, so a running
        backfill never re-derives a row the trigger already handled.

        This is pgroll's interlock, and it closes a real race that
        `AshStrangler.Backfill` could not close from its own side: the batch
        statement selects `WHERE flag` under `FOR NO KEY UPDATE`, and PostgreSQL
        re-evaluates a locking query's qualification against the updated row
        version — so every row a concurrent writer *cleared* is already dropped
        from the batch. The whole gap is the `false` the writer never assigns.

        The exposure it removes is narrow but nasty. A derived `set:` is a function
        of the row, so re-deriving a row the trigger handled produces identical
        bytes. A hand-passed one — `set: [counter: "counter + 1"]` — is not, and the
        race double-applies it with every row count and batch count reading
        correctly.

        **Off by default, and it has to be a declaration rather than something
        inferred from the twin.** The trigger assigns to the flag column, so the
        column must exist for the whole time the interlock is on. Deriving the flag
        from the twin's attributes would invert the contract order: turning the
        interlock *off* would mean dropping the column and regenerating the twin
        first, leaving a window in which the trigger assigns to a column that is
        gone and **every write on the legacy table fails**. As a flag, the order is
        reviewable — add the column, turn it on, run the backfill, turn it off,
        drop the column — and each step shows up in a migration diff.
        """
      ],
      on_update: [
        type: {:one_of, [:full_row, :changed_columns]},
        default: :full_row,
        doc: """
        What an `INSTEAD OF UPDATE` trigger writes back.

        This has to be a choice, because PostgreSQL makes it undetectable.
        `INSTEAD OF UPDATE` forbids a column list *and* forbids `WHEN`, and `NEW`
        arrives fully populated from the view row — so nothing distinguishes
        "this column was not in the `SET` clause" from "this column was
        explicitly set to its current value". `OLD.x IS DISTINCT FROM NEW.x`
        conflates them.

        - `:full_row` (the default) assigns every writable column every time.
          Honest about what the trigger can know; bumps a legacy `updated_at` and
          fires legacy triggers for columns nobody touched.
        - `:changed_columns` assigns only columns whose value differs from the
          old view row. Quieter, and wrong in the one case above: writing a
          column back to the value it already held is indistinguishable from not
          writing it, so a legacy trigger that fires on assignment will not fire.

        There is no third option that is right, only a documented choice.
        """
      ],
      writes: [
        type: {:one_of, [:auto, :triggers]},
        doc: """
        How writes reach the base table. **Derived** from the mapping shape when
        omitted — see `AshStrangler.Mechanism` — and declaring it is an override
        with a real cost either way.

        - `:auto` — rely on Postgres view auto-updatability. **Keeps upserts,
          correct `RETURNING`, and `WITH CHECK OPTION`.**
        - `:triggers` — generate `INSTEAD OF` triggers. Governs every write and
          nothing can reach the base table by an undescribed path, and
          **destroys all three of the above**.

        The derivation changed in v2 and it is the largest practical result in the
        redesign. 0.1 treated *any* writable computed mapping as forcing triggers
        for the whole resource. PostgreSQL's `CREATE VIEW` rule is per **column**:
        a computed column is read-only and errors only if something assigns to it,
        so a view may hold a mix. Measured on 17.10, a view with two plain
        references and two computed columns keeps upserts, `RETURNING` and
        `WITH CHECK OPTION` with no triggers at all.
        """
      ]
    ]
  }

  @strangler %Spark.Dsl.Section{
    name: :strangler,
    describe: """
    Maps this resource onto a legacy relation, and declares which migration
    phase it is in.
    """,
    entities: [@source],
    imports: @expr_imports,
    schema: [
      phase: [
        type: {:one_of, [:read_from_legacy, :dual_write, :read_from_new, :decommissioned]},
        required: true,
        doc: """
        Where this resource is in the migration. The single control knob:
        everything generated is derived from it.

        Transitions are checked — see `AshStrangler.Verifiers.VerifyPhaseTransition`.
        """
      ]
    ]
  }

  @sections [@strangler]

  @doc false
  def sections, do: @sections

  @doc false
  def mapping_entity_names, do: Enum.map(@mapping_entities, & &1.name)
end
