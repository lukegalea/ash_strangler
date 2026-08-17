# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.BackfillTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.BackfillTest.ExpandedUser
    resource AshStrangler.BackfillTest.IdentityKeyedUser
  end
end

defmodule AshStrangler.BackfillTest.ExpandedUser do
  @moduledoc """
  A resource caught mid-expand: the legacy table has grown a column and nothing
  has put a value in it yet.

  `salt` really is a column of `legacy.users`, and the twin declares it, but the
  mapping says `constant` — which is what an expand step looks like from the
  model's side between the `ALTER TABLE` and the backfill. That combination is
  the one case where `AshStrangler.Backfill.plan/2` has somewhere to write a
  constant to, and no other fixture in the suite is in that state: `LegacyUser`'s
  `organization_id` has no legacy column at all, which is the ordinary meaning of
  `constant` and correctly produces no backfill work.

  Once the backfill has run, this declaration becomes `map :salt, from: :salt`
  and the entry leaves the plan on its own — which is the property that keeps a
  derived backfill from accreting statements nobody can retire. See
  `AshStrangler.Backfill`'s moduledoc.
  """

  use Ash.Resource,
    domain: AshStrangler.BackfillTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  postgres do
    table "expanded_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :salt, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login

      constant :salt, expr("fixed-by-backfill")
    end
  end
end

defmodule AshStrangler.BackfillTest.IdentityKeyedUser do
  @moduledoc """
  A `strategy: :identity` key, here only so the refusal has something to refuse.

  `:identity` says the legacy table already holds the modern key and the view
  reads it unchanged, which means there is no expression to derive a stored value
  *from* — the column `key from:` names *is* the stored key. Deciding what those
  uuids should be is a choice the mapping does not state, so
  `AshStrangler.Backfill.plan/2` refuses `store_key:` here rather than inventing
  one.

  Never installed in the database: it exists to be read, not run.
  """

  use Ash.Resource,
    domain: AshStrangler.BackfillTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "identity_keyed_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :salt, strategy: :identity

      map :login, from: :login
    end
  end
end

