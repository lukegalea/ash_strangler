# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.KeyKind do
  @moduledoc """
  One kind of packed key: a 12-bit tag and the legacy integer columns it packs.
  See `AshStrangler.KeyKinds`.
  """
  defstruct [:name, :tag, :parts, :__spark_metadata__]

  @type t :: %__MODULE__{
          name: atom(),
          tag: pos_integer(),
          parts: [{String.t(), AshStrangler.UuidV8.width()}]
        }

  @doc "The width of each part, in order."
  @spec widths(t()) :: [AshStrangler.UuidV8.width()]
  def widths(%__MODULE__{parts: parts}), do: Enum.map(parts, &elem(&1, 1))

  @doc ~S|Each part as `{"schema.table", "column"}`, in order.|
  @spec columns(t()) :: [{String.t(), String.t()}]
  def columns(%__MODULE__{parts: parts}) do
    Enum.map(parts, fn {qualified, _width} -> split_column(qualified) end)
  end

  @doc false
  def split_column(qualified) do
    case String.split(qualified, ".") do
      [schema, table, column] -> {"#{schema}.#{table}", column}
      _ -> {nil, qualified}
    end
  end
end

defmodule AshStrangler.KeyKinds.Dsl do
  @moduledoc false

  @kind %Spark.Dsl.Entity{
    name: :kind,
    describe: """
    A kind of row, its 12-bit tag, and the legacy integer columns whose values
    its key packs.

    `parts` names each column as `"schema.table.column"` with the width it is
    packed in: 16, 32 or 64 bits, summing to at most 94. The column is the
    kind's *home*: a key of this kind must be derived from exactly these
    columns, and a reference to it must reach them through a validated foreign
    key (or say why not).

    The tag and the widths are the encoding. Changing either changes every id
    of the kind, so a tag is never reused and a width is never edited in
    place: a legacy column that widens fails compilation instead (see
    `snapshot`).
    """,
    examples: [
      ~S|kind :member, 0x001, parts: [{"library.members.id", 32}]|,
      ~S|kind :copy, 0x002, parts: [{"library.copies.branch_id", 16}, {"library.copies.copy_no", 64}]|
    ],
    target: AshStrangler.KeyKind,
    args: [:name, :tag],
    schema: [
      name: [type: :atom, required: true, doc: "The kind's name."],
      tag: [type: :pos_integer, required: true, doc: "The 12-bit tag, `0x001..0xFFF`."],
      parts: [
        type: {:list, {:tuple, [:string, {:in, [16, 32, 64]}]}},
        required: true,
        doc: ~S|The packed columns, `[{"schema.table.column", width}]`, most significant first.|
      ]
    ]
  }

  @key_kinds %Spark.Dsl.Section{
    name: :key_kinds,
    describe: """
    The registry of packed key kinds for one estate: which 12-bit tag means
    which kind of row, and which legacy integers each kind packs into its
    version 8 UUID. See `AshStrangler.UuidV8` for the layout.
    """,
    examples: [
      """
      key_kinds do
        estate 0x4C42
        snapshot "priv/legacy/snapshot/catalog.json"
        reserved [0x00F]

        kind :member, 0x001, parts: [{"library.members.id", 32}]
      end
      """
    ],
    entities: [@kind],
    schema: [
      estate: [
        type: :non_neg_integer,
        required: true,
        doc: """
        The 16-bit estate tag in the first two bytes of every key. Distinct
        estates (two legacy systems, two stacks) give distinct keys for equal
        integers.
        """
      ],
      snapshot: [
        type: :string,
        doc: """
        Path, relative to the project root, of a snapshot `catalog.json`. Every
        part must then be a `NOT NULL` integer column of the catalog no wider
        than its declared width. It becomes an `@external_resource`, so a new
        capture that widens a column fails compilation here.
        """
      ],
      reserved: [
        type: {:list, :pos_integer},
        default: [],
        doc: "Tags held back for kinds not yet declared. No kind may use one."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@key_kinds],
    transformers: [AshStrangler.Transformers.DeclareSnapshotResource],
    verifiers: [AshStrangler.Verifiers.VerifyKeyKinds]
end
