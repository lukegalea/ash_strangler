# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Context do
  @moduledoc """
  Transaction-local attribution for the change ledger.

  Wrap a host action with `Context.set/2` and every ledger row the legacy
  trigger writes in that transaction carries WHO and WHY:

      AshStrangler.Context.set(Repo, origin: :host, actor: user.id,
                               correlation_id: correlation_id) do
        Ash.create!(Contract, params)
      end

  The values travel in `ash_strangler.*` custom GUCs, set with
  `set_config(..., true)` — transaction-local, so they die with the
  transaction and cannot leak into a neighbour. The ledger trigger reads them
  with `current_setting(..., true)` (the `true` that returns NULL instead of
  raising) and fills its attribution slots. No context, no invention:
  `origin` stays unknown, and unknown stays unknown — nothing fabricates
  `:legacy` for a write just because it did not come from the host.

  Capture itself is **never** suppressed: the context decorates the event, it
  does not gate it. A write with no context is an event with empty attribution
  slots, exactly as the ledger documented them in 0.1.
  """

  @keys [
    origin: "ash_strangler.origin",
    correlation_id: "ash_strangler.correlation_id",
    causation_id: "ash_strangler.causation_id",
    actor: "ash_strangler.actor"
  ]

  @doc """
  Sets the given attribution on the repo's connection for the duration of the
  transaction, then runs the block.

  Accepts `origin:` (`:host` or `:legacy` — the host may assert a legacy
  origin for a write it performs on legacy's behalf), `correlation_id:`,
  `causation_id:` and `actor:`. Each present key becomes one
  `set_config('ash_strangler.<key>', value, true)`; absent keys are not set,
  and the trigger's NULL-reading lookup leaves the slot empty.
  """
  @spec set(Ecto.Repo.t(), keyword(), (-> result)) :: result when result: var
  def set(repo, opts, fun) when is_list(opts) and is_function(fun, 0) do
    values =
      for {key, guc} <- @keys, value = opts[key], value != false do
        {guc, to_string(value)}
      end

    for {guc, value} <- values do
      repo.query!("SELECT set_config($1, $2, true)", [guc, value])
    end

    fun.()
  end

  @doc """
  The same, for code that manages its own transaction: returns the
  `set_config` statements to run, as `{query, params}` tuples.
  """
  @spec statements(keyword()) :: [{String.t(), [String.t()]}]
  def statements(opts) when is_list(opts) do
    for {key, guc} <- @keys, value = opts[key], value = to_string(value) do
      {"SELECT set_config($1, $2, true)", [guc, value]}
    end
  end
end
