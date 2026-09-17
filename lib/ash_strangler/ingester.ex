# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Ingester do
  @moduledoc """
  Renders the ingestion skeleton `mix ash_strangler.gen.ingester` writes into
  the host application: one module that turns a ledger event into ordinary
  Ash actions, and one Oban worker that drains the ledger by cursor and calls
  it.

  The split is the same one `AshStrangler.Migration.render/2` has from
  `mix ash_strangler.gen.migration`: this module is pure and testable, the
  task is thin.

  What the generator can derive, it writes working: the ledger row shape, the
  key derivation (through `AshStrangler.KeyDerivation`, never a re-implementation
  of the hash), the source-envelope metadata, and the delete path. What it
  cannot derive — which legacy column becomes which action input — it refuses
  to invent: the insert/update branch raises with instructions until somebody
  maps it. A generated ingester that guessed the mapping would write plausible
  wrong rows into the new model, which is the failure this whole package
  exists to make loud.
  """

  alias AshStrangler.Info

  @doc """
  Derives everything the renderer needs from a compiled, strangled resource.

  `namespace` is the module prefix the two generated modules live under, e.g.
  `MyApp.Ledger`.
  """
  @spec context(Ash.Resource.t(), module()) :: {:ok, map()} | {:error, String.t()}
  def context(resource, namespace) do
    with {:ok, _source} <- require_source(resource),
         {:ok, key} <- require_key(resource),
         {:ok, id_derivation} <- require_supported_strategy(resource, key),
         {:ok, repo} <- require_repo(resource),
         relation when is_binary(relation) <- Info.relation(resource) do
      {schema, table} =
        case String.split(relation, ".", parts: 2) do
          [schema, table] -> {schema, table}
          [table] -> {"public", table}
        end

      name = resource |> Module.split() |> List.last()

      {:ok,
       %{
         resource: resource,
         namespace: namespace,
         ingestion: Module.concat(namespace, "#{name}Ingestion"),
         worker: Module.concat(namespace, "#{name}DrainWorker"),
         repo: repo,
         relation: relation,
         schema: schema,
         table: table,
         key_column: Atom.to_string(key.from),
         id_derivation: id_derivation
       }}
    else
      {:error, message} -> {:error, message}
      # A strangled resource always has a twin, so `relation` cannot be nil
      # here; this arm exists so the `with` stays total.
      nil -> {:error, "#{inspect(resource)} has no legacy relation to drain."}
    end
  end

  defp require_source(resource) do
    if Info.strangled?(resource) do
      {:ok, Info.source(resource)}
    else
      {:error,
       """
       #{inspect(resource)} has no strangler mapping.

       The ingester drains the ledger of the legacy relation a resource is
       mapped onto, so there is nothing to generate for a resource the DSL
       does not map. Map it first:

           strangler do
             phase :read_from_legacy
             source MyApp.Legacy.Users do ... end
           end
       """}
    end
  end

  defp require_key(resource) do
    case Info.key(resource) do
      nil ->
        {:error,
         "#{inspect(resource)}'s source declares no `key`; the ingester locates rows by it."}

      key ->
        {:ok, key}
    end
  end

  # The id derivation is baked into the generated `locate/1` as source text,
  # so only the strategies this package can spell are accepted. `VerifyTwin`
  # and `KeyDerivation` document both as the whole vocabulary.
  defp require_supported_strategy(_resource, %{strategy: {:uuid_v5, namespace: ns}}) do
    {:ok, {:uuid_v5, ns}}
  end

  defp require_supported_strategy(_resource, %{strategy: :identity}) do
    {:ok, :identity}
  end

  defp require_supported_strategy(resource, %{strategy: other}) do
    {:error,
     """
     #{inspect(resource)}'s key strategy is #{inspect(other)}, and the ingester
     can only spell `{:uuid_v5, namespace: "..."}` and `:identity`.
     """}
  end

  defp require_repo(resource) do
    twin = Info.twin(resource)

    case AshPostgres.DataLayer.Info.repo(twin, :read) do
      repo when is_function(repo) ->
        # Same resolution the check task does: a per-read repo function picks
        # a repo per call, and the drain needs one concrete module baked in.
        {:ok, repo.(twin, :read)}

      repo ->
        {:ok, repo}
    end
  rescue
    _ ->
      {:error, "#{inspect(Info.twin(resource))} has no Postgres repo to read the ledger through."}
  end

  @doc "Renders the ingestion module for `ctx` (see `context/2`)."
  @spec render_ingestion(map()) :: String.t()
  def render_ingestion(ctx) do
    """
    defmodule #{inspect(ctx.ingestion)} do
      @moduledoc \"\"\"
      Ingests one row of `AshStrangler.Sql.Ledger.events_table/0` into
      #{inspect(ctx.resource)}, through ordinary Ash actions.

      Generated by `mix ash_strangler.gen.ingester #{inspect(ctx.resource)}`.
      This is a skeleton, not machinery to trust: the delete path and the row
      location are working, and the insert/update branch raises until the
      legacy-column-to-action-input mapping is written by hand — the one fact
      no generator can derive, and the one a wrong guess corrupts silently.

      Actor and provenance are part of the contract, not decoration: every
      action carries `actor:` from `resolve_actor/1` and `metadata:` carrying
      the source envelope, so an event log (ash_events, or any audit) can
      answer "who wrote this, and out of which legacy transaction".
      \"\"\"

      @doc \"\""
      Applies one ledger event. Idempotent by design — the drain is
      at-least-once, so this must tolerate being handed an event it has
      already ingested.
      \"\"\"
      def ingest(event) do
        metadata = source_envelope(event)

        case resolve_actor(event) do
          {:ok, actor} -> apply_event(event, metadata, actor: actor)
          :unattributed -> apply_event(event, metadata, [])
        end
      end

      # The delete path works as generated: locate the row by the same
      # derivation the view's key uses, and destroy it. A delete of a row that
      # is already gone is a replayed event, not an error.
      defp apply_event(%{operation: "delete"} = event, metadata, actor_opts) do
        with {:ok, legacy_key} <- fetch_key(event),
             {:ok, record} <- locate(legacy_key) do
          case record do
            nil -> {:ok, nil}
            record -> Ash.destroy(record, actor_opts ++ [metadata: metadata])
          end
        end
      end

      # The branch no generator can write: which legacy column becomes which
      # action input. `event.new_row` is the full row and `event.changed_columns`
      # the keys an UPDATE touched (maps with string keys, decoded from jsonb).
      # Locate the record with `locate/1`, then `Ash.create` when it is nil and
      # `Ash.update` when it is not — the create/update split is what makes a
      # replayed insert an update instead of a duplicate.
      defp apply_event(_event, _metadata, _actor_opts) do
        raise "implement the insert/update branch in #{inspect(__MODULE__)}"
      end

      # Return {:ok, actor} to attribute the ingested write, or :unattributed
      # to perform it with no actor at all. A legacy write has no Ash actor
      # behind it; the honest answers are a system actor, or the legacy
      # application's own user when it records one (event.source_user).
      def resolve_actor(_event), do: :unattributed

      # The envelope the host's event metadata carries, verbatim from the
      # ledger row. actor_confidence is a claim about resolve_actor/1's
      # answer — fill it when you make the answer real.
      defp source_envelope(event) do
        %{
          source_event_id: event.id,
          source_table: "\#{event.source_schema}.\#{event.source_table}",
          source_user: event.source_user,
          transaction_id: event.transaction_id,
          actor_confidence: event.actor_confidence
        }
      end

      defp fetch_key(event) do
        case event.primary_key do
          %{"#{ctx.key_column}" => legacy_key} -> {:ok, legacy_key}
          other -> {:error, {:unknown_primary_key, other}}
        end
      end

      #{locate_fn(ctx)}

      # System machinery, reading under its own authority: tighten this if the
      # resource's policies must apply to ingested writes.
      defp locate_opts, do: [authorize?: false]
    end
    """
  end

  defp locate_fn(%{id_derivation: {:uuid_v5, namespace}} = ctx) do
    """
        # `AshStrangler.KeyDerivation` is asserted to agree byte-for-byte with
        # the SQL the view uses. Never re-implement the hash or re-spell the
        # name format -- a drift finds no row and raises nothing.
        defp locate(legacy_key) do
          id =
            AshStrangler.KeyDerivation.uuid_v5(
              "#{namespace}",
              AshStrangler.KeyDerivation.name("#{ctx.relation}", legacy_key)
            )

          Ash.get(#{inspect(ctx.resource)}, id, locate_opts())
        end
    """
  end

  defp locate_fn(%{id_derivation: :identity} = ctx) do
    """
        defp locate(legacy_key) do
          Ash.get(#{inspect(ctx.resource)}, legacy_key, locate_opts())
        end
    """
  end

  @doc "Renders the Oban drain worker for `ctx` (see `context/2`)."
  @spec render_worker(map()) :: String.t()
  def render_worker(ctx) do
    """
    defmodule #{inspect(ctx.worker)} do
      @moduledoc \"\"\"
      Drains unprocessed rows of the change ledger for `#{ctx.relation}`, one
      batch per transaction, handing each row to
      #{inspect(ctx.ingestion)}.

      Generated by `mix ash_strangler.gen.ingester #{inspect(ctx.resource)}`.
      Requires the `oban` dependency and a configured Oban instance.

      ## The wake is a hint; the sweep is the guarantee

      The ledger trigger's `pg_notify` wakes this worker promptly, and a wake
      that arrives while the listener is down is simply missed. That is why
      the periodic sweep exists: enqueue this worker on a cron and let
      `unique:` collapse the overlap with wake-driven jobs, and a missed wake
      costs delay instead of delivery.

          config :my_app, Oban,
            queues: [ash_strangler_ledger: 10],
            plugins: [
              {Oban.Plugins.Cron,
               entries: [%{cron: "*/5 * * * *", job: #{inspect(ctx.worker)}}]}
            ]

      Wire the wake up beside it:

          config :ash_strangler, ledger_drain: {#{inspect(ctx.worker)}, :nudge}
      \"\"\"

      use Oban.Worker, queue: :ash_strangler_ledger, max_attempts: 10, unique: [period: 30]

      alias #{inspect(ctx.repo)}

      @batch_size 200
      @events_table AshStrangler.Sql.Ledger.events_table()

      @impl Oban.Worker
      def perform(_job), do: drain()

      @doc "The listener's wake entry point: enqueue, and return quickly."
      def nudge(_ledger_id) do
        %{} |> new() |> Oban.insert()
      end

      @doc \"\"\"
      Drains until this relation's backlog is empty, returning
      `{:ok, total_ingested}`.
      \"\"\"
      def drain(acc \\\\ 0) do
        case drain_batch() do
          {:ok, 0} -> {:ok, acc}
          {:ok, count} -> drain(acc + count)
          {:error, reason} -> {:error, reason}
        end
      end

      # Claim, ingest and mark in ONE transaction: the claim holds the row
      # locks until the batch commits, so a claimed event is ingested and
      # marked exactly once by this transaction. The flip side is that one
      # poison event rolls the whole batch back — every row stays unprocessed
      # and is retried, which is the at-least-once contract. If ingestion
      # writes to a datastore OUTSIDE this repo, the batch is no longer
      # atomic: make `#{inspect(ctx.ingestion)}.ingest/1` idempotent and mark
      # each row as it succeeds instead.
      defp drain_batch do
        #{inspect(ctx.repo)}.transaction(fn ->
          events = claim()

          Enum.each(events, fn event ->
            case #{inspect(ctx.ingestion)}.ingest(event) do
              {:ok, _} -> :ok
              {:error, reason} -> #{inspect(ctx.repo)}.rollback({:ingest_failed, event.id, reason})
            end
          end)

          mark_processed(Enum.map(events, & &1.id))
          length(events)
        end)
      end

      # FOR UPDATE SKIP LOCKED: concurrent workers claim disjoint rows instead
      # of racing for the same ones, and a worker that dies releases its claim
      # with its transaction. ORDER BY id is the cursor — events leave the
      # ledger in the order the legacy application created them, and a
      # multi-row legacy transaction shares one transaction_id.
      defp claim do
        %Postgrex.Result{columns: columns, rows: rows} =
          #{inspect(ctx.repo)}.query!(
            \"\"\"
            SELECT id, source_schema, source_table, operation, primary_key, old_row,
                   new_row, changed_columns, transaction_id, transaction_timestamp,
                   source_user, actor_confidence
              FROM \#{@events_table}
             WHERE processed_at IS NULL
               AND source_schema = $1
               AND source_table = $2
             ORDER BY id
             LIMIT $3
               FOR UPDATE SKIP LOCKED
            \"\"\",
            ["#{ctx.schema}", "#{ctx.table}", @batch_size]
          )

        Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
      end

      # Raw SQL justified: the ledger is a non-Ash infrastructure table this
      # package itself renders -- there is no Ash resource to mark rows through.
      defp mark_processed(ids) do
        #{inspect(ctx.repo)}.query!(
          "UPDATE \#{@events_table} SET processed_at = now() WHERE id = ANY($1)",
          [ids]
        )
      end
    end
    """
  end
end
