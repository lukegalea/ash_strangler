# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.LedgerTestRepo do
  @moduledoc """
  Compile-only Ecto repo for `AshStrangler.Sql.LedgerTest`, on the same terms
  as `AshStrangler.Sql.ViewTestRepo`: the DSL requires a `postgres do repo
  end` to exist, and no test here starts it or touches a database.
  """
  use AshPostgres.Repo, otp_app: :ash_strangler, warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule AshStrangler.Sql.LedgerTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Sql.LedgerTest.Legacy.Users
  end
end

defmodule AshStrangler.Sql.LedgerTest.Legacy.Users do
  @moduledoc "The twin every fixture in this file maps onto."
  use Ash.Resource,
    domain: AshStrangler.Sql.LedgerTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "users"
    schema "legacy"
    repo AshStrangler.Sql.LedgerTestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :login, :string
    attribute :email, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Sql.LedgerTest.LedgeredUser do
  @moduledoc "The golden-SQL fixture: `ledger?` on, with its own wake channel."

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "users"
    schema "strangler"
    repo AshStrangler.Sql.LedgerTestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Sql.LedgerTest.Legacy.Users do
      notify? true
      ledger?(true)
      notify_channel "ledger_test_channel"

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :login, from: :login
      map :email, from: :email
    end
  end
end

