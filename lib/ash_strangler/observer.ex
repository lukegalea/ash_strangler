# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Observer do
  @moduledoc """
  A consumer of observations, as a behaviour.

      defmodule MyApp.ContractsObserver do
        @behaviour AshStrangler.Observer

        @impl true
        def handle_observation(observation, ctx) do
          # ctx.repo: the repo the processor's transaction runs on. Enqueue
          # into your own outbox INSIDE it and the effect commits with the
          # receipt.
          :ok
        end
      end

  The contract is deliberate, and the observation topic documents the whole
  of it:

    * at-least-once — the same `observation.source_event_id` can arrive more
      than once; be idempotent by it.
    * never exactly-once — do not build on delivery counts.
    * ledger id order is NOT commit order — order by what the event says,
      never by the id.
    * same-database effects are transactional with the receipt: use
      `ctx.repo`, or enqueue into an outbox on it. Effects on OTHER
      databases/services are yours to make idempotent.

  Returning:

    * `:ok` — the receipt is written `state: "ok"` and this observer never
      sees this observation again (replay resets receipts).
    * `{:error, reason}` — attempts are incremented and Oban (or the host's
      retry policy) re-runs the batch; at the configured max the receipt is
      written `state: "quarantined"` and auto-retry stops.
    * `{:quarantine, reason}` — quarantined immediately, reason recorded.
  """

  @callback handle_observation(
              observation :: AshStrangler.Observation.t(),
              ctx :: %{repo: module}
            ) ::
              :ok | {:error, term()} | {:quarantine, term()}
end
