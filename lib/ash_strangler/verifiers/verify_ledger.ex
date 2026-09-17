# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyLedger do
  @moduledoc """
  Refuses a `ledger?: true` source that cannot actually be drained.

  Two shapes are refused:

    * `ledger?` without `notify?`. The ledger records writes durably, but a
      record nobody is woken for is a backlog with a slow timer on it: without
      the wake, ingestion is only as prompt as the periodic sweep. The two
      options are one feature — the ledger is the guarantee, the notify is the
      promptness — so the DSL takes them together or not at all.

    * `ledger?` in a phase where the legacy relation is a *view*
      (`:read_from_new`, `:decommissioned`). PostgreSQL rejects row-level
      `AFTER` triggers on a view outright, so the statement this option asks
      for cannot be created there — the migration would fail at `mix
      ash.migrate` time, in whatever environment ran it first. Nothing is lost:
      past cutover the writes worth recording are Ash's own, and Ash's own
      event log (or plain notifiers) covers them.

  ## What this verifier does NOT check, and why it cannot

  "Only one ledger table per legacy relation" is not checked here because it
  cannot be: a Spark verifier sees one resource's DSL, and the resource that
  would double the ledger compiles in a module this one never sees. The
  invariant holds anyway, by construction — `AshStrangler.Sql.Ledger` derives
  the table, the function and the trigger names purely from `schema.table`, so
  two resources mapping the same twin emit byte-identical DDL and
  `AshStrangler.Migration.render/2` deduplicates it. Sharing is a property of
  the generator, not a rule for authors to follow, which is the only kind of
  rule that cannot drift.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  # The phases in which the legacy name is a real table the trigger can attach
  # to. Past cutover it is the reverse view, and "Views cannot have row-level
  # BEFORE or AFTER triggers" is PostgreSQL's answer, not this package's.
  @triggerless_phases [:read_from_new, :decommissioned]

  @impl true
  def verify(dsl) do
    with %AshStrangler.Source{ledger?: true} = source <- AshStrangler.Info.source(dsl),
         :ok <- require_notify(dsl, source),
         :ok <- require_triggerable_phase(dsl) do
      :ok
    else
      %AshStrangler.Source{} -> :ok
      nil -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp require_notify(_dsl, %{notify?: true}), do: :ok

  defp require_notify(dsl, _source) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl, :module),
       path: [:strangler, :source, :ledger?],
       message: """
       `ledger? true` requires `notify? true`.

       The ledger is the durable record; the notify is what wakes the drain
       that processes it. Without the wake, every event sits unprocessed until
       the periodic sweep runs, and "the drain is only as prompt as its cron
       entry" is not what anybody turning this on asked for.

           source MyApp.Legacy.Users do
             notify? true
             ledger? true
             ...
           end

       The two are one feature: `AshStrangler.Sql.Ledger`'s trigger writes the
       event row and then notifies `wake:<event id>` from the same function,
       transactionally. Opting into the record without the promptness leaves
       half a feature, so the verifier refuses it rather than letting the
       backlog explain itself in production.
       """
     )}
  end

  defp require_triggerable_phase(dsl) do
    phase = AshStrangler.Info.strangler_phase!(dsl)

    if phase in @triggerless_phases do
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:strangler, :source, :ledger?],
         message: """
         `ledger? true` is meaningless in phase #{inspect(phase)}.

         The ledger trigger is an `AFTER ... FOR EACH ROW` trigger on the
         legacy relation, and in this phase that name is the reverse *view* —
         PostgreSQL rejects row-level AFTER triggers on a view outright, so the
         statement this option asks for cannot be created and the migration
         would fail at `mix ash.migrate` time.

         Nothing is lost. Past cutover the writes worth recording are made
         through Ash, and Ash's own event log records them at their source —
         capturing them a second time, from a table this application now owns,
         would duplicate every event by construction.
         """
       )}
    else
      :ok
    end
  end
end
