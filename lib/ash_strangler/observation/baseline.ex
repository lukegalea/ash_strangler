# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Observation.Baseline do
  @moduledoc """
  The baseline: a consistent snapshot of what the forward mapping reports
  NOW, taken at watch start.

  `run/2` opens a `REPEATABLE READ` transaction, reads `max(id)` from the
  ledger INSIDE that snapshot, keyset-scans the legacy relation, and projects
  each row through the forward mapping into `:baseline` observations stamped
  with one fresh `baseline_group` uuid and the current `mapping_version`.

  Because the ledger trigger is already installed, every commit not visible
  in the snapshot arrives as an `:observation` — the handoff across the
  snapshot/stream boundary loses nothing. What it does NOT promise is
  ordering: an observation older than the baseline (id ≠ commit order) can
  arrive after it, and reconciling that is the consumer's job via
  `source_event_id` and `transaction_id`. There is deliberately no MAX(id)
  fencing: a fence would drop the rows committed between the snapshot and
  the fence, which is exactly the loss the design refuses.

  Baselines are idempotent per `(record_id, resource, baseline_group)`:
  re-running with the same group inserts nothing; a new group is a new
  snapshot. Baselines are never business events — "seen as executed", not
  "execution happened now".
  """

  alias AshStrangler.{Info, MappingVersion, Observation}
  alias AshStrangler.Sql.Ledger

  @batch 500

  @doc """
  Snapshots `resource` through the forward mapping.

  Returns `{:ok, %{group: uuid, count: n}}`, or `{:error, :no_ledger}` when
  the resource's source carries no ledger — a baseline without a stream to
  hand off to would silently miss everything after the snapshot.
  """
  def run(resource, opts) do
    repo = Keyword.fetch!(opts, :repo)

    if Info.ledger?(resource) do
      do_run(resource, repo)
    else
      {:error, :no_ledger}
    end
  end

  defp do_run(resource, repo) do
    group = Ash.UUID.generate()
    version = MappingVersion.hash(resource)
    relation = Info.relation(resource)
    {schema, table} = split(relation)

    repo.transaction(
      fn ->
        %Postgrex.Result{rows: [[_max_id]]} =
          repo.query!("SELECT COALESCE(max(id), 0) FROM #{Ledger.events_table()}")

        stream(repo, schema, table, nil, resource, group, version, 0)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, count} -> {:ok, %{group: group, count: count}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Keyset on the legacy id — a OFFSET-free scan that stays cheap at
  # production volumes and holds the snapshot's repeatable-read view.
  defp stream(_repo, _schema, _table, last_id, _resource, _group, _version, acc)
       when last_id != nil and last_id == :done,
       do: acc

  defp stream(repo, schema, table, last_id, resource, group, version, acc) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT to_jsonb(t) AS row FROM (
          SELECT * FROM #{schema}.#{table}
          WHERE ($1::bigint IS NULL OR id > $1)
          ORDER BY id
          LIMIT #{@batch}
        ) t
        """,
        [last_id]
      )

    case rows do
      [] ->
        acc

      rows ->
        jsons = Enum.map(rows, fn [[json]] -> json end)

        Enum.each(jsons, fn json ->
          store(repo, observation(repo, resource, json, group, version))
        end)

        max_seen = jsons |> Enum.map(&Jason.decode!(&1)["id"]) |> Enum.max()
        stream(repo, schema, table, max_seen, resource, group, version, acc + length(jsons))
      end
  end

  defp observation(repo, resource, row_json, group, version) do
    evaluated = Observation.evaluate_row(resource, Jason.decode!(row_json), repo)

    %Observation{
      id: Ash.UUID.generate(),
      source_event_id: nil,
      baseline_group: group,
      category: :baseline,
      resource: resource,
      record_id: evaluated.record_id,
      operation: :insert,
      before: nil,
      after: evaluated.attributes,
      changed_attributes: [],
      invalidated_attributes: [],
      origin: :unknown,
      attribution: %{actor: nil, confidence: :unknown},
      correlation_id: nil,
      causation_id: nil,
      mapping_version: version,
      source: %{
        relation: Info.relation(resource),
        primary_key: %{"id" => Jason.decode!(row_json)[to_string(Info.key(resource).from)]},
        transaction_id: nil,
        timestamp: nil,
        unprojected_attributes: evaluated.unprojected_attributes
      },
      captured_at: DateTime.utc_now(),
      recorded_at: DateTime.utc_now()
    }
  end

  # Baselines run inside the caller's transaction: the repo IS that
  # transaction's connection pool. The evaluate/store repo is passed through
  # the process dictionary-free route — the drain's repo, supplied once.
  defp store(repo, observation) do
    repo.query!(
      """
      INSERT INTO "strangler_observations"
        (id, source_event_id, baseline_group, category, resource, record_id, operation,
         before, after, changed_attributes, invalidated_attributes, origin, attribution,
         correlation_id, causation_id, mapping_version, source, captured_at, recorded_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,now())
      ON CONFLICT (record_id, resource, baseline_group) WHERE category = 'baseline'
      DO NOTHING
      """,
      [
        Ecto.UUID.dump!(observation.id),
        nil,
        Ecto.UUID.dump!(observation.baseline_group),
        "baseline",
        to_string(observation.resource),
        observation.record_id,
        "insert",
        nil,
        Jason.encode!(observation.after),
        Jason.encode!([]),
        Jason.encode!([]),
        "unknown",
        Jason.encode!(observation.attribution),
        nil,
        nil,
        observation.mapping_version,
        Jason.encode!(observation.source),
        observation.captured_at
      ]
    )
  end

  defp split(relation) do
    case String.split(relation, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end
end
