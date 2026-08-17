# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyJoinedWritesRefused do
  @moduledoc """
  A mapping that reads through a relationship must declare itself read-only.

  ## Why writes to a joined relation are not generated

  Writes go back through an `INSTEAD OF` trigger, and that trigger keys off
  `__legacy_id` — the primary relation's key. It knows exactly which row of the
  primary table a view row came from.

  It does not know that for a joined relation. The row it should update depends on
  the relationship, and on whether a matching row exists at all — the join is a
  `LEFT JOIN`, so quite possibly it does not. A "write" would have to choose between
  updating nothing, inserting a row into a table the mapping never said it owned,
  and failing. There is no answer that is right for every schema, and picking one
  silently is how this sort of tool corrupts data.

  ## What changed from 0.1, and what did not

  The *rule* is the same. What changed is that it is now detected structurally
  rather than by string matching. `VerifyJoinedMappingsReadOnly` looked for the
  join's alias as a substring of the mapping's column or `from:` text —
  `String.contains?(expression, "addr.")` — which is a heuristic over SQL, with the
  same failure mode as the deleted lineage regex: a column named `addr_line1` in a
  schema with a join aliased `addr` is a false positive waiting to happen, and an
  alias reached through a subquery is a false negative.

  Now a mapping reads `expr(address.city)` and the reference carries its
  relationship path as data. There is nothing to match.

  ## What to do instead

  Give the joined relation its own resource. That is usually what the model wanted
  anyway: if `legacy.addresses` has its own rows and its own lifecycle, it is an
  `Address` resource with an `Address` view, not a handful of columns bolted onto
  `Customer`. Read them together through a relationship, write them separately.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Info, Lens}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if Info.strangled?(dsl) do
      case offenders(dsl) do
        [] -> :ok
        offenders -> {:error, error(dsl, offenders)}
      end
    else
      :ok
    end
  end

  defp offenders(dsl) do
    dsl
    |> Lens.for_resource()
    |> Enum.reject(&(&1.combinator == :key))
    |> Enum.filter(fn lens ->
      lens.writes != [] and Enum.any?(lens.sources, fn {path, _attribute} -> path != [] end)
    end)
  end

  defp error(dsl, offenders) do
    first = List.first(offenders)

    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :map],
      message: """
      These mappings read through a relationship on the twin but still have a write
      direction:

        #{Enum.map_join(offenders, "\n  ", &describe/1)}

      Writes reach the primary relation through `__legacy_id`, which identifies
      exactly one row there. Nothing identifies the corresponding row in a joined
      relation -- and the join is a LEFT JOIN, so there may not be one -- so there is
      no write to generate that would be right for every schema.

      Declare the intent:

          map #{inspect(first.attribute)}, from: expr(#{reference(first)}),
            read_only?: true,
            because: "Read through a relationship; write it through its own resource."

      If you need to write these columns, give the joined relation its own resource
      and its own view. That is usually what the model wanted anyway.
      """
    )
  end

  defp describe(lens), do: "#{inspect(lens.attribute)} — reads #{reference(lens)}"

  defp reference(lens) do
    lens.sources
    |> Enum.find(fn {path, _attribute} -> path != [] end)
    |> case do
      {path, attribute} -> Enum.map_join(path ++ [attribute], ".", &to_string/1)
      nil -> "?"
    end
  end
end
