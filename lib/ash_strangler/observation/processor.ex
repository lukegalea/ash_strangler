# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Observation.Processor do
  @moduledoc """
  The drain engine the generated Oban worker calls — one function, host-agnostic
  (`mix ash_strangler.gen.observer` renders the worker around it).

  Per batch, in ONE repo transaction:

    1. claim the resource's unprocessed ledger events `FOR UPDATE SKIP
       LOCKED`, ordered by id, WITHOUT setting `processed_at` — the
       materialisation ingester owns that column, and observation mode does
       not take the row from it. The lock only serialises concurrent drains;
       correctness after commit comes from idempotence (the partial unique
       index on `(source_event_id, resource)` and the receipts table).
    2. project each event into `strangler_observations`
       (`ON CONFLICT DO NOTHING` — replay inserts nothing).
    3. an event on relation R additionally invalidates every OTHER strangled
       resource in scope that gathers from R: one `invalidate` observation
       per resource, `record_id: nil`, the gathered attributes named, and no
       "after" — never a re-read presented as history.
    4. per registered observer without an `ok` receipt:
       `handle_observation/2` and the receipt written in this same
       transaction. `{:error, _}` increments attempts and lets the caller
       retry; at the configured max (`:ash_strangler, :observer_max_attempts`,
       default 5) the receipt goes `quarantined`. `{:quarantine, reason}`
       quarantines immediately with the reason recorded.

  Ordering: events are claimed in id order, but ledger id order is NOT commit
  order — the claim loop must keep finding rows committed out of id order, so
  there is no `WHERE id > last` cursor anywhere in here.
  """

  alias AshStrangler.{Info, Lens, MappingVersion, Observation}

  @max_attempts_default 5

  @doc """
  Drains up to `opts[:batch]` (default 100) unprocessed events for
  `resource`, projecting and delivering as above.

  `opts[:scope]` is the list of strangled resources invalidations consider
  (the generated worker passes the host's strangled resources); it defaults
  to the caller's configured `:ash_strangler, :ash_domains`.

  Returns `{:ok, drained}` with the number of events claimed, or
  `{:error, reason}` from the transaction.
  """
  def drain(repo, resource, observers, opts \\ []) do
    batch = opts[:batch] || 100
    scope = opts[:scope] || configured_resources()
    max_attempts = Application.get_env(:ash_strangler, :observer_max_attempts, @max_attempts_default)

    repo.transaction(fn ->
      rows = claim(repo, resource, batch)

      Enum.each(rows, fn row ->
        observation = Observation.project(resource, row, repo)
        stored_id = store_observation(repo, observation)
        observation = %{observation | id: stored_id}

        invalidations(repo, resource, row, scope)

        deliver(repo, observers, observation, max_attempts)
      end)

      length(rows)
    end)
  end

  defp claim(repo, resource, batch) do
    relation = Info.relation(resource)
    {schema, table} = split_relation(relation)

    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT id, source_system, source_schema, source_table, operation, primary_key,
               old_row, new_row, changed_columns, transaction_id, transaction_timestamp,
               source_user, source_request_id, source_correlation_id, actor_confidence,
               emitted_at
          FROM legacy_change_events
         WHERE source_schema = $1 AND source_table = $2 AND processed_at IS NULL
         ORDER BY id
         LIMIT $3
           FOR UPDATE SKIP LOCKED
        """,
        [schema, table, batch]
      )

    to_rows(rows)
  end

  defp to_rows(rows) do
    keys = [
      :id,
      :source_system,
      :source_schema,
      :source_table,
      :operation,
      :primary_key,
      :old_row,
      :new_row,
      :changed_columns,
      :transaction_id,
      :transaction_timestamp,
      :source_user,
      :source_request_id,
      :source_correlation_id,
      :actor_confidence,
      :emitted_at
    ]

    Enum.map(rows, fn row -> Map.new(Enum.zip(keys, row)) end)
  end

  # Returns the STORED observation's id: on first insert the new one, on a
  # replay the original -- receipts key on it, and a replay that regenerated
  # the uuid would silently reset every consumer's attempts.
  defp store_observation(repo, observation) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
      """
      INSERT INTO "strangler_observations"
        (id, source_event_id, baseline_group, category, resource, record_id, operation,
         before, after, changed_attributes, invalidated_attributes, origin, attribution,
         correlation_id, causation_id, mapping_version, source, captured_at, recorded_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,now())
      ON CONFLICT (source_event_id, resource) WHERE category = 'observation'
      DO UPDATE SET recorded_at = now()
      RETURNING id
      """,
      [
        Ecto.UUID.dump!(observation.id),
        observation.source_event_id,
        nil,
        to_string(observation.category),
        to_string(observation.resource),
        observation.record_id,
        to_string(observation.operation),
        dump_json(observation.before),
        dump_json(observation.after),
        dump_json(observation.changed_attributes),
        dump_json(observation.invalidated_attributes),
        to_string(observation.origin),
        dump_json(observation.attribution),
        observation.correlation_id,
        observation.causation_id,
        observation.mapping_version,
        dump_json(observation.source),
        observation.captured_at
      ]
    )

    case rows do
      [[id]] -> Ecto.UUID.load(id) |> elem(1)
    end
  end

  # An event on R invalidates every OTHER resource in scope that GATHERS from
  # R: a resource whose joins name R's relation reads attributes from R's
  # rows, and R's change unmoors every one of those reads. One observation
  # per resource per event, idempotent by the same partial index.
  defp invalidations(repo, resource, row, scope) do
    relation = "#{row.source_schema}.#{row.source_table}"

    for other <- scope,
        other != resource,
        attrs = gathered_attributes(other, relation),
        attrs != [] do
      observation = %Observation{
        id: Ash.UUID.generate(),
        source_event_id: row.id,
        baseline_group: nil,
        category: :observation,
        resource: other,
        record_id: nil,
        operation: :invalidate,
        before: nil,
        after: nil,
        changed_attributes: [],
        invalidated_attributes: attrs,
        origin: origin(row.source_system),
        attribution: %{actor: row.source_user, confidence: confidence(row.actor_confidence)},
        correlation_id: row.source_correlation_id,
        causation_id: row.source_request_id,
        mapping_version: MappingVersion.hash(other),
        source: %{
          relation: relation,
          primary_key: row.primary_key,
          transaction_id: row.transaction_id,
          timestamp: row.transaction_timestamp,
          unprojected_attributes: []
        },
        captured_at: row.emitted_at || row.transaction_timestamp,
        recorded_at: DateTime.utc_now()
      }

      store_observation(repo, observation)
    end
  end

  # The attributes of `other` read through a join into `relation` — the
  # mapping lenses whose relationship path resolves onto that relation.
  defp gathered_attributes(other, relation) do
    joins =
      Info.joins(other)
      |> Enum.filter(&(&1.relation == relation))
      |> MapSet.new(& &1.relationship.name)

    if MapSet.size(joins) == 0 do
      []
    else
      other
      |> Lens.for_resource()
      |> Enum.filter(fn lens ->
        Enum.any?(lens.sources, fn {path, _attr} ->
          path != [] and hd(path) in joins
        end)
      end)
      |> Enum.map(& &1.attribute)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  defp deliver(repo, observers, observation, max_attempts) do
    Enum.each(observers, fn observer ->
      # A closed receipt ("ok") never re-delivers; a quarantined one is
      # re-delivered ONLY by replay (deleting the receipt), never by a drain.
      if receipt_state(repo, observer, observation.id) in [nil, "error"] do
        case observer.handle_observation(observation, %{repo: repo}) do
          :ok ->
            write_receipt(repo, observer, observation.id, "ok", 0, nil)

          {:quarantine, reason} ->
            write_receipt(repo, observer, observation.id, "quarantined", 0, inspect(reason))

          {:error, reason} ->
            attempts = attempts(repo, observer, observation.id) + 1

            if attempts >= max_attempts do
              write_receipt(repo, observer, observation.id, "quarantined", attempts, inspect(reason))
            else
              write_receipt(repo, observer, observation.id, "error", attempts, inspect(reason))
            end
        end
      end
    end)
  end

  defp receipt_state(repo, observer, observation_id) do
    case repo.query!("SELECT state FROM \"strangler_receipts\" WHERE consumer = $1 AND observation_id = $2", [
           to_string(observer),
           Ecto.UUID.dump!(observation_id)
         ]) do
      %Postgrex.Result{rows: [[state]]} -> state
      %Postgrex.Result{rows: []} -> nil
    end
  end

  defp attempts(repo, observer, observation_id) do
    case repo.query!("SELECT attempts FROM \"strangler_receipts\" WHERE consumer = $1 AND observation_id = $2", [
           to_string(observer),
           Ecto.UUID.dump!(observation_id)
         ]) do
      %Postgrex.Result{rows: [[attempts]]} -> attempts
      %Postgrex.Result{rows: []} -> 0
    end
  end

  defp write_receipt(repo, observer, observation_id, state, attempts, last_error) do
    repo.query!(
      """
      INSERT INTO "strangler_receipts" (consumer, observation_id, state, attempts, last_error, recorded_at)
      VALUES ($1,$2,$3,$4,$5,now())
      ON CONFLICT (consumer, observation_id)
      DO UPDATE SET state = EXCLUDED.state, attempts = EXCLUDED.attempts,
                    last_error = EXCLUDED.last_error, recorded_at = now()
      """,
      [to_string(observer), Ecto.UUID.dump!(observation_id), state, attempts, last_error]
    )
  end

  # Projection values come out of typed casts — a `::uuid` arrives as a
  # 16-byte binary — and the envelope is jsonb. Convert what JSON cannot say
  # verbatim, recursively.
  defp dump_json(value) do
    value
    |> jsonable()
    |> Jason.encode!()
  end

  # Jason encodes the calendar structs natively; route them before the
  # generic struct clause, which would explode them into internals.
  defp jsonable(%Date{} = d), do: d
  defp jsonable(%Time{} = t), do: t
  defp jsonable(%DateTime{} = d), do: d
  defp jsonable(%NaiveDateTime{} = d), do: d
  defp jsonable(%Decimal{} = d), do: Decimal.to_string(d)
  defp jsonable(%_{} = struct), do: jsonable(Map.from_struct(struct))

  defp jsonable(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(<<_::128>> = uuid) do
    case Ecto.UUID.load(uuid) do
      {:ok, string} -> string
      :error -> uuid
    end
  end

  defp jsonable(other), do: other

  defp configured_resources do
    (Application.get_env(:ash, :ash_domains, []) ++
       Enum.flat_map(Application.loaded_applications(), fn {app, _, _} ->
         Application.get_env(app, :ash_domains, [])
       end))
    |> Enum.uniq()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&AshStrangler.Info.strangled?/1)
  end

  defp split_relation(relation) do
    case String.split(relation, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end

  defp origin(nil), do: :unknown
  defp origin("host"), do: :host
  defp origin("legacy"), do: :legacy
  defp origin(other) when is_binary(other), do: String.to_existing_atom(other)

  defp confidence(nil), do: :unknown
  defp confidence("asserted"), do: :asserted
  defp confidence("verified"), do: :verified
  defp confidence(other) when is_binary(other), do: String.to_existing_atom(other)
end
