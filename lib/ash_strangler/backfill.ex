# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Backfill do
  @moduledoc """
  Batched, resumable backfill of a legacy table.

  The loop is plain functions over a repo and a table, and it reads no DSL. That
  is deliberate: a backfill is the one operation an operator wants to run
  against a table the Ash model does not describe yet — a column added by hand,
  a partially-migrated tenant, a rerun after an incident. Tying the loop to a
  compiled resource would make the emergency path the one that needs a deploy.

  ## What a backfill is *for* is already declared, so it is derived

  `plan/2` reads a strangler-mapped resource and produces the arguments `run/2`
  takes:

      {:ok, result} =
        AshStrangler.Backfill.run(
          MyApp.Repo,
          AshStrangler.Backfill.plan(MyApp.Accounts.User, store_key: :row_uuid)
        )

  Retyping those arguments is not a style question. `relation` retyped is a
  second spelling of the twin's own `postgres do table/schema end`; `key`
  retyped is a second spelling of the `key` entity's `from:`; and the value
  stored under `store_key:` is *the same uuid expression the compatibility view
  projects and the expression index carries*. Three copies of that expression
  have to be byte-identical, and the failure when they are not is the quietest
  in the package: the view has been serving derived ids to the new application
  for weeks, the backfill stores different ones, and the disagreement only
  surfaces at `:read_from_new` when the old application's integer ids stop
  resolving. So the plan comes from the declaration and the hand-passed form
  stays for the emergency it was written for.

  ## The mechanics are not clever, but each one is load-bearing

  **Keyset pagination, never `OFFSET`.** `OFFSET n` re-walks and discards `n`
  rows on every batch, so a backfill's cost is quadratic in table size and its
  last batches are its slowest. Worse, `OFFSET` is only stable if the ordering
  is stable, and a backfill mutates the very rows it is ordering over.

  **One committed transaction per batch.** The tempting single large `UPDATE`
  holds every row lock for the whole run, pins the global xmin so `VACUUM`
  reclaims nothing *cluster-wide* for the duration, and cannot be resumed: kill
  it at 90% and 90% is lost.

  **A dedicated flag column, not `AND target IS NULL`.** Taken from `pgroll`'s
  implementation (`pkg/backfill/`), which adds `_pgroll_needs_backfill boolean
  DEFAULT true` and batches on it. `IS NULL` is wrong whenever the *correct*
  value of the target column can legitimately be null — which
  `unmapped [...], as: :null` guarantees will happen here — because a finished
  row is then indistinguishable from a pending one, the batch re-selects it
  forever, and the loop never terminates. The failure is a hung job, not an
  error.

  **`FOR NO KEY UPDATE`, not `FOR UPDATE`.** Both lock the batch's rows against
  concurrent update; only `FOR UPDATE` also blocks a concurrent foreign-key
  check referencing them. A backfill is not changing the key, so it has no
  reason to make every FK check on a busy child table queue behind it.

  ## Resumability is a property of the data, not of a cursor file

  The cursor lives in memory for the duration of a run and is deliberately not
  persisted anywhere. It does not need to be: the flag column *is* the
  persisted state. `run/2` starts each pass from `min(key) WHERE flag`, so an
  interrupted run resumes by being called again, from a different machine if
  necessary, with no coordination.

  This also fixes a hazard a persisted cursor cannot: a row inserted with a key
  *below* the cursor after the cursor has passed it. `bigserial` values are
  handed out in order but committed out of order, so this is ordinary, not
  exotic. When a pass exhausts, `run/2` recomputes the minimum pending key and
  sweeps again; only when nothing is pending does it stop.

  ## The interlock is half-built, and the missing half is not in this module

  `pgroll` has a second mechanism alongside the flag column, and only the column
  was taken: **its writer clears the flag.** The dual-write trigger sets
  `_pgroll_needs_backfill = false` on every row it writes, so a row the trigger
  has already handled is never re-derived by the backfill.

  Without that half the sequence is: the compatibility view's `INSTEAD OF`
  trigger writes a row correctly, leaves the flag `true` because nothing told it
  to clear it, and a later batch re-derives that row's columns from the legacy
  row and overwrites what the trigger stored. Nothing in this module can fix
  that, and it is worth being precise about why rather than adding SQL that
  looks like a fix. The batch statement already selects `WHERE flag` under `FOR
  NO KEY UPDATE`, and PostgreSQL re-evaluates a locking query's qualification
  against the updated row version — so every row a concurrent writer *did* clear
  is already dropped from the batch. The gap is entirely the `false` the writer
  never assigns. `interlock_assignment/1` is that assignment, exported so the
  writer and the batch statement cannot spell the column differently.

  What the gap costs depends on the `set` expressions, and this is the one place
  the derived plan is safer than a hand-written one. `plan/2` derives only
  **row-functional** values — a key expression over the row's own key, a
  constant — so re-deriving a row the trigger already handled produces identical
  bytes and there is nothing to lose. A hand-passed
  `set: [counter: "counter + 1"]` is not row-functional, and the same race
  double-applies it: the stored value is wrong, every count of rows and batches
  reads correctly, and nothing reports it.

  ## What this module does not do

  No `CREATE INDEX CONCURRENTLY`. A partial index on `(key) WHERE flag` is the
  right way to keep resumption cheap on a large table, but CIC cannot run in a
  transaction block, can leave an *invalid* index behind on failure that still
  costs write throughput, and therefore needs a `pg_index.indisvalid` check and
  a migration of its own. That belongs with the migration generator, not in a
  loop that is expected to be safe to kill at any moment.

  ## Usage

      AshStrangler.Backfill.add_flag_column!(MyApp.Repo, "legacy.users")

      {:ok, result} =
        AshStrangler.Backfill.run(MyApp.Repo,
          relation: "legacy.users",
          key: "id",
          set: [tenant_id: "'0f0e...'::uuid"],
          batch_size: 5_000,
          progress: fn done, total -> IO.puts("\#{done}/\#{total}") end
        )

      AshStrangler.Backfill.drop_flag_column!(MyApp.Repo, "legacy.users")

  Or, with the middle argument derived from the mapping rather than typed:

      {:ok, result} =
        AshStrangler.Backfill.run(
          MyApp.Repo,
          AshStrangler.Backfill.plan(MyApp.Accounts.User,
            store_key: :row_uuid,
            batch_size: 5_000,
            progress: fn done, total -> IO.puts("\#{done}/\#{total}") end
          )
        )
  """

  alias AshStrangler.{Constant, Info, Key, Lens, Twin}
  alias AshStrangler.Sql.{Printer, View}

  @flag_column "_strangler_needs_backfill"
  @batch_size 1_000
  @lock_timeout 5_000
  @lock_retries 5

  # Three consecutive passes that select and update nothing while
  # `min(key) WHERE flag` still returns a row means something outside this
  # process is undoing our work (or holding it in a state we cannot see).
  # Spinning silently on that is the worst available outcome, so it raises.
  @max_empty_passes 3

  @typedoc """
  The outcome of a `run/2`.

    * `:rows` — rows actually updated. Not an estimate.
    * `:batches` — committed batch transactions.
    * `:passes` — sweeps from `min(key) WHERE flag`. More than one means rows
      appeared below a cursor that had already gone past, which is expected on
      a live table.
    * `:total` — the estimate reported to the progress callback, for reference.
    * `:complete?` — false only when `:max_batches` stopped the run early.
      Calling `run/2` again resumes it.
  """
  @type result :: %{
          rows: non_neg_integer(),
          batches: non_neg_integer(),
          passes: non_neg_integer(),
          total: non_neg_integer(),
          complete?: boolean()
        }

  # `:savepoint` is only meaningful *inside* an enclosing transaction. At the top
  # level Ecto has nothing to open a savepoint against: `repo.transaction(fun, mode:
  # :savepoint)` returns `{:error, :rollback}` and disconnects, so `batch!/3`'s
  # `{:ok, %Postgrex.Result{}} =` match fails and the run dies on its first batch.
  #
  # The sandbox is what hid this. `Ecto.Adapters.SQL.Sandbox` holds an owner
  # transaction open for the whole test, so every call in the suite is nested and
  # `:savepoint` is always correct there -- and the documented way to call these
  # functions, from a plain `mix` task or a migration that is not already in a
  # transaction, is exactly the case the suite cannot reach.
  #
  # The comment two functions down anticipated the sandbox obscuring this
  # distinction, and had it backwards: it warned that a test could not prove the
  # savepoint was needed, when the thing a test could not prove was that it is
  # sometimes wrong.
  defp transaction_mode(repo), do: if(repo.in_transaction?(), do: :savepoint, else: :transaction)

  @doc "The default flag column name, exposed so trigger and migration code cannot misspell it."
  @spec flag_column() :: String.t()
  def flag_column, do: @flag_column

  @doc """
  The `SET` fragment a concurrent writer must include to interlock with a running
  backfill.

      AshStrangler.Backfill.interlock_assignment()
      #=> ~s("_strangler_needs_backfill" = false)

  A writer that includes it declares the row done, and the batch statement's
  `WHERE #{@flag_column}` then skips it — which is the whole interlock, and the
  half of it that does not live here. See the moduledoc for what its absence
  costs.

  Exported rather than left to each writer to spell, because the two spellings
  would agree until one of them changed, and a writer assigning to a column the
  batch statement is not reading is a no-op that reports success.

  Options: `:flag_column`.
  """
  @spec interlock_assignment(keyword()) :: String.t()
  def interlock_assignment(opts \\ []) do
    flag = identifier!(Keyword.get(opts, :flag_column, @flag_column), :flag_column)

    ~s("#{flag}" = false)
  end

  @doc """
  The `run/2` options for `resource`, derived from its mapping.

  Pure — it reads the DSL and touches no database — so what a backfill is about
  to write is a value you can print and read before anything runs.

      AshStrangler.Backfill.plan(MyApp.Accounts.User, store_key: :row_uuid)
      #=> [
      #     relation: "legacy.users",
      #     key: "id",
      #     set: [
      #       {"row_uuid", "uuid_generate_v5('6b1e…'::uuid, 'legacy.users:' || id::text)"}
      #     ]
      #   ]

  ## What is derived

    * **`relation`** — the twin's relation. The twin's own
      `postgres do table/schema end` is where the legacy table's name is
      recorded; a second spelling of it in a backfill call is a second thing to
      keep in step.

    * **`key`** — `AshStrangler.Twin.column!/2` over the `key` entity's `from:`,
      so a twin whose generator found a column Elixir would not want as an atom
      still paginates on the real column name, and a stale twin raises here
      rather than paginating on a column that does not exist.

    * **`set`** — one entry per value the mapping says a legacy column should
      hold and the legacy table does not hold yet:

      * `store_key: :some_column` materialises the derived primary key into that
        column, using `AshStrangler.Sql.View`'s **own** key expression. That is
        the point of deriving it: the view's `SELECT`, the expression index and
        this `UPDATE` must produce byte-identical uuids, and a hand-typed fourth
        copy is a silent disagreement — see the moduledoc.

      * every `constant` whose attribute names a column the **twin declares**.
        A constant means "no legacy source for this value", so most of them
        write nowhere and are correctly absent from the plan. One that *does*
        name a twin column is the transitional state of an expand step: the
        column has been added, the twin regenerated, and the value has yet to be
        put in it. Once the backfill is done that `constant` becomes a `map` and
        the entry disappears from the plan on its own.

  Every derived expression is row-functional, which is what makes re-running a
  batch harmless — see the moduledoc's note on the interlock.

  ## Options

    * `:store_key` — the legacy column to store the derived key in. Refused for
      `strategy: :identity`, where `key from:` already names a stored column and
      there is nothing to derive its value *from*.
    * `:set` — extra assignments, as a keyword list. An entry for a column the
      derivation also produced replaces it, so an operator can correct one
      column without abandoning the rest of the plan.
    * anything else `run/2` takes (`:batch_size`, `:progress`, `:max_batches`,
      `:flag_column`, `:total`) is passed straight through.
  """
  @spec plan(Ash.Resource.t(), keyword()) :: keyword()
  def plan(resource, opts \\ []) do
    source =
      Info.source(resource) ||
        raise ArgumentError, """
        #{inspect(resource)} has no strangler `source`, so there is no mapping to derive a backfill from.

        Pass the backfill explicitly if you are populating a table no resource
        describes -- which is the case this module's hand-passed form exists for:

            AshStrangler.Backfill.run(MyApp.Repo,
              relation: "legacy.users",
              key: "id",
              set: [tenant_id: "'0f0e…'::uuid"]
            )
        """

    key =
      Info.key(resource) ||
        raise ArgumentError,
              "#{inspect(resource)}'s source declares no `key`, so a backfill has nothing to paginate on"

    twin = source.twin
    frame = Printer.bare_frame(twin)

    {store_key, opts} = Keyword.pop(opts, :store_key)
    {extra, opts} = Keyword.pop(opts, :set, [])

    set =
      extra
      |> Enum.concat(key_set(resource, key, frame, store_key))
      |> Enum.concat(constant_set(resource, twin, frame))
      # First wins, and `extra` is first: an explicit entry replaces the derived
      # one rather than joining it. Two assignments to one column is a hard error
      # from PostgreSQL, so this is not a preference.
      |> Enum.uniq_by(fn {column, _expression} -> to_string(column) end)

    Keyword.merge(
      [relation: Info.relation(resource), key: Twin.column!(twin, key.from), set: set],
      opts
    )
  end

  defp key_set(_resource, _key, _frame, nil), do: []

  defp key_set(_resource, %Key{strategy: :identity}, _frame, store_key) do
    raise ArgumentError, """
    store_key: #{inspect(store_key)}, but the key strategy is `:identity`.

    `:identity` means the legacy table already holds the modern key and the view
    reads it unchanged, so there is no expression to derive a value from -- the
    column named by `key from:` IS the stored key. Populating it is a choice about
    what those uuids should be, which no mapping states:

        AshStrangler.Backfill.run(MyApp.Repo,
          AshStrangler.Backfill.plan(MyApp.Accounts.User,
            set: [row_uuid: "gen_random_uuid()"]
          )
        )
    """
  end

  # `to_string`, so a derived plan is uniformly string-keyed however the option was
  # spelled -- the constants beside it come from `Twin.column!/2`, which is already
  # a string, and a plan an operator reads before running it should not be half
  # atoms.
  defp key_set(resource, key, frame, store_key) do
    [{to_string(store_key), View.key_expression(resource, key, frame)}]
  end

  # A constant with nowhere to go is skipped rather than raising, because having
  # nowhere to go is what `constant` usually means -- the value lives in the view's
  # SELECT list and in no column at all. The twin is the record of which columns
  # the legacy table actually has, so it is the thing asked.
  defp constant_set(resource, twin, frame) do
    lenses = Lens.by_attribute(resource)

    resource
    |> Info.constants()
    |> Enum.flat_map(fn %Constant{attribute: attribute} ->
      with column when not is_nil(column) <- twin_column(twin, attribute),
           %Lens{forward: forward} when not is_nil(forward) <- Map.get(lenses, attribute) do
        [{column, Printer.to_sql(forward, ref: frame)}]
      else
        _ -> []
      end
    end)
  end

  defp twin_column(twin, attribute) do
    if Ash.Resource.Info.attribute(twin, attribute), do: Twin.column!(twin, attribute)
  end

  @doc """
  Adds the `#{@flag_column}` column to `relation`.

  `boolean NOT NULL DEFAULT true`, which on PG 11+ is a catalog-only change:
  the default is constant, so no table rewrite happens and the `ACCESS
  EXCLUSIVE` lock is held for microseconds rather than for the length of a full
  rewrite. (A *volatile* default — `gen_random_uuid()`, or a stored generated
  column — does rewrite, which is why the expand step adds nullable columns and
  backfills them instead of adding a defaulted `uuid` column.)

  `NOT NULL DEFAULT true` also means rows the legacy application inserts *after*
  this runs arrive flagged, and so get backfilled. That is the intended
  behaviour: the flag is cleared by the row having been processed, not by the
  row having existed when the backfill started.

  `IF NOT EXISTS`, and that matters more than it looks: re-running this must not
  reset the flags of rows already done. A `DROP` + `ADD` pairing — the obvious
  way to make it idempotent — silently restarts a forty-million-row backfill
  from zero.

  Options: `:flag_column`, plus the `with_lock_retry/3` options.
  """
  @spec add_flag_column!(module(), String.t(), keyword()) :: :ok
  def add_flag_column!(repo, relation, opts \\ []) do
    rel = relation!(relation)
    flag = identifier!(Keyword.get(opts, :flag_column, @flag_column), :flag_column)

    with_lock_retry(repo, opts, fn ->
      repo.query!(
        ~s(ALTER TABLE #{rel} ADD COLUMN IF NOT EXISTS "#{flag}" boolean NOT NULL DEFAULT true),
        []
      )
    end)

    :ok
  end

  @doc """
  Drops the flag column.

  Metadata-only, but still `ACCESS EXCLUSIVE`, so it takes the same lock
  timeout and retry treatment as adding it. Contract this only once every
  writer that sets the flag (the dual-write triggers) is gone; a trigger that
  assigns to a dropped column fails every write on the legacy table.

  Options: `:flag_column`, plus the `with_lock_retry/3` options.
  """
  @spec drop_flag_column!(module(), String.t(), keyword()) :: :ok
  def drop_flag_column!(repo, relation, opts \\ []) do
    rel = relation!(relation)
    flag = identifier!(Keyword.get(opts, :flag_column, @flag_column), :flag_column)

    with_lock_retry(repo, opts, fn ->
      repo.query!(~s(ALTER TABLE #{rel} DROP COLUMN IF EXISTS "#{flag}"), [])
    end)

    :ok
  end

  @doc """
  Runs the backfill to completion, or until `:max_batches` batches have run.

  Options:

    * `:relation` (required) — `"schema.table"` or `"table"`.
    * `:key` (required) — the column to paginate on. Must be unique and
      orderable; the primary key, in practice.
    * `:set` — keyword list or map of `column => SQL expression`, applied to
      every row in the batch. The expressions are interpolated verbatim, not
      bound: this is a SQL generator, and the whole point is to push the work
      into the database. They are evaluated against the row being updated, so
      `[counter: "counter + 1"]` is legal and means what it says. `plan/2`
      derives these from a resource's mapping, and is the form to prefer
      whenever there is a mapping to derive them from.
    * `:batch_size` — default `#{@batch_size}`.
    * `:flag_column` — default `#{@flag_column}`.
    * `:progress` — `(done, total -> any)`, called after each non-empty batch.
    * `:max_batches` — stop after this many batches and report
      `complete?: false`. This is how a backfill is fitted into a maintenance
      window: it is resumed by calling `run/2` again.
    * `:total` — override the row-count estimate, if you already know it.

  Returns `{:ok, t:result/0}`.
  """
  @spec run(module(), keyword()) :: {:ok, result()}
  def run(repo, opts) do
    config = normalize!(opts)
    total = Keyword.get_lazy(opts, :total, fn -> total_estimate(repo, config) end)

    state = %{
      cursor: nil,
      # `nil` means "no pass in progress" — the next step is to find the
      # minimum pending key and start one.
      op: nil,
      rows: 0,
      batches: 0,
      passes: 0,
      pass_start: nil,
      pass_rows: 0,
      empty_passes: 0,
      complete?: false,
      total: total
    }

    final = loop(repo, config, state)

    {:ok, Map.take(final, [:rows, :batches, :passes, :total, :complete?])}
  end

  @doc """
  How many rows are still flagged as needing the backfill.

  An exact `count(*)`, so it is a diagnostic, not something to call in a loop.
  """
  @spec pending_count(module(), String.t(), keyword()) :: non_neg_integer()
  def pending_count(repo, relation, opts \\ []) do
    rel = relation!(relation)
    flag = identifier!(Keyword.get(opts, :flag_column, @flag_column), :flag_column)

    %Postgrex.Result{rows: [[count]]} =
      repo.query!(~s|SELECT count(*) FROM #{rel} WHERE "#{flag}"|, [])

    count
  end

  # --- the loop ---------------------------------------------------------------

  defp loop(repo, config, state) do
    cond do
      state.batches >= config.max_batches -> %{state | complete?: false}
      is_nil(state.op) -> start_pass(repo, config, state)
      true -> run_batch(repo, config, state)
    end
  end

  # A pass starts at the smallest still-pending key rather than at "the
  # beginning". On a table that is 39/40ths done, starting at the beginning
  # means walking 39 million index entries to find the first row that matters —
  # every time the job restarts.
  defp start_pass(repo, config, state) do
    case min_pending_key(repo, config) do
      nil -> %{state | complete?: true}
      key -> open_pass(repo, config, state, key)
    end
  end

  # A pass already cleared this row's flag, and the row is pending again.
  # Clearing the flag is durable, so the only ways back are something re-setting
  # it -- a trigger on the legacy table that fires on the backfill's own UPDATE
  # is the realistic one -- or the key being deleted and reinserted.
  #
  # This loops forever otherwise, and does so invisibly: every pass does real
  # work, updates real rows and reports real progress, so nothing in the
  # counters ever looks wrong. The job simply never finishes.
  defp open_pass(_repo, config, %{pass_start: pass_start}, key) when key == pass_start do
    raise """
    AshStrangler.Backfill started a second pass at key #{inspect(key)}, which an
    earlier pass had already marked as done.

    Something is setting "#{config.flag}" back to true on #{config.relation} --
    most likely a trigger that fires on this backfill's own UPDATE. Left alone
    this is an infinite loop that looks exactly like a slow backfill.
    """
  end

  defp open_pass(repo, config, state, key) do
    # `>=` for the first batch of a pass because `key` is itself pending; `>`
    # from then on. Keeping the cursor semantics in the operator rather than in
    # a "have I started yet" flag is what lets one SQL template serve both.
    loop(repo, config, %{
      state
      | cursor: key,
        op: ">=",
        pass_start: key,
        passes: state.passes + 1
    })
  end

  defp run_batch(repo, config, state) do
    keys = batch!(repo, config, state)

    case keys do
      [] ->
        end_pass(repo, config, state)

      keys ->
        state = %{
          state
          | # `max`, not `List.last`: `RETURNING` makes no ordering promise, and
            # a cursor that is not the true maximum silently re-reads rows that
            # are already done — or, if it is too high, skips rows forever.
            cursor: Enum.max(keys),
            op: ">",
            rows: state.rows + length(keys),
            pass_rows: state.pass_rows + length(keys),
            batches: state.batches + 1
        }

        if config.progress, do: config.progress.(state.rows, state.total)

        loop(repo, config, state)
    end
  end

  # The pass found nothing more above its cursor. That is the normal end of a
  # pass, but it is not the end of the run: rows can have been inserted below
  # the cursor while the pass was running (a `bigserial` allocated before ours
  # can commit after it). So we go back for the minimum pending key.
  defp end_pass(_repo, _config, %{pass_rows: 0, empty_passes: empty})
       when empty + 1 >= @max_empty_passes do
    raise """
    AshStrangler.Backfill made no progress in #{@max_empty_passes} consecutive passes \
    while rows were still flagged as pending.

    The batch statement keeps selecting nothing while `min` keeps returning a \
    row, which means something outside this process is holding rows in a state \
    this loop cannot act on. Continuing would spin, so it stops here.
    """
  end

  defp end_pass(repo, config, state) do
    empty_passes = if state.pass_rows == 0, do: state.empty_passes + 1, else: 0

    loop(repo, config, %{state | op: nil, pass_rows: 0, empty_passes: empty_passes})
  end

  # One committed transaction, one batch. See the moduledoc for why this is not
  # one big UPDATE.
  #
  # No `lock_timeout` here, unlike the DDL: these are row locks behind ordinary
  # application writes, and aborting a batch because one row was briefly locked
  # would turn a busy table into a backfill that never finishes.
  defp batch!(repo, config, state) do
    {:ok, %Postgrex.Result{rows: rows}} =
      repo.transaction(
        fn -> repo.query!(batch_sql(config, state.op), [state.cursor]) end,
        # `:savepoint` for the same reason as the DDL below: a backfill invoked
        # from inside an enclosing transaction must still get one unit of work
        # per batch.
        mode: transaction_mode(repo)
      )

    List.flatten(rows)
  end

  defp batch_sql(config, op) do
    assignments =
      Enum.map_join(config.set ++ [{config.flag, "false"}], ", ", fn {column, expression} ->
        ~s("#{column}" = #{expression})
      end)

    """
    WITH strangler_batch AS (
      SELECT "#{config.key}" AS strangler_key
      FROM #{config.relation}
      WHERE "#{config.flag}" AND "#{config.key}" #{op} $1
      ORDER BY "#{config.key}"
      LIMIT #{config.batch_size}
      FOR NO KEY UPDATE
    )
    UPDATE #{config.relation} AS strangler_target
    SET #{assignments}
    FROM strangler_batch
    WHERE strangler_target."#{config.key}" = strangler_batch.strangler_key
    RETURNING strangler_target."#{config.key}"
    """
  end

  defp min_pending_key(repo, config) do
    %Postgrex.Result{rows: [[key]]} =
      repo.query!(
        ~s|SELECT min("#{config.key}") FROM #{config.relation} WHERE "#{config.flag}"|,
        []
      )

    key
  end

  # `n_live_tup` is free; `count(*)` is a full scan of the table we are about to
  # rewrite. But the estimate is 0 until autovacuum or an explicit ANALYZE has
  # visited the table — which is exactly the state a freshly-loaded or
  # freshly-created table is in — and a progress bar reading `1000/0` is worse
  # than no progress bar. So 0 means "no statistics", not "no rows", and falls
  # back to the exact count.
  defp total_estimate(repo, config) do
    %Postgrex.Result{rows: rows} =
      repo.query!(
        "SELECT n_live_tup FROM pg_stat_user_tables WHERE relid = to_regclass($1)",
        [config.relation]
      )

    case rows do
      [[estimate]] when is_integer(estimate) and estimate > 0 ->
        estimate

      _ ->
        %Postgrex.Result{rows: [[count]]} =
          repo.query!("SELECT count(*) FROM #{config.relation}", [])

        count
    end
  end

  # --- DDL under a lock timeout -----------------------------------------------

  @doc """
  Runs `fun` inside a transaction with `lock_timeout` set, retrying on
  SQLSTATE `55P03`.

  Public because every DDL statement a strangler migration issues wants this
  treatment, not just the two in this module.

  ## Why a timeout at all

  A DDL statement waiting for `ACCESS EXCLUSIVE` goes to the *head* of the lock
  queue, and every subsequent `SELECT` queues behind it. One long-running
  reader plus one waiting `ALTER TABLE` takes the table offline for everyone —
  the `ALTER` has not run, and the reads are not running either. A short
  `lock_timeout` converts that outage into a retry.

  `statement_timeout` is not a substitute. It also kills a DDL that has already
  acquired its lock and is doing legitimate work, which is the one case you
  want to leave alone.

  ## Why each attempt is its own transaction

  A failed statement poisons its transaction: everything after it errors with
  `25P02 current transaction is aborted`. Retrying inside the transaction that
  just took the `55P03` therefore *cannot* succeed — it fails with a different,
  more confusing error, and does so instantly, so the backoff appears to work
  while never actually retrying anything.

  Options:

    * `:lock_timeout` — milliseconds, default `#{@lock_timeout}`. An integer,
      not a string, because `SET` takes no bind parameters and the value is
      therefore interpolated; an integer cannot carry SQL.
    * `:lock_retries` — default `#{@lock_retries}`.
    * `:backoff` — `(attempt -> milliseconds)`, default exponential from 100ms,
      capped at 5s.
  """
  @spec with_lock_retry(module(), keyword(), (-> any())) :: any()
  def with_lock_retry(repo, opts, fun) do
    timeout = Keyword.get(opts, :lock_timeout, @lock_timeout)
    retries = Keyword.get(opts, :lock_retries, @lock_retries)
    backoff = Keyword.get(opts, :backoff, &default_backoff/1)

    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError, ":lock_timeout must be a positive integer number of milliseconds"
    end

    attempt_locked(repo, timeout, retries, backoff, fun, 0)
  end

  defp attempt_locked(repo, timeout, retries, backoff, fun, attempt) do
    {:ok, value} =
      repo.transaction(
        fn ->
          repo.query!("SET LOCAL lock_timeout = '#{timeout}ms'", [])
          fun.()
        end,
        # Stated, not defaulted. Ecto's nested `transaction/2` joins the
        # enclosing transaction unless a savepoint is asked for -- and Ecto
        # runs migrations inside a transaction, which is precisely where this
        # function gets called from. Without a savepoint the first 55P03 aborts
        # the migration's transaction and every retry fails instantly with
        # 25P02: a retry loop that looks like it works and never retries
        # anything.
        #
        # Note for anyone testing this: `Ecto.Adapters.SQL.Sandbox` already
        # turns nested transactions into savepoints on its own, so a test suite
        # cannot tell the two apart. The guarantee has to be written down here,
        # because it cannot be asserted from inside a sandbox.
        mode: transaction_mode(repo)
      )

    value
  rescue
    error in Postgrex.Error ->
      # Only 55P03. Retrying anything else — a syntax error, a missing column —
      # burns the whole backoff budget to arrive at the same failure, and hides
      # the real one behind a delay.
      if lock_not_available?(error) and attempt < retries do
        attempt |> backoff.() |> Process.sleep()
        attempt_locked(repo, timeout, retries, backoff, fun, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp lock_not_available?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_not_available?(_), do: false

  defp default_backoff(attempt), do: min(100 * 2 ** attempt, 5_000)

  # --- configuration ----------------------------------------------------------

  defp normalize!(opts) do
    relation = relation!(Keyword.fetch!(opts, :relation))
    key = identifier!(Keyword.fetch!(opts, :key), :key)
    flag = identifier!(Keyword.get(opts, :flag_column, @flag_column), :flag_column)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)

    unless is_integer(batch_size) and batch_size > 0 do
      raise ArgumentError, ":batch_size must be a positive integer"
    end

    %{
      relation: relation,
      key: key,
      flag: flag,
      batch_size: batch_size,
      set: set!(Keyword.get(opts, :set, [])),
      progress: Keyword.get(opts, :progress),
      max_batches: Keyword.get(opts, :max_batches, :infinity)
    }
  end

  # Column names are validated as identifiers; the values are not touched at
  # all. That asymmetry is the contract: `set` values are SQL expressions by
  # design (`"counter + 1"`, `"upper(login)"`), and there is no bind-parameter
  # form for a column name, so validation is the only defence available on the
  # left-hand side.
  defp set!(set) do
    set
    |> Enum.map(fn {column, expression} ->
      unless is_binary(expression) do
        raise ArgumentError,
              "the value of `set: [#{column}: ...]` must be a SQL expression string, got: #{inspect(expression)}"
      end

      {identifier!(column, :set), expression}
    end)
  end

  # `to_string` first, so both `:id` and `"id"` are accepted.
  defp identifier!(name, option) do
    name = to_string(name)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/, name) do
      name
    else
      raise ArgumentError,
            "`#{option}` must be a plain SQL identifier (letters, digits, _ and $), got: #{inspect(name)}"
    end
  end

  defp relation!(relation) do
    relation
    |> to_string()
    |> String.split(".")
    |> case do
      [table] ->
        ~s("#{identifier!(table, :relation)}")

      [schema, table] ->
        ~s("#{identifier!(schema, :relation)}"."#{identifier!(table, :relation)}")

      _ ->
        raise ArgumentError, "`relation` must be \"table\" or \"schema.table\""
    end
  end
end
