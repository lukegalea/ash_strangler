# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Union.Dsl do
  @moduledoc """
  The `union` section: one canonical relation over several legacy branches and
  one owned branch. See `AshStrangler.Union`.
  """

  alias AshStrangler.Dsl.Combinators

  alias AshStrangler.Union.{
    Column,
    Constant,
    Extension,
    InsertThrough,
    Legacy,
    Map,
    NotWrittenBack,
    Owned,
    RefuseDelete,
    TenantKey,
    Unmapped
  }

  @phases [:read_from_legacy, :dual_write, :read_from_new, :decommissioned]

  @column %Spark.Dsl.Entity{
    name: :column,
    describe: "A column of the canonical relation. Every branch answers every column.",
    examples: [~S|column :patient, :text, null?: false|],
    target: Column,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true],
      type: [
        type: :any,
        required: true,
        doc: "An Ash type (`:string`, `:date`, ...) or a PostgreSQL type name."
      ],
      null?: [type: :boolean, default: true, doc: "Whether the owned table allows NULL."]
    ]
  }

  @key %Spark.Dsl.Entity{
    name: :key,
    describe: """
    How the branch's legacy key becomes the canonical key. Keys of different
    branches must not collide: give each its own namespace or kind, or, when
    two branches carry the same legacy entity under disjoint filters, declare
    `shares_key_with` on both.
    """,
    examples: [
      ~S|key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}|
    ],
    target: AshStrangler.Key,
    args: [:from],
    transform: {AshStrangler.Key, :transform, []},
    schema: [
      from: [type: {:or, [:atom, {:list, :atom}]}, required: true, doc: "The legacy key column."],
      strategy: [
        type: :any,
        required: true,
        doc: "`{:uuid_v8, Registry, :kind}`, `{:uuid_v5, namespace: \"...\"}` or `:identity`."
      ]
    ]
  }

  @map %Spark.Dsl.Entity{
    name: :map,
    describe: """
    A column read from the twin. `from: :column` is a rename and the branch
    can write it back in `:dual_write`; `from: expr(...)` is read-only.
    """,
    examples: [~S|map :patient, from: :patient_name|],
    target: Map,
    args: [:attribute],
    imports: [Ash.Expr, Combinators],
    schema: [
      attribute: [type: :atom, required: true],
      from: [type: {:or, [:atom, {:custom, Combinators, :expression, []}]}, required: true]
    ]
  }

  @constant %Spark.Dsl.Entity{
    name: :constant,
    describe: "A literal for every row of the branch. Read-only.",
    examples: [~S|constant :site, "north"|],
    target: Constant,
    args: [:attribute, :value],
    schema: [attribute: [type: :atom, required: true], value: [type: :any, required: true]]
  }

  @tenant_of %Spark.Dsl.Entity{
    name: :tenant_of,
    describe: """
    A column read as a packed key (`AshStrangler.KeyKinds`) of the legacy
    row's own columns. It is how a branch derives the union's `tenant`: estate
    check E5 requires `kind` to be declared `tenant?: true`. Read-only.
    """,
    examples: [~S|tenant_of :clinic, kind: {Clinic.Keys, :clinic}, from: :clinic_id|],
    target: TenantKey,
    args: [:attribute],
    schema: [
      attribute: [type: :atom, required: true],
      kind: [
        type: {:tuple, [:module, :atom]},
        required: true,
        doc: "`{Registry, :kind}`: a packed kind of the registry."
      ],
      from: [
        type: {:or, [:atom, {:list, :atom}]},
        required: true,
        doc: "The twin column (or columns, in kind order) the key packs."
      ],
      through: [
        type:
          {:list, {:list, {:tuple, [:string, {:or, [:atom, :string]}, {:or, [:atom, :string]}]}}},
        required: false,
        doc: """
        Opt-in: the tenant is not on the legacy row but is reached from it. A list of
        alternative chains, each a list of hops `{relation, match, take}` that starts at the
        single twin column `from`: the row of `relation` whose `match` equals the value so far
        (the lowest `take` when several match), whose `take` becomes the value. The first chain
        that reaches a value wins. The kind must have one part. Estate check E5 holds every hop
        to a validated foreign key and the last `take` to the kind's home column, so the chain is
        as closed as a direct `tenant_of`; without `through:` a column that is not the home, or
        has no foreign key onto it, is refused as before.
        """
      ]
    ]
  }

  @unmapped %Spark.Dsl.Entity{
    name: :unmapped,
    describe: "Columns this branch has no source for. They read NULL; the reason is recorded.",
    examples: [~S|unmapped [:notes], because: "the north system keeps no notes"|],
    target: Unmapped,
    args: [:attributes],
    schema: [
      attributes: [type: {:list, :atom}, required: true],
      because: [type: :string, required: true]
    ]
  }

  @not_written_back %Spark.Dsl.Entity{
    name: :not_written_back,
    describe: """
    Columns a `:dual_write` update does not carry to the legacy table: no guard and no `SET`, so
    a changed value is accepted and dropped, and the row keeps reading the legacy value. They are
    not counted as writers of a shared legacy column. No effect in `:read_from_legacy`. Refused
    on the owned branch.
    """,
    examples: [~S|not_written_back [:modified_on], because: "legacy stamps it itself"|],
    target: NotWrittenBack,
    args: [:attributes],
    schema: [
      attributes: [type: {:list, :atom}, required: true],
      because: [type: :string, required: true]
    ]
  }

  @extension %Spark.Dsl.Entity{
    name: :extension,
    describe: """
    Columns stored in `"<schema>"."<view>_extension"`, keyed by the union key, instead of the
    legacy table. The branch's select `LEFT JOIN`s it (no row reads NULL), and a `:dual_write`
    update upserts into it and writes nothing to the legacy table for them.
    """,
    examples: [~S|extension [:template_id]|],
    target: Extension,
    args: [:attributes],
    schema: [attributes: [type: {:list, :atom}, required: true]]
  }

  @refuse_delete %Spark.Dsl.Entity{
    name: :refuse_delete,
    describe: """
    At `:dual_write`, a delete of one of the branch's rows is refused with `because` (the same
    `BranchWriteRefused` as any refusal) instead of deleting the legacy row.
    """,
    examples: [~S|refuse_delete because: "legacy archives; it never deletes"|],
    target: RefuseDelete,
    schema: [because: [type: :string, required: true]]
  }

  @insert_through %Spark.Dsl.Entity{
    name: :insert_through,
    describe: """
    At `:dual_write`, an insert naming this branch (`NEW."__branch" = '<branch>'`) lands in the
    legacy table. The legacy table allocates its own key, so the trigger inserts the legacy row,
    then returns the view row of that key, and `RETURNING` carries the key and every default.
    The insert writes the branch's plain `map` columns (the columns a `:dual_write` update
    writes, minus the ones read from a legacy column that forms the key), upserts `extension`
    columns into the extension table, and refuses a supplied value for a column it cannot write
    (an expression, a constant, an unmapped column, a `not_written_back` column, the key).
    Without it, an insert naming the branch is refused and inserts land in the owned branch.
    """,
    examples: [
      ~S|insert_through because: "the south system expects the rows it reads to exist", set: [processed: true, verified: false]|
    ],
    target: InsertThrough,
    args: [{:optional, :columns, []}],
    schema: [
      columns: [
        type: {:list, :atom},
        default: [],
        doc: """
        Narrows the view columns the insert writes. Default: every plain `map :x, from: :column`
        column that is not in `not_written_back` and is not read from a legacy column that forms
        the key. Each named column must be one the insert can write.
        """
      ],
      set: [
        type: :keyword_list,
        default: [],
        doc: "Legacy columns the insert sets to a constant (`set: [processed: true]`)."
      ],
      because: [
        type: :string,
        required: true,
        doc: "Why inserts take this route."
      ]
    ]
  }

  @legacy %Spark.Dsl.Entity{
    name: :legacy,
    describe: """
    A legacy branch: rows that live in a twin's relation. Its `phase` is its
    own. In `:read_from_legacy` a write that would land on the branch is refused
    with `refused_because`. In `:dual_write` an update or delete of one of its
    rows is carried to the legacy table (renamed columns only), and an insert
    naming it lands in the legacy table when it declares `insert_through`.
    In `:read_from_new` and `:decommissioned` the branch has left the view: its
    rows now live in the owned table.
    """,
    examples: [
      """
      legacy :north do
        twin MyApp.Legacy.NorthVisits
        phase :read_from_legacy
        refused_because "the north system writes these rows until its cutover"
        key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
        filter expr(not is_nil(patient_name))
        map :patient, from: :patient_name
        unmapped [:notes], because: "the north system keeps no notes"
      end
      """
    ],
    target: Legacy,
    args: [:name],
    imports: [Ash.Expr, Combinators],
    entities: [
      keys: [@key],
      mappings: [@map, @constant, @tenant_of, @unmapped, @extension],
      write_rules: [@not_written_back, @refuse_delete, @insert_through]
    ],
    schema: [
      name: [type: :atom, required: true],
      filter: [
        type: {:custom, Combinators, :expression, []},
        doc: """
        An expression over the twin's columns; the branch shows only the rows where it is
        true. The rest of the relation belongs to no branch.
        """
      ],
      twin: [type: :module, required: true, doc: "The twin of the branch's legacy relation."],
      shares_key_with: [
        type: {:list, :atom},
        default: [],
        doc: """
        Other legacy branches whose `key` uses this branch's namespace or kind, on purpose: the
        same legacy entity reaches the view through whichever branch's filter takes it, and keeps
        one id either way. Every branch of the group must name every other, or the union is
        refused. Their filters must keep them apart; the estate obligation
        `key-disjoint:<view>:<a>+<b>` counts the ids more than one of them produces.
        """
      ],
      phase: [type: {:one_of, @phases}, required: true],
      refused_because: [
        type: :string,
        required: true,
        doc: "Why a write to this branch is refused in `:read_from_legacy`. Quoted in the error."
      ]
    ]
  }

  @owned %Spark.Dsl.Entity{
    name: :owned,
    describe: "The owned branch. Inserts always land here.",
    examples: [~S|owned :native|],
    target: Owned,
    args: [{:optional, :name, :owned}],
    entities: [write_rules: [@not_written_back, @insert_through]],
    schema: [
      name: [type: :atom, default: :owned],
      table: [type: :string, doc: "Defaults to `\"<view>_owned\"`, in the union's schema."]
    ]
  }

  @union %Spark.Dsl.Section{
    name: :union,
    describe: "One canonical relation, a view over legacy branches and an owned branch.",
    entities: [@column, @legacy, @owned],
    schema: [
      schema: [
        type: :string,
        default: "public",
        doc: "The schema of the view and the owned table."
      ],
      view: [type: :string, required: true, doc: "The canonical relation's name."],
      key: [type: :atom, default: :id, doc: "The canonical key column (uuid)."],
      security_definer: [
        type: :boolean,
        default: false,
        doc: """
        Render the trigger functions `SECURITY DEFINER SET search_path = pg_catalog`, so a role
        needs write on the view only, not on the legacy tables. Every relation a trigger names is
        schema-qualified; the twins must declare a schema.
        """
      ],
      functions_schema: [
        type: :string,
        default: "public",
        doc: """
        With `security_definer`, the schema that holds `uuid_generate_v5` (the trigger
        functions have no other schema on their `search_path`).
        """
      ],
      tenant: [
        type: :atom,
        doc: """
        The column that scopes a row to a tenant. Every legacy branch must derive
        it with `tenant_of` through a `tenant?: true` kind, and the column must be
        `null?: false` (estate check E5).
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@union],
    verifiers: [AshStrangler.Verifiers.VerifyUnion]

  @doc false
  def phases, do: @phases

  @doc false
  # The column, map, constant and unmapped entities, shared with `AshStrangler.Derived.Dsl`.
  def shared_entities,
    do: %{
      column: @column,
      map: @map,
      constant: @constant,
      tenant_of: @tenant_of,
      unmapped: @unmapped
    }
end
