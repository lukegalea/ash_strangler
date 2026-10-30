# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Observation.Baseline do
  @moduledoc """
  The baseline: a consistent snapshot of what the forward mapping reports
  NOW, taken at watch start.

  `run/2` opens a `REPEATABLE READ` transaction by default, reads `max(id)` from
  the ledger INSIDE that snapshot, keyset-scans the legacy relation, and projects
  each row through the forward mapping into `:baseline` observations stamped
  with one fresh `baseline_group` uuid and the current `mapping_version`. Pass
  `isolation: :caller` when an existing transaction owns the isolation level.

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

  Pass `isolation: :caller` when an existing transaction owns the isolation
  level; the default starts a new repeatable-read transaction.
  """
  def run(resource, opts) do
    repo = Keyword.fetch!(opts, :repo)
    isolation = Keyword.get(opts, :isolation, :repeatable_read)

    if Info.ledger?(resource) do
      do_run(resource, repo, Keyword.get(opts, :group), isolation)
    else
      {:error, :no_ledger}
    end
  end

  defp do_run(resource, repo, group, isolation) do
    group = group || Ash.UUID.generate()
    version = MappingVersion.hash(resource)
    relation = Info.relation(resource)
    {schema, table} = split(relation)

    key = Info.key(resource)
    key_column = key.from

    key_type =
      AshStrangler.Sql.Printer.pg_type!(
        Ash.Resource.Info.attribute(Info.twin(resource), key_column).type
      )

    scan = %{
      repo: repo,
      schema: schema,
      table: table,
      key_column: key_column,
      key_type: key_type,
      resource: resource,
      group: group,
      version: version
    }

    repo.transaction(
      fn ->
        # This must be first when this function owns the transaction: the
        # ledger marker and keyset scan share one MVCC snapshot.
        set_isolation!(repo, isolation)
        repo.query!("SELECT COALESCE(max(id), 0) FROM #{Ledger.events_table()}")
        stream(scan, nil, 0)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, count} -> {:ok, %{group: group, count: count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp set_isolation!(repo, :repeatable_read),
    do: repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])

  defp set_isolation!(_repo, :caller), do: :ok

  # Keyset on the legacy key column, cast by its own type (bigint ids and
  # uuid ids both order and compare). An OFFSET-free scan that stays cheap at
  # production volumes and holds the snapshot's repeatable-read view.
  defp stream(state, last_id, acc) do
    %{
      repo: repo,
      schema: schema,
      table: table,
      key_column: key_column,
      key_type: key_type,
      resource: resource,
      group: group,
      version: version
    } = state

    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT to_jsonb(t) AS row FROM (
          SELECT * FROM #{schema}.#{table}
          WHERE ($1::text IS NULL OR #{key_column} > $1::#{key_type})
          ORDER BY #{key_column}
          LIMIT #{@batch}
        ) t
        """,
        [last_id && to_string(last_id)]
      )

    case rows do
      [] ->
        acc

      rows ->
        # to_jsonb arrives already decoded: the repo's jsonb extension is on.
        jsons = Enum.map(rows, fn [json] -> json end)

        inserted =
          Enum.count(jsons, fn json ->
            store(repo, observation(repo, resource, json, group, version))
          end)

        max_seen = jsons |> Enum.map(& &1[to_string(key_column)]) |> Enum.max()
        stream(state, max_seen, acc + inserted)
    end
  end

  defp observation(repo, resource, row_json, group, version) do
    evaluated = Observation.evaluate_row(resource, row_json, repo)

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
        primary_key: %{"id" => row_json[to_string(Info.key(resource).from)]},
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
  # Returns true when THIS call inserted the row -- a re-run with the same
  # group counts zero, which is what makes the reported count honest.
  defp store(repo, observation) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        INSERT INTO "strangler_observations"
          (id, source_event_id, baseline_group, category, resource, record_id, operation,
           before, after, changed_attributes, invalidated_attributes, origin, attribution,
           correlation_id, causation_id, mapping_version, source, captured_at, recorded_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,now())
        ON CONFLICT (record_id, resource, baseline_group) WHERE category = 'baseline'
        DO NOTHING
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(observation.id),
          nil,
          Ecto.UUID.dump!(observation.baseline_group),
          "baseline",
          to_string(observation.resource),
          # record_id is a TEXT column: the string id, never the dumped binary.
          observation.record_id,
          "insert",
          nil,
          dump_json(observation.after),
          "[]",
          "[]",
          "unknown",
          dump_json(observation.attribution),
          nil,
          nil,
          observation.mapping_version,
          dump_json(observation.source),
          observation.captured_at
        ]
      )

    rows != []
  end

  defp split(relation) do
    case String.split(relation, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end

  # Projection values come out of typed casts — a `::uuid` arrives as a
  # 16-byte binary — and the envelope is jsonb. Convert what JSON cannot say
  # verbatim, recursively.
  defp dump_json(%Decimal{} = d), do: Decimal.to_string(d)
  defp dump_json(%_{} = struct), do: dump_json(Map.from_struct(struct))

  defp dump_json(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), dump_json(v)} end)

  defp dump_json(list) when is_list(list), do: Enum.map(list, &dump_json/1)

  defp dump_json(<<_::128>> = uuid) do
    case Ecto.UUID.load(uuid) do
      {:ok, string} -> string
      :error -> uuid
    end
  end

  defp dump_json(other), do: other
end
