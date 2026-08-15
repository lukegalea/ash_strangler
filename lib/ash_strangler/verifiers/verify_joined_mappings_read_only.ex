# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyJoinedMappingsReadOnly do
  @moduledoc """
  A mapping that reads from a joined relation must declare itself read-only.

  ## Why writes to a join are not generated

  Writes go back through an `INSTEAD OF` trigger, and that trigger keys off
  `__legacy_id` — the primary relation's key. It knows exactly which row of the
  primary table a view row came from.

  It does not know that for a joined relation. The row it should update depends
  on the join condition, which is arbitrary SQL, and on whether a matching row
  exists at all — with a `LEFT JOIN`, quite possibly it does not, so a "write"
  would have to decide between updating nothing, inserting a row into a table
  the mapping never said it owned, and failing. There is no answer that is right
  for every schema, and picking one silently is how this sort of tool corrupts
  data.

  So joined columns are read-only, and the compiler makes you say so rather than
  discovering it when a write vanishes.

  ## What to do instead

  Give the joined relation its own resource. That is usually what the model
  wanted anyway: if `legacy.addresses` has its own rows and its own lifecycle,
  it is an `Address` resource with an `Address` view, not a handful of columns
  bolted onto `Customer`. Read them together through a relationship, write them
  separately.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    with true <- AshStrangler.Info.strangled?(dsl),
         [_ | _] = aliases <- AshStrangler.Info.join_aliases(dsl),
         [_ | _] = offenders <- writable_from_joins(dsl, aliases) do
      {:error, error(dsl, offenders)}
    else
      _ -> :ok
    end
  end

  defp writable_from_joins(dsl, aliases) do
    dsl
    |> AshStrangler.Info.mappings()
    |> Enum.filter(fn mapping ->
      mapping.writable? and reads_from_join?(mapping, aliases)
    end)
  end

  # A mapping declares which relation it reads from by qualifying its column, so
  # that qualification is what identifies it here. `"addr.city"` reads from the
  # join aliased `addr`; a bare `"city"` reads from the primary relation.
  defp reads_from_join?(mapping, aliases) do
    expression = mapping.column || mapping.from || ""

    Enum.any?(aliases, &String.contains?(expression, "#{&1}."))
  end

  defp error(dsl, offenders) do
    first = List.first(offenders)

    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :map],
      message: """
      These mappings read from a joined relation but are still marked writable:

        #{Enum.map_join(offenders, "\n  ", &inspect(&1.attribute))}

      Writes reach the primary relation through `__legacy_id`, which identifies
      exactly one row there. Nothing identifies the corresponding row in a joined
      relation -- and under a LEFT JOIN there may not be one -- so there is no
      write to generate that would be right for every schema.

      Declare the intent:

          map #{inspect(first.attribute)}, #{inspect(first.column || first.from)} do
            writable? false
            because "Read from a joined relation; write it through its own resource."
          end

      If you need to write these columns, give the joined relation its own
      resource and its own view. That is usually what the model wanted anyway.
      """
    )
  end
end
