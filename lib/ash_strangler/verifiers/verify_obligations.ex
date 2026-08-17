# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyObligations do
  @moduledoc """
  Refuses a mapping that fails a proof obligation, quoting the counterexample.

  The obligations themselves are `AshStrangler.Obligations`; this is the thin
  layer that decides which of them stop a compile.

  **Errors stop the compile. Warnings do not, and are not emitted here at all.**
  A warning in this design means one of two things — the guard lattice is a
  propositional abstraction that can suspect an overlap no real value produces, or
  the obligation was undecidable and has been re-emitted as SQL. Neither is
  something to fail a build on, and both are reported by `mix ash_strangler.check`
  where the database is available to settle them.

  Which is also why they are not `IO.warn`ed: a warning in a build log is not a
  refusal, and pretending otherwise is precisely the gap that let a wrong inverse
  ship in 0.1.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Obligations
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case Obligations.errors(dsl) do
      [] -> :ok
      [finding | _rest] -> {:error, error(dsl, finding)}
    end
  end

  defp error(dsl, finding) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, finding.attribute],
      message: """
      #{finding.obligation} violation on #{inspect(finding.attribute)}.

      #{String.trim(finding.message)}
      """
    )
  end
end
