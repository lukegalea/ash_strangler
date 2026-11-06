# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Union.Dsl do
  @moduledoc """
  The `union` section: one canonical relation over several legacy branches and
  one owned branch. See `AshStrangler.Union`.
  """

  alias AshStrangler.Dsl.Combinators
  alias AshStrangler.Union.{Column, Constant, Legacy, Map, Owned, Unmapped}

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
    branches must not collide: give each its own namespace or kind.
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

  @legacy %Spark.Dsl.Entity{
    name: :legacy,
    describe: """
    A legacy branch: rows that live in a twin's relation. Its `phase` is its
    own. In `:read_from_legacy` a write that would land on the branch is refused
    with `refused_because`. In `:dual_write` an update or delete of one of its
    rows is carried to the legacy table (renamed columns only). In
    `:read_from_new` and `:decommissioned` the branch has left the view: its
    rows now live in the owned table.
    """,
    examples: [
      """
      legacy :north do
        twin MyApp.Legacy.NorthVisits
        phase :read_from_legacy
        refused_because "the north system writes these rows until its cutover"
        key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
        map :patient, from: :patient_name
        unmapped [:notes], because: "the north system keeps no notes"
      end
      """
    ],
    target: Legacy,
    args: [:name],
    entities: [keys: [@key], mappings: [@map, @constant, @unmapped]],
    schema: [
      name: [type: :atom, required: true],
      twin: [type: :module, required: true, doc: "The twin of the branch's legacy relation."],
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
      key: [type: :atom, default: :id, doc: "The canonical key column (uuid)."]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@union],
    verifiers: [AshStrangler.Verifiers.VerifyUnion]

  @doc false
  def phases, do: @phases
end
