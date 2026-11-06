# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Derived.Dsl do
  @moduledoc """
  The `derived` section: canonical rows derived from the rows of one legacy
  relation. See `AshStrangler.Derived`.
  """

  alias AshStrangler.Derived.Source
  alias AshStrangler.Dsl.Combinators

  @shared AshStrangler.Union.Dsl.shared_entities()

  @filter [
    type: {:custom, Combinators, :expression, []},
    doc: "An expression over the twin's columns; the source yields rows only where it is true."
  ]

  @mappings [@shared.map, @shared.constant, @shared.tenant_of, @shared.unmapped]

  @slot %Spark.Dsl.Entity{
    name: :slot,
    describe: """
    One canonical row per legacy row for which `filter` holds: a fixed slot of
    the legacy row (the second signatory, the primary contact), read from the
    columns that hold it.
    """,
    examples: [
      """
      slot :lead do
        filter expr(not is_nil(lead_nurse))
        map :person, from: :lead_nurse
        constant :role, "lead"
      end
      """
    ],
    target: Source,
    args: [:name],
    auto_set_fields: [kind: :slot],
    imports: [Ash.Expr, Combinators],
    entities: [mappings: @mappings],
    schema: [name: [type: :atom, required: true], filter: @filter]
  }

  @synthesized %Spark.Dsl.Entity{
    name: :synthesized,
    describe: """
    One canonical row per legacy row for which `filter` holds, whose values are
    computed (a "created" event at the row's creation time). Same shape as a
    `slot`; the name says the row has no counterpart in the legacy data.
    """,
    examples: [
      """
      synthesized :created do
        filter expr(not is_nil(created_at))
        map :happened_at, from: :created_at
        constant :role, "created"
      end
      """
    ],
    target: Source,
    args: [:name],
    auto_set_fields: [kind: :synthesized],
    imports: [Ash.Expr, Combinators],
    entities: [mappings: @mappings],
    schema: [name: [type: :atom, required: true], filter: @filter]
  }

  @element %Spark.Dsl.Entity{
    name: :element,
    describe: """
    One canonical row per element of a jsonb array of the legacy row.

    `type: :integer` accepts an element only when it is a JSON number with an
    integer value in the 32-bit range (`12.5`, `1e10` and `"12"` are refused,
    never cast); `type: :text` accepts only JSON strings. A refused element
    yields no row. Duplicate elements yield one row (the first). The element's
    value lands in the `value` column and its 1-based position in `ordinal`.
    """,
    examples: [
      """
      element :property do
        from :metadata
        path ["propertyIds"]
        type :integer
        value :property_id
        ordinal :position
        map :contract, from: :id
      end
      """
    ],
    target: Source,
    args: [:name],
    auto_set_fields: [kind: :element],
    imports: [Ash.Expr, Combinators],
    entities: [mappings: @mappings],
    schema: [
      name: [type: :atom, required: true],
      from: [type: :atom, required: true, doc: "The twin column holding the jsonb."],
      path: [
        type: {:list, :string},
        default: [],
        doc: "Object keys from the column to the array. Empty: the column is the array."
      ],
      type: [type: {:one_of, [:integer, :text]}, required: true],
      value: [type: :atom, required: true, doc: "The declared column that receives the element."],
      ordinal: [type: :atom, doc: "The declared column that receives the 1-based position."],
      filter: @filter
    ]
  }

  @derived %Spark.Dsl.Section{
    name: :derived,
    describe: "Canonical rows derived from the rows of one legacy relation, as a read-only view.",
    imports: [Ash.Expr, Combinators],
    entities: [@shared.column, @slot, @synthesized, @element],
    schema: [
      schema: [type: :string, default: "public", doc: "The schema of the view."],
      view: [type: :string, required: true, doc: "The canonical relation's name."],
      twin: [type: :module, required: true, doc: "The twin of the legacy relation."],
      key: [type: :atom, default: :id, doc: "The canonical key column (uuid)."],
      registry: [
        type: :module,
        required: true,
        doc: "The `AshStrangler.KeyKinds` registry that declares the logical kind."
      ],
      kind: [type: :atom, required: true, doc: "The `logical` kind of the registry."],
      from: [
        type: {:list, :atom},
        required: true,
        doc: """
        The twin columns that identify the legacy row. The key is the logical
        key over these values, the source's name and, for an element, its value.
        """
      ],
      filter: @filter,
      tenant: [
        type: :atom,
        doc: """
        The column that scopes a row to a tenant. Every source must derive it
        with `tenant_of` through a `tenant?: true` kind, and the column must be
        `null?: false` (estate check E5).
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@derived],
    verifiers: [AshStrangler.Verifiers.VerifyDerived]
end