defmodule AshStrangler.Sql.LedgerTest.AlsoLedgeredUser do
  @moduledoc """
  A second resource over the SAME twin -- the case the "one ledger per
  relation" invariant rests on. Its ledger DDL must be byte-identical to the
  first fixture's, because the table, function and trigger names are pure
  functions of `schema.table` and nothing else.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "also_ledgered"
    schema "strangler"
    repo AshStrangler.Sql.LedgerTestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Sql.LedgerTest.Legacy.Users do
      notify? true
      ledger?(true)
      notify_channel "ledger_test_channel"

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :login, from: :login
    end
  end
end

defmodule AshStrangler.Sql.LedgerTest.NotifyOnlyUser do
  @moduledoc "Did not opt into the ledger; `Notify` must keep serving it."

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "notify_only"
    schema "strangler"
    repo AshStrangler.Sql.LedgerTestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Sql.LedgerTest.Legacy.Users do
      notify? true

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :login, from: :login
    end
  end
end

defmodule AshStrangler.Sql.LedgerTest do
  @moduledoc """
  Golden-SQL tests for the change ledger -- no database, no live connection,
  the same discipline as `AshStrangler.Sql.ViewTest`: DSL in, SQL out, checked
  as a fixture.

  What these assert that the verifier cannot: that the DDL is what it claims
  to be. The trigger's insert must sit before the wake in the same function;
  the payload must be `wake:<id>` and nothing bigger; the names must derive
  from `schema.table` alone, which is what makes one ledger table per relation
  hold by construction rather than by convention.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.Sql.{Ledger, Notify}
  alias AshStrangler.Sql.LedgerTest.{AlsoLedgeredUser, LedgeredUser, NotifyOnlyUser}

  @table ~s("public"."legacy_change_events")

  describe "build/1" do
    test "emits nothing for a resource that did not opt in" do
      # Off by default, like `notify?`: the trigger inserts into the legacy
      # application's transaction on every write, and that cost is a decision
      # for the mapping's author, not a package default.
      assert Ledger.build(NotifyOnlyUser) == []
    end

    test "emits table, index, function and trigger, in dependency order" do
      names = LedgeredUser |> Ledger.build() |> Enum.map(& &1.name)

      assert names == [
               :strangler_ledger_events_table,
               :strangler_ledger_events_index,
               :strangler_ledger_legacy_users_function,
               :strangler_ledger_legacy_users_trigger
             ]
    end

    test "replaces the notify statements rather than joining them" do
      # A second trigger would double every legacy write's pg_notify while
      # announcing the same fact twice. One write, one trigger, one notify.
      assert Notify.build(LedgeredUser) == []

      assert [
               %{name: :strangler_notify_only_notify_function},
               %{name: :strangler_notify_only_notify_trigger}
             ] =
               Notify.build(NotifyOnlyUser)
    end
  end

  describe "the table" do
    setup do
      [_table, _index, _function, trigger] = statements = Ledger.build(LedgeredUser)

      {:ok, statements: statements, trigger: trigger}
    end

    test "carries every column the drain and the audit read", %{statements: [table | _]} do
      assert table.up == """
             CREATE TABLE IF NOT EXISTS #{@table} (
               id bigserial PRIMARY KEY,
               source_system text,
               source_schema text NOT NULL,
               source_table text NOT NULL,
               operation text NOT NULL,
               primary_key jsonb NOT NULL,
               old_row jsonb,
               new_row jsonb,
               changed_columns jsonb,
               transaction_id bigint,
               transaction_timestamp timestamptz,
               source_user text,
               source_request_id text,
               source_correlation_id text,
               actor_confidence text,
               emitted_at timestamptz NOT NULL DEFAULT now(),
               processed_at timestamptz
             )
             """

      assert table.down == "DROP TABLE IF EXISTS #{@table};"
    end

    test "is one SQL command, as the extended protocol demands", %{statements: [table, index | _]} do
      for statement <- [table, index] do
        refute statement.up |> String.trim_trailing() |> String.trim_trailing(";") =~ ";"
      end
    end

    test "the index is partial on unprocessed rows", %{statements: [_table, index | _]} do
      # The drain's whole world is `WHERE processed_at IS NULL`, so processed
      # rows drop out of the index instead of accumulating in it forever.
      assert index.up == """
             CREATE INDEX IF NOT EXISTS legacy_change_events_unprocessed_idx
               ON #{@table} (processed_at)
               WHERE processed_at IS NULL
             """

      assert index.down ==
               "DROP INDEX IF EXISTS \"public\".\"legacy_change_events_unprocessed_idx\";"
    end

    test "the function writes the event and wakes the drain, transactionally", %{
      statements: [_table, _index, function | _]
    } do
      assert function.up == """
             CREATE OR REPLACE FUNCTION "public"."strangler_ledger_legacy_users"() RETURNS trigger AS $strangler$
             DECLARE
               event_id bigint;
               affected record;
               old_row jsonb;
               new_row jsonb;
               changed jsonb;
             BEGIN
               affected := COALESCE(NEW, OLD);

               IF (TG_OP = 'DELETE') THEN
                 old_row := to_jsonb(OLD);
                 new_row := NULL;
                 changed := NULL;
               ELSIF (TG_OP = 'INSERT') THEN
                 old_row := NULL;
                 new_row := to_jsonb(NEW);
                 changed := new_row;
               ELSE
                 old_row := to_jsonb(OLD);
                 new_row := to_jsonb(NEW);
                 changed := (
                   SELECT COALESCE(jsonb_object_agg(pair.key, pair.value), '{}'::jsonb)
                     FROM jsonb_each(new_row) AS pair
                    WHERE (old_row -> pair.key) IS DISTINCT FROM pair.value
                 );
               END IF;

               -- Committed WITH the legacy write or not at all: that is the whole
               -- guarantee the ledger exists for, and it is why this is a synchronous
               -- insert rather than a queue.
               INSERT INTO #{@table}
                 (source_schema, source_table, operation, primary_key, old_row, new_row,
                  changed_columns, transaction_id, transaction_timestamp)
               VALUES
                 (TG_TABLE_SCHEMA, TG_TABLE_NAME, lower(TG_OP),
                  jsonb_build_object('id', affected.id),
                  old_row, new_row, changed,
                  txid_current(), transaction_timestamp())
               RETURNING id INTO event_id;

               -- The wake, key-only. The event id is a bigint, so the payload is a
               -- handful of bytes no matter how wide the row is -- the 7999-byte
               -- pg_notify ceiling aborts the LEGACY application's transaction, and a
               -- drain re-reads the durable row anyway.
               PERFORM pg_notify('ledger_test_channel', 'wake:' || event_id);

               -- The return value of an AFTER row trigger is ignored.
               RETURN NULL;
             END $strangler$ LANGUAGE plpgsql;
             """

      assert function.down ==
               "DROP FUNCTION IF EXISTS \"public\".\"strangler_ledger_legacy_users\"() CASCADE;"
    end

    test "the trigger attaches to the relation the twin names", %{trigger: trigger} do
      assert trigger.up == """
             CREATE OR REPLACE TRIGGER "strangler_ledger_legacy_users"
               AFTER INSERT OR UPDATE OR DELETE ON legacy.users
               FOR EACH ROW EXECUTE FUNCTION "public"."strangler_ledger_legacy_users"();
             """

      # The legacy table is not ours to assume still exists.
      assert trigger.down =~ "to_regclass('legacy.users')"
      assert trigger.down =~ "DROP TRIGGER IF EXISTS"
    end
  end

  describe "one ledger table per relation, by construction" do
    test "two resources over one twin emit byte-identical ledger DDL" do
      # The verifier cannot check this -- a Spark verifier sees one resource's
      # DSL, and the second resource compiles in a module the first never
      # sees. It holds because the names derive from schema.table alone, and
      # this is the test that says so.
      ours = Ledger.build(LedgeredUser)
      theirs = Ledger.build(AlsoLedgeredUser)

      assert Enum.map(ours, & &1.up) == Enum.map(theirs, & &1.up)
      assert Enum.map(ours, & &1.down) == Enum.map(theirs, & &1.down)
    end

    test "a migration covering both resources emits the ledger DDL once" do
      source =
        AshStrangler.Migration.render("Elixir.LedgerRenderTest", [LedgeredUser, AlsoLedgeredUser])

      # One CREATE TABLE, one index, one function, one trigger -- render
      # deduplicates byte-identical statements, and byte-identical is what the
      # derivation guarantees.
      assert source |> String.split("CREATE TABLE IF NOT EXISTS") |> length() == 2

      assert source
             |> String.split("CREATE OR REPLACE TRIGGER \"strangler_ledger_legacy_users\"")
             |> length() == 2
    end
  end

  describe "Migration.statements/1 composition" do
    test "the ledger statements flow through, and the notify ones do not" do
      names = LedgeredUser |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      assert :strangler_ledger_events_table in names
      assert :strangler_ledger_legacy_users_function in names
      refute :strangler_legacy_users_notify_function in names
      refute :strangler_legacy_users_notify_trigger in names
    end

    test "the table statement precedes the trigger that inserts into it" do
      names = LedgeredUser |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      assert names |> Enum.find_index(&(&1 == :strangler_ledger_events_table)) <
               names |> Enum.find_index(&(&1 == :strangler_ledger_legacy_users_trigger))
    end
  end
end
