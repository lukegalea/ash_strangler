# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Notify do
  @moduledoc """
  Builds the `AFTER` trigger that announces legacy writes over `pg_notify`.

  This sits on the **legacy base table**, not on the view: Postgres rejects
  row-level `BEFORE`/`AFTER` triggers on a view outright ("Views cannot have
  row-level BEFORE or AFTER triggers"), and a statement-level trigger on a view
  never fires at all unless a row-level `INSTEAD OF` trigger handled the
  statement. The base table is the only place this can live.

  ## The payload carries a key and nothing else

  Not an optimization — the only safe choice. `pg_notify`'s payload ceiling is
  7999 **bytes** (so UTF-8 expansion counts), and exceeding it is a hard error
  (SQLSTATE `22023`), not a truncation. That error aborts the transaction that
  issued the `NOTIFY` — which is the *legacy application's* transaction. A
  notify trigger that builds its payload from row data is therefore a latent
  outage in the old system, triggered by whoever first pastes a long enough
  value into a text field.

  `AshStrangler.Listener` re-reads through Ash anyway, which is what makes the
  resulting notification indistinguishable from an Ash-originated one.

  ## What this cannot promise

  `NOTIFY` is at-most-once and in-memory. It does not fire on rollback (correct,
  and what you want), it is discarded by savepoint rollback (so it is safe
  inside an `Ecto.Multi`), a disconnected listener misses everything sent while
  it was away, and nothing survives a restart. Postgres also **collapses
  duplicate `(channel, payload)` pairs within one transaction**, so a row
  updated twice in one transaction produces one event — meaning this can never
  be used to count writes.

  Fine for cache invalidation and LiveView reactivity. Unacceptable as an audit
  trail; that needs a synchronous trigger writing to a table, which couples the
  legacy application's availability to that table's health.
  """

  alias AshStrangler.{Info, Key, Source}

  @doc """
  Builds the notify function and trigger for `resource_or_dsl`.

  Returns `[]` unless the source opted in with `notify? true` — notifications
  cost the legacy application a `pg_notify` on every write, so they are not
  imposed by default.
  """
  def build(resource_or_dsl) do
    case AshStrangler.Info.source(resource_or_dsl) do
      %Source{notify?: true, keys: [%Key{} = key]} ->
        do_build(resource_or_dsl, key)

      _ ->
        []
    end
  end

  defp do_build(resource_or_dsl, key) do
    relation = Info.relation(resource_or_dsl)
    table = AshPostgres.DataLayer.Info.table(resource_or_dsl)
    schema = AshPostgres.DataLayer.Info.schema(resource_or_dsl) || "public"
    channel = AshStrangler.Info.notify_channel(resource_or_dsl)

    function = ~s("#{schema}"."strangler_#{table}_notify")
    trigger = ~s("strangler_#{table}_notify")

    # The resource module name is baked in so the listener knows what was
    # written without a lookup table keyed on relation names. `inspect/1` would
    # give the "Elixir."-less form; the atom's real text is what
    # `String.to_existing_atom/1` needs on the way back.
    resource_name = Atom.to_string(resource_module(resource_or_dsl))

    function_up = """
    CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $strangler$
    DECLARE
      affected record;
    BEGIN
      affected := COALESCE(NEW, OLD);

      -- Key only. See the moduledoc: a payload built from row data can exceed
      -- the 7999-byte ceiling and abort the LEGACY application's transaction.
      PERFORM pg_notify('#{channel}', json_build_object(
        'resource', '#{resource_name}',
        'legacy_id', affected.#{key.from},
        'op', lower(TG_OP)
      )::text);

      -- The return value of an AFTER row trigger is ignored.
      RETURN NULL;
    END $strangler$ LANGUAGE plpgsql;
    """

    trigger_up = """
    CREATE OR REPLACE TRIGGER #{trigger}
      AFTER INSERT OR UPDATE OR DELETE ON #{relation}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    """

    [
      %{
        name: :"strangler_#{table}_notify_function",
        up: function_up,
        down: "DROP FUNCTION IF EXISTS #{function}() CASCADE;"
      },
      %{
        name: :"strangler_#{table}_notify_trigger",
        up: trigger_up,
        # Unlike the INSTEAD OF triggers, this one lives on the legacy table,
        # which this package does not own and must not assume still exists.
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

  defp resource_module(resource) when is_atom(resource), do: resource

  defp resource_module(dsl), do: Spark.Dsl.Transformer.get_persisted(dsl, :module)
end
