# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Observation.Store do
  @moduledoc """
  The observation store and its consumer receipts: infrastructure tables, not
  a resource. Same rule as the ledger — a resource over them would invite
  querying the pipeline as domain data when its only job is to be drained and
  audited.

  Unqualified names: the tables land in the migrating session's
  `current_schema()`, exactly like `legacy_change_events` — a host that owns a
  non-`public` schema points its migrations at it, and the tables follow.

  Uniqueness carries the delivery contract:

    * `(source_event_id, resource) WHERE category = 'observation'` — the
      projector is idempotent by the ledger's bigserial id; replaying an
      event inserts nothing.
    * `(record_id, resource, baseline_group) WHERE category = 'baseline'` —
      re-running a baseline with the same group id inserts nothing.

  Partial unique indexes, not `NULLS NOT DISTINCT`: the TestRepo's Postgres
  floor is 14, and the partial form also says what it means — uniqueness
  WITHIN a category, where the NULL-bearing column participates.

  The source ledger is retained, never truncated by the observation path:
  observations are a projection, and a projection that destroys its source
  has made itself unreplayable.
  """

  @spec statements() :: [%{name: atom(), up: String.t(), down: String.t()}]
  def statements do
    [
      %{
        name: :strangler_observations_table,
        up: observations_up(),
        down: "DROP TABLE IF EXISTS \"strangler_observations\";"
      },
      %{
        name: :strangler_observations_event_index,
        up: event_index_up(),
        down: "DROP INDEX IF EXISTS \"strangler_observations_event_idx\";"
      },
      %{
        name: :strangler_observations_baseline_index,
        up: baseline_index_up(),
        down: "DROP INDEX IF EXISTS \"strangler_observations_baseline_idx\";"
      },
      %{
        name: :strangler_receipts_table,
        up: receipts_up(),
        down: "DROP TABLE IF EXISTS \"strangler_receipts\";"
      }
    ]
  end

  defp observations_up do
    """
    CREATE TABLE IF NOT EXISTS "strangler_observations" (
      id uuid PRIMARY KEY,
      source_event_id bigint,
      baseline_group uuid,
      category text NOT NULL,
      resource text NOT NULL,
      record_id text,
      operation text NOT NULL,
      before jsonb,
      after jsonb,
      changed_attributes jsonb,
      invalidated_attributes jsonb,
      origin text NOT NULL,
      attribution jsonb NOT NULL,
      correlation_id text,
      causation_id text,
      mapping_version text NOT NULL,
      source jsonb NOT NULL,
      captured_at timestamptz NOT NULL,
      recorded_at timestamptz NOT NULL DEFAULT now()
    )
    """
  end

  defp event_index_up do
    """
    CREATE UNIQUE INDEX IF NOT EXISTS strangler_observations_event_idx
      ON "strangler_observations" (source_event_id, resource)
      WHERE category = 'observation'
    """
  end

  defp baseline_index_up do
    """
    CREATE UNIQUE INDEX IF NOT EXISTS strangler_observations_baseline_idx
      ON "strangler_observations" (record_id, resource, baseline_group)
      WHERE category = 'baseline'
    """
  end

  defp receipts_up do
    """
    CREATE TABLE IF NOT EXISTS "strangler_receipts" (
      consumer text NOT NULL,
      observation_id uuid NOT NULL,
      state text NOT NULL,
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      recorded_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (consumer, observation_id)
    )
    """
  end
end
