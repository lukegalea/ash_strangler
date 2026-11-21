# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifyObligations do
  @moduledoc """
  Refuses a facade whose lenses fail a proof obligation, quoting the
  counterexample.

  The obligations are `AshStrangler.Obligations.over/3` — the same finite
  enumeration a strangled mapping is held to, with its facts taken from the
  source resource instead of a twin. Only **errors** stop the compile, exactly
  as `AshStrangler.Verifiers.VerifyObligations` does for the strangler:
  warnings report an abstraction the compiler can only suspect, and refusing
  on a suspicion would reject correct mappings.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Facade.Info, Obligations}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    findings = safe_findings(dsl)

    case Enum.filter(findings, &(&1.severity == :error)) do
      [] ->
        :ok

      [finding | _rest] ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:facade, finding.attribute],
           message: """
           #{finding.obligation} violation on #{inspect(finding.attribute)}.

           #{String.trim(finding.message)}
           """
         )}
    end
  end

  # `Obligations.over/3` builds lenses; an unbuilt lens is VerifySource's
  # refusal, not this verifier's.
  defp safe_findings(dsl) do
    Obligations.over(Info.source(dsl), dsl, Info.entries(dsl))
  rescue
    ArgumentError -> []
  end
end
