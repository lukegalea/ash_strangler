# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.RecordingObserver do
  @moduledoc """
  The observation tests' consumer: records one effect row per
  `(consumer, source_event_id)`, idempotent by the delivery contract, with a
  mode switch (`Application.put_env(:ash_strangler_test, :recording_mode,
  _)`) for the receipt paths:

    * `:ok` (default) — records the effect and returns `:ok`.
    * `{:error, :boom}` — returns `{:error, :boom}` WITHOUT recording, so the
      receipt goes error/attempts and the effect is missing until the mode
      changes back.
    * `:quarantine` — returns `{:quarantine, :asked_to}` without recording.
  """

  @behaviour AshStrangler.Observer

  @impl true
  def handle_observation(observation, %{repo: repo}) do
    case Application.get_env(:ash_strangler_test, :recording_mode, :ok) do
      :ok ->
        record(repo, observation)
        :ok

      {:error, _reason} ->
        {:error, :boom}

      :quarantine ->
        {:quarantine, :asked_to}
    end
  end

  defp record(repo, observation) do
    repo.query!(
      """
      INSERT INTO observation_effects (consumer, source_event_id, effect)
      VALUES ($1, $2, $3)
      ON CONFLICT (consumer, source_event_id) DO NOTHING
      """,
      [to_string(__MODULE__), observation.source_event_id, describe(observation)]
    )
  end

  defp describe(observation) do
    "#{observation.operation} #{observation.record_id || "-"} " <>
      inspect(observation.changed_attributes ++ observation.invalidated_attributes)
  end

  @doc "The effects this observer has recorded, in delivery-record order."
  def effects(repo) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        "SELECT source_event_id, effect FROM observation_effects WHERE consumer = $1 ORDER BY source_event_id",
        [to_string(__MODULE__)]
      )

    rows
  end

  @doc "The receipt row for this observer and observation, or nil."
  def receipt(repo, observation_id) do
    case repo.query!(
           "SELECT state, attempts, last_error FROM \"strangler_receipts\" WHERE consumer = $1 AND observation_id = $2",
           [to_string(__MODULE__), Ecto.UUID.dump!(observation_id)]
         ) do
      %Postgrex.Result{rows: [[state, attempts, last_error]]} ->
        %{state: state, attempts: attempts, last_error: last_error}

      %Postgrex.Result{rows: []} ->
        nil
    end
  end
end
