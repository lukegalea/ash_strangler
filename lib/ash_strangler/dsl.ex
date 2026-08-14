# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Dsl do
  @moduledoc """
  The `strangler` DSL section: how an Ash resource maps onto a legacy table.

  This module defines the vocabulary only. The verifiers in
  `AshStrangler.Verifiers.*` decide what is *legal*, and SQL generation (not yet
  implemented) decides what is *emitted*.

  See the README for the whole shape at once.
  """

  @map %Spark.Dsl.Entity{
    name: :map,
    describe: """
    Maps one resource attribute onto legacy data.

    The simple form is a column name and is bidirectional by construction. The
    block form takes a forward expression and, optionally, a backward one — and
    if there is no backward expression the mapping must say `writable? false`
    and explain why.
    """,
    examples: [
      ~S|map :email, "email", cast: :citext|,
      """
      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong."
      end
      """
    ],
    target: AshStrangler.Map,
    args: [:attribute, {:optional, :column}],
    schema: [
      attribute: [
        type: :atom,
        required: true,
        doc: "The resource attribute this mapping populates."
      ],
      column: [
        type: :string,
        doc: "The legacy column, when the mapping is a plain column reference."
      ],
      from: [
        type: :string,
        doc: """
        SQL expression producing the attribute's value from legacy columns.
        Mutually exclusive with the positional `column`.
        """
      ],
      to: [
        type: :string,
        doc: """
        SQL expression producing the legacy value from the attribute, referenced
        as `$NEW.<attribute>`. Required with `into:`.
        """
      ],
      into: [
        type: :string,
        doc: "The legacy column that `to:` writes into."
      ],
      cast: [
        type: :atom,
        doc: "Postgres type to cast to, e.g. `:citext`, `:timestamptz`."
      ],
      from_zone: [
        type: :string,
        doc: """
        The time zone a naive legacy `timestamp` column is recorded in, e.g.
        `"UTC"`. **Required with `cast: :timestamptz`**, and rejected without it.

        A bare `(col)::timestamptz` on a `timestamp without time zone` column
        reads the value as wall-clock time in the *session's* `TimeZone`, so the
        instant it produces depends on a per-connection setting the view does
        not control — verified as 10.5 hours of drift between two connections
        reading the same row. `from_zone` generates `col AT TIME ZONE '<zone>'`
        instead, which is deterministic.

        Which zone a legacy column is in is a fact about the old application,
        not about its schema, so it cannot be inferred and is not guessed. If
        the column is *already* `timestamptz`, drop the `cast:` rather than
        supplying a zone: `AT TIME ZONE` on an aware value converts it back to a
        naive one, which is the opposite of what you want.
        """
      ],
      writable?: [
        type: :boolean,
        default: true,
        doc: """
        Whether writes propagate back to legacy. Setting this to `false`
        requires `because:` — the text is user-facing and appears in the runtime
        error raised when something tries to write the attribute.
        """
      ],
      because: [
        type: :string,
        doc: "Why this mapping is not writable. Required when `writable? false`."
      ]
    ]
  }

  @constant %Spark.Dsl.Entity{
    name: :constant,
    describe: "An attribute with no legacy source, given a fixed SQL expression.",
    examples: [~S|constant :organization_id, "'0000...fe'::uuid"|],
    target: AshStrangler.Constant,
    args: [:attribute, :expression],
    schema: [
      attribute: [type: :atom, required: true],
      expression: [type: :string, required: true, doc: "SQL expression, emitted verbatim."]
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
        doc: "What the view exposes: SQL NULL, or the attribute's declared default."
      ],
      because: [type: :string, required: true, doc: "Why there is no legacy source."]
    ]
  }

  @index %Spark.Dsl.Entity{
    name: :index,
    describe: """
    A uniqueness constraint that exists on the legacy table.

    Declared so constraint violations can be mapped back to the right Ash
    identity instead of surfacing as an opaque Postgres error.
    """,
    examples: [~S|index "index_users_on_login", unique: true, columns: ["login"]|],
    target: AshStrangler.Index,
    args: [:name],
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "The constraint or index name as Postgres has it."
      ],
      unique: [type: :boolean, default: false],
      columns: [type: {:list, :string}, required: true]
    ]
  }

  @key %Spark.Dsl.Entity{
    name: :key,
    describe: """
    How the modern primary key is derived from the legacy key.

    Deterministic by requirement, so SQL and Elixir agree without a lookup
    table — a lookup table is a second source of truth and a migration-time
    join on every row.
    """,
    examples: [~S|key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e...71"}|],
    target: AshStrangler.Key,
    args: [:attribute],
    schema: [
      attribute: [type: :atom, required: true, doc: "The resource's primary key attribute."],
      from: [type: :string, required: true, doc: "The legacy key column."],
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

  @source %Spark.Dsl.Entity{
    name: :source,
    describe: "The legacy relation this resource is mapped onto.",
    examples: [
      """
      source "legacy.users" do
        key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e...71"}
        map :email, "email", cast: :citext
      end
      """
    ],
    target: AshStrangler.Source,
    args: [:relation],
    entities: [mappings: [@map, @constant, @unmapped], indexes: [@index], keys: [@key]],
    schema: [
      relation: [
        type: :string,
        required: true,
        doc: ~S|The legacy relation, schema-qualified: "legacy.users".|
      ],
      writes: [
        type: {:one_of, [:auto, :triggers]},
        doc: """
        How writes reach the base table. Derived from the mapping shape when
        omitted; declaring it is an override with a real cost either way.

        - `:auto` — rely on Postgres view auto-updatability. **Keeps upserts,
          correct `RETURNING`, and `WITH CHECK OPTION`.** Requires a mapping
          Postgres considers auto-updatable.
        - `:triggers` — generate `INSTEAD OF` triggers. Governs every write and
          enables the usage counter, and **destroys all three of the above**.

        This is a trade, not an addition. See the README.
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
end
