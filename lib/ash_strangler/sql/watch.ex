# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Watch do
  @moduledoc """
  Builds the notify-only trigger for a watched twin (`twin do watch "channel"
  end`).

  Some legacy relations matter without being mapped: a membership table whose
  rows decide who sees what, a permission table a host folds into a cached
  context. Nothing reads them through a strangled resource, so neither
  `AshStrangler.Sql.Notify` nor the ledger applies, but a host still needs to
  hear that they changed.

  A watch is the smallest thing that does that:

    * **notify only.** No ledger, no table, nothing written in the legacy
      transaction. Delivery is at-most-once, like every `pg_notify`: right for
      invalidating a cache, wrong for anything that must not miss a write.
    * **key only.** The payload is
      `{"relation": "schema.table", "op": "insert" | "update" | "delete", "key": {...}}`,
      where `key` holds the twin's primary key columns. No row data, so no
      secret, and no payload anywhere near the 7999-byte ceiling.
    * **isolated.** The `pg_notify` runs in a savepoint; a failure is logged
      with `RAISE WARNING` and the legacy write commits.

  A watch payload has no `"resource"`, so it is not for `AshStrangler.Listener`;
  give it a channel of its own and subscribe with `Postgrex.Notifications`.

  The function carries no schema qualifier and is created with `SET search_path
  FROM CURRENT`, like the ledger's: it lands in the migrating session's schema
  (the host's), not in the legacy one. Names derive from `schema.table`, and
  every trigger this package installs starts `strangler_`, which is how
  `mix ash_strangler.snapshot drift` tells its own triggers from drift.
  """

  alias AshStrangler.Sql.Printer
  alias AshStrangler.Twin

  @doc "The watch function and trigger for `twin`, or `[]` when it is not watched."
  @spec build(Ash.Resource.t()) :: [%{name: atom(), up: String.t(), down: String.t()}]
  def build(twin) do
    case Twin.watch(twin) do
      nil -> []
      channel -> do_build(twin, channel)
    end
  end

  defp do_build(twin, channel) do
    schema = AshPostgres.DataLayer.Info.schema(twin) || "public"
    table = Twin.table!(twin)
    relation = ~s("#{schema}"."#{table}")
    name = "strangler_watch_#{schema}_#{table}"
    function = ~s("#{name}")
    trigger = ~s("#{name}")

    key =
      twin
      |> Ash.Resource.Info.primary_key()
      |> Enum.map_join(", ", fn attribute ->
        column = Twin.column!(twin, attribute)
        # Always quoted, as this function has always been written, so the
        # generated text of a watched twin with ordinary columns does not move.
        quoted = String.replace(column, ~s("), ~s(""))
        "#{Printer.literal(column)}, affected.\"#{quoted}\""
      end)

    [
      %{
        name: :"#{name}_function",
        up: """
        CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger
        SET search_path FROM CURRENT
        AS $strangler$
        DECLARE
          affected record;
        BEGIN
          affected := COALESCE(NEW, OLD);

          -- Key only, and isolated: a failed notify is logged and the legacy
          -- write still commits.
          BEGIN
            PERFORM pg_notify('#{channel}', json_build_object(
              'relation', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
              'op', lower(TG_OP),
              'key', json_build_object(#{key})
            )::text);
          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'ash_strangler watch on %.% skipped: % (%)',
              TG_TABLE_SCHEMA, TG_TABLE_NAME, SQLERRM, SQLSTATE;
          END;

          -- The return value of an AFTER row trigger is ignored.
          RETURN NULL;
        END $strangler$ LANGUAGE plpgsql;
        """,
        down: "DROP FUNCTION IF EXISTS #{function}() CASCADE;"
      },
      %{
        name: :"#{name}_trigger",
        up: """
        CREATE OR REPLACE TRIGGER #{trigger}
          AFTER INSERT OR UPDATE OR DELETE ON #{relation}
          FOR EACH ROW EXECUTE FUNCTION #{function}();
        """,
        # The relation belongs to the legacy application and may be gone.
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
end
