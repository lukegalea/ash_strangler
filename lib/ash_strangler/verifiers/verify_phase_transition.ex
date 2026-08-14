defmodule AshStrangler.Verifiers.VerifyPhaseTransition do
  @moduledoc """
  Checks the phase declaration is internally consistent with the mapping.

  The phases are ordered, and each requires more of the mapping than the last:

  | Phase | Requires |
  |---|---|
  | `:read_from_legacy` | a source and a key |
  | `:dual_write` | every attribute either writable or explicitly not |
  | `:read_from_new` | as above; legacy is now the replica |
  | `:decommissioned` | nothing — the mapping is vestigial and should be deleted |

  ## What this cannot check

  It cannot verify the *transition*, only the current state, because a compile
  step sees one version of the code and has no memory of the last one. Whether
  `:read_from_new` is safe depends on whether the backfill finished and the
  reconciler is clean — runtime facts.

  That check is `mix ash_strangler.check`, which talks to the database. This
  verifier catches the subset that is knowable statically, and the mix task
  catches the rest. Saying so plainly matters: a verifier that appears to
  validate phase transitions but only validates syntax would be trusted for
  something it does not do.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if AshStrangler.Info.strangled?(dsl) do
      phase = AshStrangler.Info.strangler_phase!(dsl)
      source = AshStrangler.Info.source(dsl)

      check(dsl, phase, source)
    else
      :ok
    end
  end

  defp check(dsl, _phase, %{keys: []}) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl, :module),
       path: [:strangler, :source, :key],
       message: """
       The source declares no `key`.

       Every strangler mapping needs a deterministic derivation from the legacy
       primary key, so that SQL and Elixir agree on a row's modern id without a
       lookup table:

           key :id, from: "id", strategy: {:uuid_v5, namespace: "..."}
       """
     )}
  end

  defp check(dsl, phase, source) when phase in [:dual_write, :read_from_new] do
    undeclared =
      Enum.filter(source.mappings, fn
        %AshStrangler.Map{writable?: false, because: because} ->
          is_nil(because) or String.trim(because) == ""

        _ ->
          false
      end)

    case undeclared do
      [] ->
        :ok

      mappings ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:strangler, :phase],
           message: """
           Phase #{inspect(phase)} writes to legacy, but these mappings are
           read-only without a stated reason:

             #{Enum.map_join(mappings, "\n  ", &inspect(&1.attribute))}

           In a write phase, every unwritable attribute is a value that will
           silently not propagate. The `because:` text is shown to whoever
           attempts the write, so it has to exist before writes are enabled.
           """
         )}
    end
  end

  defp check(_dsl, _phase, _source), do: :ok
end
