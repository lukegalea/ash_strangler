# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Dsl do
  @moduledoc """
  The `estate` section: one disposition for every relation and column of a
  snapshot catalog. See `AshStrangler.Estate`.
  """

  alias AshStrangler.Estate.{Disposition, OpenReference, Residue}

  @because [
    type: :string,
    required: true,
    doc: "Why. Every gap in the strangle is a recorded decision."
  ]

  @id [
    type: :string,
    required: true,
    doc: ~s|`"schema.table"` for the whole relation, or `"schema.table.column"`.|
  ]

  @carried %Spark.Dsl.Entity{
    name: :carried,
    describe: """
    A column the new model does not use but must not lose. Its value travels
    opaquely beside the mapped row (an extension column the new application
    never reads), so the legacy application keeps it after cutover. Columns
    only.
    """,
    examples: [
      ~S|carried "lending.books.shelf_note", because: "free text the new model does not read"|
    ],
    target: Disposition,
    args: [:id],
    auto_set_fields: [kind: :carried],
    schema: [id: @id, because: @because]
  }

  @deferred %Spark.Dsl.Entity{
    name: :deferred,
    describe: """
    A relation or column a later wave strangles. `wave` names the wave and
    `target` what it becomes.
    """,
    examples: [
      ~S|deferred "lending.fines", wave: :billing, target: "Lending.Fine", because: "billing moves in its own wave"|
    ],
    target: Disposition,
    args: [:id],
    auto_set_fields: [kind: :deferred],
    schema: [
      id: @id,
      wave: [type: :atom, required: true, doc: "The wave that strangles it."],
      target: [type: :string, required: true, doc: "What it becomes, by name."],
      because: @because
    ]
  }

  @legacy_only %Spark.Dsl.Entity{
    name: :legacy_only,
    describe:
      "A relation or column that stays with the legacy application and is never strangled.",
    examples: [~S|legacy_only "lending.sessions", because: "the old application's own sessions"|],
    target: Disposition,
    args: [:id],
    auto_set_fields: [kind: :legacy_only],
    schema: [id: @id, because: @because]
  }

  @dead %Spark.Dsl.Entity{
    name: :dead,
    describe: "A relation or column nothing reads or writes any more.",
    examples: [~S|dead "lending.fax_log", because: "no writer since the fax machine went"|],
    target: Disposition,
    args: [:id],
    auto_set_fields: [kind: :dead],
    schema: [id: @id, because: @because]
  }

  @residue %Spark.Dsl.Entity{
    name: :residue,
    describe: """
    A relation a live database may carry that the catalog does not, such as a
    table an old restore still has. It must not be in the catalog, and it is
    dead by declaration. `AshStrangler.Estate.drift_allow/1` turns the list
    into allow patterns for `mix ash_strangler.snapshot drift`.
    """,
    examples: [
      ~S|residue "lending.old_reservations", because: "dropped by a migration; old restores keep it"|
    ],
    target: Residue,
    args: [:relation],
    schema: [
      relation: [type: :string, required: true, doc: ~s|`"schema.table"`.|],
      because: @because
    ]
  }

  @open_reference %Spark.Dsl.Entity{
    name: :open_reference,
    describe: """
    A foreign key out of a mapped relation that the estate accepts as not
    closed: its target columns are not mapped or claimed, or the constraint
    is `NOT VALID`. Without one, such a key fails the reference check.
    """,
    examples: [
      ~S|open_reference "lending.loans.loans_member_id_fkey", because: "members are strangled in wave 2"|
    ],
    target: OpenReference,
    args: [:id],
    schema: [
      id: [
        type: :string,
        required: true,
        doc: ~s|`"schema.table.constraint_name"`.|
      ],
      because: @because
    ]
  }

  @estate %Spark.Dsl.Section{
    name: :estate,
    describe: """
    Every relation and column of the snapshot catalog, accounted for once.

    Columns that a resource's mapping reads are `mapped`, and secrets of the
    twins involved are `secret`: both are computed, never declared. Plug-ins
    claim the columns the host's own machinery reads. Everything else is
    declared here.
    """,
    examples: [
      """
      estate do
        snapshot "priv/legacy/snapshot/catalog.json"
        resources [MyApp.Lending.Book, MyApp.Lending.Loan]

        carried "lending.books.shelf_note", because: "free text the new model does not read"
        deferred "lending.fines", wave: :billing, target: "Lending.Fine", because: "its own wave"
        legacy_only "lending.sessions", because: "the old application's own sessions"
        dead "lending.fax_log", because: "no writer since the fax machine went"
        residue "lending.old_reservations", because: "old restores still carry it"
      end
      """
    ],
    entities: [@carried, @deferred, @legacy_only, @dead, @residue, @open_reference],
    schema: [
      snapshot: [
        type: :string,
        required: true,
        doc: """
        Path, relative to the project root, of the `catalog.json` the estate
        covers. It becomes an `@external_resource` of the estate module.
        """
      ],
      resources: [
        type: {:list, :module},
        default: [],
        doc: """
        The strangled resources whose mappings read the catalog, plus any
        twin that no resource maps but whose `secrets` the estate should know.
        """
      ],
      plugins: [
        type: {:list, {:behaviour, AshStrangler.Estate.Plugin}},
        default: [],
        doc: """
        Modules implementing `AshStrangler.Estate.Plugin`: host claims and
        host checks, run by `AshStrangler.Estate.evaluate/1`.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@estate],
    transformers: [AshStrangler.Transformers.DeclareSnapshotResource],
    verifiers: [AshStrangler.Verifiers.VerifyEstate]
end
