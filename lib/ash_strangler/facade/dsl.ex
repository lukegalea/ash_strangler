# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Dsl do
  @moduledoc """
  The `facade` section: a vocabulary over one source resource's rows.

      facade do
        source MyApp.Task
        read_action :read

        map :title, from: :name
        decode :state, from: :status, values: %{done: :finished}
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
        write :finish, via: :complete, sets: [state: :finished]
      end

  The mapping entities are the strangler's own (`AshStrangler.Dsl.mapping_entities/0`),
  so one grammar describes both a strangled view and a facade over it.
  """

  alias AshStrangler.Dsl.Combinators
  alias AshStrangler.Facade.{Defer, Hide, WriteSpec}

  # Every mapping entity that takes an expression imports `Ash.Expr`, which is
  # how the strangler's own entities accept `expr(...)`; `Combinators` adds
  # `touch/0`. Shared verbatim with `AshStrangler.Dsl`.
  @expr_imports [Ash.Expr, Combinators]

  @hide %Spark.Dsl.Entity{
    name: :hide,
    describe: """
    A source attribute this facade deliberately leaves out. `because:` is
    required: a hidden attribute is a decision about the vocabulary, and a
    decision without a reason is indistinguishable from an oversight.
    """,
    examples: [~S|hide :internal_notes, because: "Not part of this vocabulary."|],
    target: Hide,
    args: [:attribute],
    schema: [
      attribute: [type: :atom, required: true, doc: "The source attribute to leave out."],
      because: [
        type: :string,
        required: true,
        doc: "Why this facade does not answer it. Quoted in the estate report."
      ]
    ]
  }

  @defer %Spark.Dsl.Entity{
    name: :defer,
    describe: """
    A source attribute not placed yet. Like `hide`, it satisfies the estate
    check — every source attribute is exposed, hidden or deferred — but claims
    nothing about why, only that the placement has not happened.
    """,
    examples: [~S|defer :legacy_ref|],
    target: Defer,
    args: [:attribute],
    schema: [
      attribute: [type: :atom, required: true, doc: "The source attribute left unplaced."]
    ]
  }

  @write %Spark.Dsl.Entity{
    name: :write,
    describe: """
    One write: a generic action on the facade that runs ONE named source action,
    as the caller. `sets:` names facade attributes and the values they take (put
    through the lens at compile time and checked against the source action's own
    `set_attribute` changes, or a state machine's `transition_state`);
    `accepts:` names facade attributes whose argument value is put through the
    lens and handed to the source action as an accepted attribute or as the
    argument the action copies into that column. At least one of the two is
    required.
    """,
    examples: [
      ~S|write :finish, via: :complete, sets: [state: :finished]|,
      ~S|write :set_estimate, via: :set_estimate, accepts: [:effort_minutes]|
    ],
    target: WriteSpec,
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "The name of the facade's generic action."],
      via: [
        type: :atom,
        required: true,
        doc: "The source's update action this write runs. One write is one source action."
      ],
      sets: [
        type: :keyword_list,
        default: [],
        doc: "Facade attribute to value, put through the lens and checked against `via:`."
      ],
      accepts: [
        type: {:list, :atom},
        default: [],
        doc: "Facade attributes accepted as arguments of the generic action."
      ]
    ]
  }

  @facade %Spark.Dsl.Section{
    name: :facade,
    describe: """
    Makes this resource a facade: an Ash resource with no storage of its own
    that gives a different vocabulary to the rows of one source resource. It
    reads by calling the source's read action as the caller, and each `write`
    runs one named source action as the caller. Every fact keeps one record,
    on the source.
    """,
    entities: AshStrangler.Dsl.mapping_entities() ++ [@hide, @defer, @write],
    imports: @expr_imports,
    # `source` is a module: Spark must expand the alias in the section option.
    modules: [:source],
    schema: [
      source: [
        type: {:behaviour, Ash.Resource},
        required: true,
        doc: "The row source: an Ash resource this facade reads and writes through."
      ],
      read_action: [
        type: :atom,
        default: :read,
        doc: "The source's read action the facade calls. The source's policies decide."
      ]
    ]
  }

  @sections [@facade]

  @doc false
  def sections, do: @sections
end