defmodule AshStrangler.BackfillTest do
  @moduledoc """
  The backfill loop, against a real table.

  Every failure this file asserts against is silent in production. A backfill
  that re-processes rows corrupts the ones it touches twice; a backfill that
  skips rows leaves a partially-migrated table that reads correctly until the
  one row nobody looked at; a backfill whose predicate can never become false
  runs forever and looks like a slow job rather than a broken one. None of them
  raise on their own, so each gets an explicit test here.

  The fixture tables are created inside the test's own sandbox transaction, in
  a `backfill_test` schema, and vanish when it rolls back. The derived-plan
  tests are the exception: a plan is derived from a real mapping, so they run
  against the shared `legacy` fixture — inside the same transaction, so the
  `ALTER TABLE`s they need roll back with everything else.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Backfill
  alias AshStrangler.BackfillTest.ExpandedUser

  @relation "backfill_test.widgets"

  setup do
    # `counter` rather than a plain target column: an increment makes
    # double-processing visible. A backfill that writes the same constant twice
    # is indistinguishable from one that writes it once, which is exactly the
    # bug that would otherwise slip through the resume test below.
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS backfill_test", [])

    TestRepo.query!(
      """
      CREATE TABLE backfill_test.widgets (
        id        bigserial PRIMARY KEY,
        tenant_id uuid,
        counter   integer NOT NULL DEFAULT 0
      )
      """,
      []
    )

    :ok
  end

  defp seed!(count) do
    TestRepo.query!(
      "INSERT INTO backfill_test.widgets (counter) SELECT 0 FROM generate_series(1, $1)",
      [count]
    )
  end

  defp flags do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        ~s|SELECT "#{Backfill.flag_column()}", count(*) FROM backfill_test.widgets GROUP BY 1|,
        []
      )

    Map.new(rows, fn [flag, count] -> {flag, count} end)
  end

  defp counters do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!("SELECT counter, count(*) FROM backfill_test.widgets GROUP BY 1", [])

    Map.new(rows, fn [counter, count] -> {counter, count} end)
  end

  defp tenant_ids do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!("SELECT DISTINCT tenant_id FROM backfill_test.widgets", [])

    List.flatten(rows)
  end

  defp increment_config(opts) do
    Keyword.merge(
      [relation: @relation, key: "id", set: [counter: "counter + 1"], batch_size: 3],
      opts
    )
  end

  describe "add_flag_column!/3" do
    test "adds a defaulted boolean without rewriting the table" do
      seed!(10)
      before = filenode()

      Backfill.add_flag_column!(TestRepo, @relation)

      # The §6.4 claim, checked rather than trusted: a *constant* default is a
      # catalog-only change on PG 11+, so the ACCESS EXCLUSIVE lock is held for
      # microseconds. A volatile default (gen_random_uuid()) rewrites the whole
      # table under that same lock, which on a 40M-row table is an outage.
      assert filenode() == before
      assert flags() == %{true => 10}
    end

    test "re-running it does not un-finish rows that are already done" do
      seed!(4)
      Backfill.add_flag_column!(TestRepo, @relation)
      {:ok, _} = Backfill.run(TestRepo, increment_config([]))

      Backfill.add_flag_column!(TestRepo, @relation)

      # The whole reason for `ADD COLUMN IF NOT EXISTS` rather than the more
      # obvious DROP-then-ADD: this assertion is the difference between an
      # idempotent setup step and one that silently restarts a day-long
      # backfill from zero.
      assert flags() == %{false => 4}
    end

    test "rejects a relation that is not a plain identifier" do
      assert_raise ArgumentError, ~r/plain SQL identifier/, fn ->
        Backfill.add_flag_column!(TestRepo, ~s(widgets"; DROP TABLE widgets; --))
      end
    end
  end

  describe "drop_flag_column!/3" do
    test "removes the column and is safe to repeat" do
      seed!(2)
      Backfill.add_flag_column!(TestRepo, @relation)

      Backfill.drop_flag_column!(TestRepo, @relation)
      Backfill.drop_flag_column!(TestRepo, @relation)

      assert columns() == ["id", "tenant_id", "counter"]
    end
  end

  describe "run/2" do
    test "updates every row exactly once, in batches" do
      seed!(10)
      Backfill.add_flag_column!(TestRepo, @relation)

      {:ok, result} = Backfill.run(TestRepo, increment_config(batch_size: 3))

      assert result.rows == 10
      assert result.batches == 4
      assert result.passes == 1
      assert result.complete? == true
      assert counters() == %{1 => 10}
      assert flags() == %{false => 10}
      assert Backfill.pending_count(TestRepo, @relation) == 0
    end

    test "a second run does nothing at all" do
      seed!(5)
      Backfill.add_flag_column!(TestRepo, @relation)
      {:ok, _} = Backfill.run(TestRepo, increment_config([]))

      {:ok, second} = Backfill.run(TestRepo, increment_config([]))

      assert second.rows == 0
      assert second.batches == 0
      assert counters() == %{1 => 5}
    end

    test "terminates when the correct value of the target column is NULL" do
      # The pgroll finding, executable. `unmapped [...], as: :null` guarantees
      # this shape exists: the backfill's job is to write NULL. With the
      # tempting `AND tenant_id IS NULL` predicate every row stays eligible
      # forever and this call never returns -- so `max_batches` is here purely
      # to turn a hang into a failure.
      seed!(6)
      Backfill.add_flag_column!(TestRepo, @relation)

      {:ok, result} =
        Backfill.run(TestRepo,
          relation: @relation,
          key: "id",
          set: [tenant_id: "NULL"],
          batch_size: 2,
          max_batches: 20
        )

      assert result.complete? == true
      assert result.batches == 3
      assert tenant_ids() == [nil]
      assert flags() == %{false => 6}
    end

    test "is resumable, and resuming does not re-process finished rows" do
      seed!(9)
      Backfill.add_flag_column!(TestRepo, @relation)

      # Interrupt from inside the progress callback, which runs between
      # committed batches -- the same place a deploy, an OOM kill or a lost
      # connection would land.
      interrupt = fn done, _total -> if done >= 3, do: throw(:killed) end

      assert catch_throw(Backfill.run(TestRepo, increment_config(progress: interrupt))) == :killed
      assert Backfill.pending_count(TestRepo, @relation) == 6

      {:ok, result} = Backfill.run(TestRepo, increment_config([]))

      assert result.rows == 6

      # The load-bearing assertion. `counter` was incremented, not set, so a
      # row processed twice reads 2 -- which no count of rows or batches would
      # ever reveal.
      assert counters() == %{1 => 9}
    end

    test "max_batches stops early and reports the run as incomplete" do
      seed!(10)
      Backfill.add_flag_column!(TestRepo, @relation)

      {:ok, first} = Backfill.run(TestRepo, increment_config(batch_size: 3, max_batches: 2))

      assert first.rows == 6
      assert first.complete? == false
      assert Backfill.pending_count(TestRepo, @relation) == 4

      {:ok, second} = Backfill.run(TestRepo, increment_config(batch_size: 3))

      assert second.complete? == true
      assert counters() == %{1 => 10}
    end

    test "catches a row inserted below the cursor after the cursor passed it" do
      # `bigserial` hands out values in order but transactions commit out of
      # order, so a row with a *lower* id than the cursor can appear after the
      # batch that would have covered it. A keyset backfill with a single pass
      # skips it silently and forever; this is the sweep that stops that.
      #
      # The progress callback is the injection point: it runs between committed
      # batches, so the insert lands exactly in the window that matters.
      seed!(6)
      Backfill.add_flag_column!(TestRepo, @relation)

      inserts = :counters.new(1, [])

      late_insert = fn _done, _total ->
        if :counters.get(inserts, 1) == 0 do
          :counters.add(inserts, 1, 1)

          TestRepo.query!(
            """
            INSERT INTO backfill_test.widgets (id, counter)
            VALUES ((SELECT min(id) - 1 FROM backfill_test.widgets), 0)
            """,
            []
          )
        end
      end

      {:ok, result} =
        Backfill.run(TestRepo, increment_config(batch_size: 2, progress: late_insert))

      assert :counters.get(inserts, 1) == 1
      assert result.passes == 2
      assert Backfill.pending_count(TestRepo, @relation) == 0
      assert counters() == %{1 => 7}
    end

    test "refuses to spin when something re-flags the rows it just finished" do
      # The realistic version of "this never terminates": a trigger on the
      # legacy table that fires on the backfill's own UPDATE and puts the flag
      # back. Every pass then does real work, updates real rows and reports
      # real progress -- nothing in the counters ever looks wrong, and the job
      # simply never ends. A backfill that hangs is indistinguishable from one
      # that is merely slow, which is why this raises instead.
      seed!(4)
      Backfill.add_flag_column!(TestRepo, @relation)

      TestRepo.query!(
        """
        CREATE FUNCTION backfill_test.reflag() RETURNS trigger AS $$
        BEGIN
          NEW."#{Backfill.flag_column()}" := true;
          RETURN NEW;
        END $$ LANGUAGE plpgsql
        """,
        []
      )

      TestRepo.query!(
        """
        CREATE TRIGGER reflag BEFORE UPDATE ON backfill_test.widgets
          FOR EACH ROW EXECUTE FUNCTION backfill_test.reflag()
        """,
        []
      )

      assert_raise RuntimeError, ~r/started a second pass at key 1/, fn ->
        Backfill.run(TestRepo, increment_config(batch_size: 2))
      end
    end

    test "reports progress against a total, falling back to count(*) with no statistics" do
      seed!(4)
      Backfill.add_flag_column!(TestRepo, @relation)

      test_pid = self()
      progress = fn done, total -> send(test_pid, {:progress, done, total}) end

      {:ok, result} = Backfill.run(TestRepo, increment_config(batch_size: 2, progress: progress))

      # Surprising until you look: `n_live_tup` is 0 on a table autovacuum has
      # never visited, which is the exact state of the freshly-loaded table a
      # backfill runs against. Reporting `2/0` would be worse than useless, so 0
      # means "no statistics" and falls back to the exact count.
      assert result.total == 4
      assert_received {:progress, 2, 4}
      assert_received {:progress, 4, 4}
    end
  end

  describe "the batch statement" do
    test "takes FOR NO KEY UPDATE and never uses OFFSET" do
      seed!(4)
      Backfill.add_flag_column!(TestRepo, @relation)

      queries = capture_queries(fn -> Backfill.run(TestRepo, increment_config(batch_size: 2)) end)

      batch = Enum.find(queries, &String.contains?(&1, "strangler_batch"))
      assert batch

      # FOR UPDATE would also block concurrent foreign-key checks against these
      # rows; the backfill is not touching the key, so it has no business doing
      # that to a busy child table.
      assert batch =~ "FOR NO KEY UPDATE"
      refute batch =~ ~r/FOR UPDATE/

      # OFFSET makes each batch re-walk and discard everything before it, so
      # cost is quadratic and the last batches are the slowest -- and the
      # ordering it depends on is being mutated by the backfill itself.
      refute Enum.any?(queries, &(&1 =~ ~r/\bOFFSET\b/i))
    end
  end

  describe "with_lock_retry/3" do
    test "retries SQLSTATE 55P03 and succeeds on a later attempt" do
      counter = :counters.new(1, [])

      result =
        Backfill.with_lock_retry(TestRepo, [lock_retries: 5, backoff: fn _ -> 0 end], fn ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) < 3 do
            raise lock_error()
          end

          :done
        end)

      assert result == :done
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry any other error" do
      counter = :counters.new(1, [])

      assert_raise Postgrex.Error, fn ->
        Backfill.with_lock_retry(TestRepo, [lock_retries: 5, backoff: fn _ -> 0 end], fn ->
          :counters.add(counter, 1, 1)

          raise %Postgrex.Error{
            postgres: %{
              code: :undefined_column,
              message: "no such column",
              severity: "ERROR",
              pg_code: "42703"
            }
          }
        end)
      end

      # Retrying a syntax error or a missing column spends the whole backoff
      # budget arriving at the same failure, and hides the real error behind
      # the delay.
      assert :counters.get(counter, 1) == 1
    end

    test "gives up after the configured number of retries and re-raises" do
      counter = :counters.new(1, [])

      assert_raise Postgrex.Error, fn ->
        Backfill.with_lock_retry(TestRepo, [lock_retries: 2, backoff: fn _ -> 0 end], fn ->
          :counters.add(counter, 1, 1)
          raise lock_error()
        end)
      end

      assert :counters.get(counter, 1) == 3
    end

    test "rejects a lock timeout that is not an integer" do
      # `SET` takes no bind parameters, so the timeout is interpolated. An
      # integer is the type that cannot carry SQL.
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Backfill.with_lock_retry(TestRepo, [lock_timeout: "5s"], fn -> :never end)
      end
    end

    test "really does time out and really does retry against a locked table" do
      # The end-to-end version of the three tests above: a second, non-sandbox
      # connection holds ACCESS EXCLUSIVE, so the DDL cannot proceed and every
      # attempt has to reach Postgres and come back 55P03.
      #
      # This is also the only place that proves each attempt gets its own
      # transaction. If they shared one, attempt two would fail instantly with
      # 25P02 (current transaction is aborted) instead of 55P03 -- the retry
      # loop would appear to work while never retrying anything, and the
      # elapsed-time assertion below is what catches that.
      conn = outside_connection()
      Postgrex.query!(conn, "DROP TABLE IF EXISTS strangler_lock_probe", [])
      Postgrex.query!(conn, "CREATE TABLE strangler_lock_probe (id bigint)", [])
      on_exit(fn -> drop_lock_probe() end)

      {elapsed, error} =
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "LOCK TABLE strangler_lock_probe IN ACCESS EXCLUSIVE MODE", [])

          :timer.tc(fn ->
            assert_raise Postgrex.Error, fn ->
              Backfill.add_flag_column!(TestRepo, "strangler_lock_probe",
                lock_timeout: 100,
                lock_retries: 2,
                backoff: fn _ -> 0 end
              )
            end
          end)
        end)
        |> then(fn {:ok, {elapsed, error}} -> {elapsed, error} end)

      assert %Postgrex.Error{postgres: %{code: :lock_not_available}} = error

      # Three attempts (initial + 2 retries), each waiting out the 100ms
      # lock_timeout. Anything much under 300ms means attempts are failing for
      # some cheaper reason than the lock.
      assert elapsed >= 250_000
    end
  end

  describe "plan/2: the backfill comes out of the mapping it is backfilling" do
    test "the relation and the key are read off the twin and the key entity" do
      plan = Backfill.plan(LegacyUser)

      assert plan[:relation] == "legacy.users"
      assert plan[:key] == "id"
    end

    test "a constant with no legacy column to live in produces no work" do
      # `organization_id` has no column in `legacy.users`, which is the ordinary
      # meaning of `constant`: the view manufactures the value and nothing stores
      # it. So the plan is honest about having nothing to do, rather than
      # inventing a column for a value that has no home.
      assert Backfill.plan(LegacyUser)[:set] == []
    end

    test "a constant whose column the twin declares is materialised into it" do
      # The transitional state of an expand step -- see
      # `AshStrangler.BackfillTest.ExpandedUser`. The twin is the record of which
      # columns the legacy table actually has, so it is the thing asked.
      assert Backfill.plan(ExpandedUser)[:set] == [{"salt", "'fixed-by-backfill'"}]
    end

    test "store_key stores the view's own key expression, not a fourth copy of it" do
      [{"row_uuid", expression}] = Backfill.plan(LegacyUser, store_key: :row_uuid)[:set]

      %{view: %{up: view_sql}, key_index: %{up: index_sql}} =
        AshStrangler.Sql.View.build(LegacyUser)

      # The view's SELECT, the expression index and this UPDATE have to agree
      # byte for byte. A difference as small as whitespace makes Postgres decline
      # to use the index, silently, with a sequential scan as the only symptom;
      # a difference in the *value* means the ids the new application has been
      # reading for weeks are not the ids the backfill stored, and that surfaces
      # only at cutover.
      assert String.contains?(view_sql, expression)
      assert String.contains?(index_sql, expression)
    end

    test ":identity refuses store_key, because there is nothing to derive a value from" do
      # `:identity` means the legacy table already holds the modern key. What
      # those uuids should be is a choice no mapping states, so deriving one
      # would be inventing it.
      assert_raise ArgumentError, ~r/the key strategy is `:identity`/, fn ->
        Backfill.plan(AshStrangler.BackfillTest.IdentityKeyedUser, store_key: :salt)
      end
    end

    test "an explicit set entry replaces the derived one rather than joining it" do
      # Two assignments to one column is a hard error from PostgreSQL, so which
      # one wins is not a matter of preference.
      plan =
        Backfill.plan(LegacyUser, store_key: :row_uuid, set: [row_uuid: "gen_random_uuid()"])

      assert plan[:set] == [row_uuid: "gen_random_uuid()"]
    end

    test "run/2 options pass straight through" do
      plan = Backfill.plan(LegacyUser, batch_size: 250, max_batches: 4, progress: nil)

      assert plan[:batch_size] == 250
      assert plan[:max_batches] == 4
    end

    test "a resource with no strangler mapping says so, and says what to do instead" do
      assert_raise ArgumentError, ~r/has no strangler `source`/, fn ->
        Backfill.plan(AshStrangler.DiagramTest.Plain)
      end
    end
  end

  describe "run/2 with a derived plan" do
    setup do
      # The expand step, as DDL: a column the legacy schema never had. Inside the
      # test's own sandbox transaction, so it rolls back with the rows.
      TestRepo.query!("ALTER TABLE legacy.users ADD COLUMN row_uuid uuid", [])

      ids = Enum.map(1..3, fn _ -> insert_legacy_user!() end)
      Backfill.add_flag_column!(TestRepo, "legacy.users")

      %{ids: ids}
    end

    test "stores exactly the uuid the derivation computes in Elixir", %{ids: ids} do
      {:ok, result} =
        Backfill.run(TestRepo, Backfill.plan(LegacyUser, store_key: :row_uuid, batch_size: 2))

      assert result.complete?
      assert result.rows == 3

      # `derived_id/1` computes the uuid in Elixir, so this is not Postgres being
      # compared against Postgres. It is the independent side of the agreement
      # the key derivation has to hold on, and the reason the backfill must not
      # carry its own spelling of the expression.
      for legacy_id <- ids do
        assert stored_uuid(legacy_id) == derived_id(legacy_id)
      end
    end

    test "and therefore the value the view has been serving all along", %{ids: ids} do
      {:ok, _} = Backfill.run(TestRepo, Backfill.plan(LegacyUser, store_key: :row_uuid))

      for legacy_id <- ids do
        %Postgrex.Result{rows: [[view_id]]} =
          TestRepo.query!(
            "SELECT id::text FROM strangler.users WHERE __legacy_id = $1",
            [legacy_id]
          )

        assert stored_uuid(legacy_id) == view_id
      end
    end

    test "a derived constant is written into the legacy column the twin declares" do
      {:ok, result} = Backfill.run(TestRepo, Backfill.plan(ExpandedUser))

      assert result.rows == 3
      assert salts() == ["fixed-by-backfill"]
    end

    test "a derived plan is idempotent, which is what bounds the missing interlock" do
      # The trigger does not clear the flag, so a row a concurrent writer already
      # handled can be re-derived by a later batch. That is only harmless because
      # every expression `plan/2` produces is a function of the row -- so this
      # asserts the property the moduledoc leans on rather than leaving it as a
      # claim. `add_flag_column!` re-flags nothing, so the flags are reset by
      # hand here to force the second pass.
      plan = Backfill.plan(LegacyUser, store_key: :row_uuid)

      {:ok, _} = Backfill.run(TestRepo, plan)
      first = uuids()

      TestRepo.query!(
        ~s|UPDATE legacy.users SET "#{Backfill.flag_column()}" = true|,
        []
      )

      {:ok, second} = Backfill.run(TestRepo, plan)

      assert second.rows == 3
      assert uuids() == first
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp stored_uuid(legacy_id) do
    %Postgrex.Result{rows: [[uuid]]} =
      TestRepo.query!("SELECT row_uuid::text FROM legacy.users WHERE id = $1", [legacy_id])

    uuid
  end

  defp uuids do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!("SELECT id, row_uuid::text FROM legacy.users ORDER BY id", [])

    rows
  end

  defp salts do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!("SELECT DISTINCT salt FROM legacy.users", [])

    List.flatten(rows)
  end

  # `severity` is not decoration: `Postgrex.Error.message/1` reads it
  # unconditionally, so a hand-built error without it makes ExUnit's
  # `assert_raise` fail while *rendering* the exception rather than while
  # matching it -- which looks like the code under test is broken.
  defp lock_error do
    %Postgrex.Error{
      postgres: %{
        code: :lock_not_available,
        message: "canceling statement due to lock timeout",
        severity: "ERROR",
        pg_code: "55P03"
      }
    }
  end

  # `::regclass` in the SQL rather than as a bound parameter: Postgrex has no
  # encoder for regclass, so the cast has to happen inside the statement.
  defp filenode do
    %Postgrex.Result{rows: [[filenode]]} =
      TestRepo.query!("SELECT pg_relation_filenode('#{@relation}'::regclass)", [])

    filenode
  end

  defp columns do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'backfill_test' AND table_name = 'widgets'
        ORDER BY ordinal_position
        """,
        []
      )

    List.flatten(rows)
  end

  defp capture_queries(fun) do
    test_pid = self()
    handler = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:ash_strangler, :test_repo, :query],
      &__MODULE__.forward_query/4,
      test_pid
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain_queries([])
  end

  @doc false
  def forward_query(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:query, metadata.query})
  end

  defp drain_queries(acc) do
    receive do
      {:query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp outside_connection do
    config = TestRepo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: config[:database]
      )

    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    conn
  end

  # A separate connection, because the one that created the probe table has
  # already been stopped by the time on_exit runs.
  defp drop_lock_probe do
    config = TestRepo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: config[:database]
      )

    Postgrex.query!(conn, "DROP TABLE IF EXISTS strangler_lock_probe", [])
    GenServer.stop(conn)
  end
end
