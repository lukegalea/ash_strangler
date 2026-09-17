# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Ledger do
  @moduledoc """
  Builds the durable change ledger: a `legacy_change_events` table, an
  `AFTER` row trigger on the legacy relation that writes one event per write
  inside the legacy transaction, and the `wake:<event id>` `pg_notify` that
  tells a drain worker to come and get it.

  `notify?` alone is at-most-once: a listener that is down misses every write
  sent while it was down, and there is nothing to recover from. The ledger
  flips the guarantee. The event row commits **with** the legacy write or not
  at all, and the drain re-reads whatever is unprocessed — so the contract
  becomes at-least-once, and the wake becomes a promptness optimisation rather
  than the delivery mechanism. The periodic sweep is the recovery net for the
  wakes that were missed.

  That guarantee is bought with the trade every synchronous audit trigger
  makes: the legacy application's transaction now inserts into this table, so
  the old system's write path depends on the ledger's health. That is a real
  coupling and the reason `ledger?` is opt-in beside `notify?`, not a
  consequence of it.

  ## One trigger, not two

  With `ledger?: true` this module emits the *only* trigger: the same function
  writes the event row and then issues the `pg_notify`, whose payload becomes
  `wake:<event id>` instead of the JSON envelope `AshStrangler.Sql.Notify`
  builds on its own. `AshStrangler.Sql.Notify.build/1` returns `[]` for a
  ledger resource, so a legacy write pays one trigger, not two, and there is
  one place to read to know what a write announces.

  The wake payload replaces the envelope rather than extending it, and that is
  deliberate: the payload stays a fixed handful of bytes (the 7999-byte
  `pg_notify` ceiling aborts the *legacy* transaction when exceeded, so a
  payload that grows with row data is a latent outage in the old system), and
  the consumer of a ledger write is the **drain**, which re-reads the durable
  event and performs ordinary Ash actions — which fire Ash's own notifiers
  downstream. Downstream consumers cannot tell where the change came from
  either way; they just hear about it one hop later, and cannot lose it.

  The wake is sent **after** the insert, from the same function, so it is
  transactional with the event: a rolled-back legacy write announces nothing
  (correct — there is nothing to drain), and a committed one always has a row
  behind its wake.

  ## One ledger table, by construction

  The table is named `legacy_change_events`, once, and every relation's events
  land in it — `source_schema`/`source_table` name where a row came from.
  Nobody names the table per resource: resources mapping the same legacy
  relation share one table and one trigger function because the function and
  trigger names are pure functions of `schema.table`, so two resources over
  one twin emit byte-identical DDL and a migration deduplicates it.

  The table is **infrastructure, not a resource**. This package ships no Ash
  resource over it, on purpose: the drain is host code that owns the
  read-and-act policy, and putting the ledger behind a resource would invite
  querying it as domain data when its only job is to be drained. A host that
  does want to query it can wrap it — the schema is plain and stable.

  One consequence of that derivation deserves stating: the function and
  trigger names come from the *relation*, so two resources sharing a twin must
  also share a `notify_channel`. With two channels, both migrations are
  emitted (their SQL differs), the trigger names collide, and the later
  migration silently wins. One relation, one channel — the wakes carry only an
  event id, so every drain hears them all anyway.

  ## What the trigger fills, and what it leaves

  The trigger fills what only the database knows: `source_schema`,
  `source_table`, `operation`, `primary_key` (the mapped key column, as
  jsonb), `old_row`/`new_row` (`to_jsonb(OLD)`/`to_jsonb(NEW)`),
  `changed_columns` (per-key jsonb comparison — an UPDATE that writes a column
  back with its current value counts as changed, which is the honest reading:
  PostgreSQL cannot distinguish it from a write, and neither can this), and
  `transaction_id`/`transaction_timestamp`.

  `transaction_id` is `txid_current()`. The package's Postgres floor is 14,
  where both `txid_current()` and `pg_current_xact_id()` exist; `txid_current()`
  returns `bigint` directly, which is the column's type, and needs no
  `::text::bigint` detour. Every event a legacy transaction writes shares one
  id, which is what makes a multi-row legacy transaction reconstructable.

  `source_system`, `source_user`, `source_request_id`,
  `source_correlation_id` and `actor_confidence` are left NULL by the trigger.
  They are attribution slots for the drain and for whatever supplementary
  capture a legacy application can provide; a generic trigger cannot know who
  the old application's user was, and inventing a value would be worse than
  admitting there is none.

  ## One SQL command per statement, necessarily

  As everywhere in this package: an Ecto migration's `execute/1` runs on the
  extended protocol, which rejects multiple commands with 42601. The plpgsql
  body's semicolons are inside a dollar-quoted string — one command, as far as
  the parser is concerned.
  """

  alias AshStrangler.{Info, Key, Source}

  @events_table ~s("public"."legacy_change_events")

  @doc """
  The qualified name of the ledger table every relation's events land in.

  One definition, read by the migration that creates it, the check task that
  counts its backlog and the generated drain worker that empties it — a table
  name spelled twice is a migration that creates one and a drain that empties
  nothing.
  """
  @spec events_table() :: String.t()
  def events_table, do: @events_table

  @doc """
  Builds the ledger table, index, function and trigger for `resource_or_dsl`.

  Returns `[]` unless the source opted in with `ledger? true` — the trigger
  inserts into the legacy application's transaction on every write, so it is
  not imposed by default. When set, the notify statements are *replaced*, not
  joined: see "One trigger, not two" in the moduledoc.
  """
  def build(resource_or_dsl) do
    case AshStrangler.Info.source(resource_or_dsl) do
      %Source{ledger?: true, keys: [%Key{} = key]} ->
        do_build(resource_or_dsl, key)

      _ ->
        []
    end
  end

  defp do_build(resource_or_dsl, key) do
    relation = Info.relation(resource_or_dsl)
    {schema, table} = split_relation(relation)
    channel = Info.notify_channel(resource_or_dsl)
    key_column = Atom.to_string(key.from)

    function = ~s("public"."strangler_ledger_#{schema}_#{table}")
    trigger = ~s("strangler_ledger_#{schema}_#{table}")

    [
      %{
        name: :strangler_ledger_events_table,
        up: table_up(),
        down: "DROP TABLE IF EXISTS #{@events_table};"
      },
      %{
        name: :strangler_ledger_events_index,
        up: index_up(),
        down: "DROP INDEX IF EXISTS \"public\".\"legacy_change_events_unprocessed_idx\";"
      },
      %{
        name: :"strangler_ledger_#{schema}_#{table}_function",
        up: function_up(schema, table, channel, key_column),
        # Functions drop CASCADE so a trigger that outlived its function by a
        # rollback cannot block the drop.
        down: "DROP FUNCTION IF EXISTS #{function}() CASCADE;"
      },
      %{
        name: :"strangler_ledger_#{schema}_#{table}_trigger",
        up: trigger_up(relation, trigger, function),
        # Like the notify trigger, this lives on a relation this package does
        # not own and must not assume still exists.
        down: """
        DO $strangler$
        BEGIN
          IF to_regclass('#{relation}') IS NOT NULL THEN
            EXECUTE 'DROP TRIGGER IF EXISTS #{trigger} ON #{relation}';
          END IF;
        END $strangler$;
        """
      }
    ]
  end

  defp table_up do
    """
    CREATE TABLE IF NOT EXISTS #{@events_table} (
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
  end

  # Partial on purpose: the drain's whole world is `WHERE processed_at IS
  # NULL`, and processed rows drop out of the index instead of accumulating in
  # it forever.
  defp index_up do
    """
    CREATE INDEX IF NOT EXISTS legacy_change_events_unprocessed_idx
      ON #{@events_table} (processed_at)
      WHERE processed_at IS NULL
    """
  end

  defp function_up(schema, table, channel, key_column) do
    """
    CREATE OR REPLACE FUNCTION "public"."strangler_ledger_#{schema}_#{table}"() RETURNS trigger AS $strangler$
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
      INSERT INTO #{@events_table}
        (source_schema, source_table, operation, primary_key, old_row, new_row,
         changed_columns, transaction_id, transaction_timestamp)
      VALUES
        (TG_TABLE_SCHEMA, TG_TABLE_NAME, lower(TG_OP),
         jsonb_build_object('#{key_column}', affected.#{key_column}),
         old_row, new_row, changed,
         txid_current(), transaction_timestamp())
      RETURNING id INTO event_id;

      -- The wake, key-only. The event id is a bigint, so the payload is a
      -- handful of bytes no matter how wide the row is -- the 7999-byte
      -- pg_notify ceiling aborts the LEGACY application's transaction, and a
      -- drain re-reads the durable row anyway.
      PERFORM pg_notify('#{channel}', 'wake:' || event_id);

      -- The return value of an AFTER row trigger is ignored.
      RETURN NULL;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  defp trigger_up(relation, trigger, function) do
    """
    CREATE OR REPLACE TRIGGER #{trigger}
      AFTER INSERT OR UPDATE OR DELETE ON #{relation}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    """
  end

  defp split_relation(relation) do
    case String.split(relation, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end
end
