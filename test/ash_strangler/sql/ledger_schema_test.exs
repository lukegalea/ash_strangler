# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.LedgerSchemaTest do
  @moduledoc """
  The ledger lands in the migrating session's schema, and the trigger keeps
  writing there from a legacy session that has never heard of it.

  This is the portability claim in "Which schema" (`AshStrangler.Sql.Ledger`)
  run against a real server: a host that owns a non-`public` schema migrates
  with that schema first on its `search_path`, and nothing of the ledger may
  end up in `public`.

  Not async: the statements replace the fixture's ledger trigger on
  `legacy.users` for the length of the sandbox transaction, and that DDL lock
  would stall the async tests writing legacy rows.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Migration
  alias AshStrangler.Test.LedgerUser

  @owned "strangler_owned_ledger_test"

  test "the table, index and function land in the migrator's schema, and legacy writes follow them" do
    TestRepo.query!(~s(CREATE SCHEMA "#{@owned}"))
    TestRepo.query!(~s(SET LOCAL search_path TO "#{@owned}", public))

    LedgerUser
    |> Migration.statements()
    |> Enum.filter(&(&1.name |> Atom.to_string() |> String.starts_with?("strangler_ledger")))
    |> Enum.each(&TestRepo.query!(&1.up, []))

    assert @owned in schema_of("legacy_change_events", "r")
    assert @owned in schema_of("legacy_change_events_unprocessed_idx", "i")
    assert @owned in function_schemas("strangler_ledger_legacy_users")

    # The legacy application's session: its own search_path, no owned schema.
    TestRepo.query!("SET LOCAL search_path TO public")
    legacy_id = insert_legacy_user!()

    assert %{rows: [[1]]} =
             TestRepo.query!(
               ~s|SELECT count(*)::int FROM "#{@owned}".legacy_change_events WHERE primary_key = $1|,
               [%{"id" => legacy_id}]
             )
  end

  defp schema_of(name, kind) do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = $1 AND c.relkind = $2
        ORDER BY n.nspname
        """,
        [name, kind]
      )

    List.flatten(rows)
  end

  defp function_schemas(name) do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname = $1",
        [name]
      )

    List.flatten(rows)
  end
end
