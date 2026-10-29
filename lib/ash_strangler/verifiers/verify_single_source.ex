# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifySingleSource do
  @moduledoc """
  At most one `source` per resource — across inline declarations *and*
  fragments.

  The one-declaration rule is the constitution of this package: the view, the
  triggers, the index, the backfill, the reconciler and the ledger all derive
  from a single `strangler do ... end` block, and nothing is kept in sync by
  hand. Out-of-resource mappings (see `AshStrangler.Mapping`) create a new way
  to break that rule: a resource can attach a fragment *and* declare its own
  block, or attach two fragments, and before fragments existed nothing could
  produce that shape.

  It is detectable, and in exactly one place. Spark merges a fragment's
  sections into the parent's DSL config before any verifier runs, so a second
  mapping arrives here as a second `source` entity in the `:strangler` section —
  the merged fact, not the declaration sites, is what this verifier counts.

  Without it the failure would be silent in the worst way: `AshStrangler.Info.source/1`
  takes the first entity with `Enum.find/2`, so one of the two mappings would
  drive everything and the other would simply not exist — two answers to one
  question, resolved by accident of declaration order.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    sources =
      dsl
      |> Spark.Dsl.Extension.get_entities([:strangler])
      |> Enum.filter(&is_struct(&1, AshStrangler.Source))

    case sources do
      [] ->
        :ok

      [_one] ->
        :ok

      many ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:strangler],
           message: """
           resource has #{length(many)} strangler sources (inline and/or fragments): \
           two mappings is the same bug as two answers to one question.

           `AshStrangler.Info.source/1` would take the first and silently ignore \
           the rest, so the generated view, triggers and obligations would all be \
           derived from whichever mapping happened to be declared first.

           Keep one mapping per resource. Move the inline block into the fragment, \
           or drop one of the attached fragments.
           """
         )}
    end
  end
end
