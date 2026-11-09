# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionWriteTest do
  @moduledoc """
  `:dual_write` updates through a union view where the declared columns do not
  line up one to one with the legacy columns: a declared type that differs from
  the legacy type, and a column read from the legacy column that forms the key.
  DDL runs inside the sandbox transaction.
  """

  use AshStrangler.DataCase, async: false

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  defp install!(columns, maps, opts \\ []) do
    n = System.unique_integer([:positive])

    q!("CREATE TABLE clinic_union.fix#{n} (id integer PRIMARY KEY, name text, code integer)")
    q!("INSERT INTO clinic_union.fix#{n} VALUES (2, 'ada', 7)")

    Code.compile_string("""
    defmodule AshStrangler.UnionWriteTest.Twin#{n} do
      use Ash.Resource,
        domain: AshStrangler.Test.Clinic.Legacy,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Twin]

      postgres do
        table "fix#{n}"
        schema "clinic_union"
        repo AshStrangler.TestRepo
        migrate? false
      end

      attributes do
        attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
        attribute :name, :string, public?: true
        attribute :code, :integer, public?: true
      end

      actions do
        defaults [:read]
      end
    end

    defmodule AshStrangler.UnionWriteTest.Union#{n} do
      use AshStrangler.Union

      union do
        schema "clinic_union"
        view "fixv#{n}"
        #{opts[:union]}
        #{columns}

        legacy :north do
          twin AshStrangler.UnionWriteTest.Twin#{n}
          phase :dual_write
          refused_because "north writes"
          key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
          #{maps}
          #{opts[:branch]}
        end

        owned :native
      end
    end
    """)

    union = Module.concat(AshStrangler.UnionWriteTest, "Union#{n}")
    for %{up: up} <- AshStrangler.Migration.statements(union), do: q!(up)
    {"clinic_union.fixv#{n}", "clinic_union.fix#{n}", union}
  end

  test "a declared type that differs from the legacy type is cast back on write" do
    {view, table, _union} =
      install!(
        "column :display, :string\ncolumn :code, :string",
        "map :display, from: :name\nmap :code, from: :code"
      )

    q!("UPDATE #{view} SET display = 'Ada L' WHERE display = 'ada'")
    assert [["Ada L", 7]] = q!("SELECT name, code FROM #{table}")

    q!("UPDATE #{view} SET code = '9'")
    assert [["Ada L", 9]] = q!("SELECT name, code FROM #{table}")
  end

  test "a column read from the legacy key column is read-only; the row is not re-keyed" do
    {view, table, _union} =
      install!(
        "column :legacy_no, :integer\ncolumn :display, :string",
        "map :legacy_no, from: :id\nmap :display, from: :name"
      )

    assert_raise Postgrex.Error, ~r/forms the row's key/, fn ->
      q!("UPDATE #{view} SET legacy_no = 50 WHERE legacy_no = 2")
    end

    assert [[2]] = q!("SELECT id FROM #{table}")

    assert [[id, 2, "Ada"]] =
             q!("UPDATE #{view} SET display = 'Ada' RETURNING id, legacy_no, display")

    assert is_binary(id)
  end

  defp refused!(fun) do
    error = assert_raise Postgrex.Error, fun
    "ash_error: " <> json = error.postgres.message
    assert %{"exception" => "Elixir.AshStrangler.Error.BranchWriteRefused"} = Jason.decode!(json)
    Jason.decode!(json)["input"]
  end

  test "a not_written_back column is accepted, dropped, and reads the legacy value" do
    {view, table, _} =
      install!(
        "column :display, :string\ncolumn :code, :string\ncolumn :stamp, :string",
        "map :display, from: :name\nmap :code, from: :code\nmap :stamp, from: :name",
        branch: ~S|not_written_back [:code, :stamp], because: "legacy stamps these"|
      )

    q!("UPDATE #{view} SET display = 'Ada L', code = '99', stamp = 'x'")
    assert [["Ada L", 7]] = q!("SELECT name, code FROM #{table}")
    assert [["Ada L", "7"]] = q!("SELECT display, code FROM #{view}")
  end

  test "an extension column round-trips and the legacy table is not written for it" do
    {view, table, union} =
      install!(
        "column :display, :string\ncolumn :template, :string",
        "map :display, from: :name\nextension [:template]"
      )

    assert [[nil]] = q!("SELECT template FROM #{view}")

    q!("UPDATE #{view} SET template = 'tpl-1'")
    assert [["tpl-1"]] = q!("SELECT template FROM #{view}")

    q!("UPDATE #{view} SET template = 'tpl-2', display = 'Ada L'")
    assert [["tpl-2", "Ada L"]] = q!("SELECT template, display FROM #{view}")
    assert [["Ada L"]] = q!("SELECT name FROM #{table}")

    assert [[1]] =
             q!("SELECT count(*)::int FROM #{AshStrangler.Union.Info.extension_table(union)}")
  end

  test "an update that changes only extension columns issues no write to the legacy table" do
    {view, table, _} = install!("column :template, :string", "extension [:template]")

    [[xmin]] = q!("SELECT xmin::text FROM #{table}")
    q!("UPDATE #{view} SET template = 'tpl-1'")
    assert [["tpl-1"]] = q!("SELECT template FROM #{view}")
    assert [[^xmin]] = q!("SELECT xmin::text FROM #{table}")
  end

  test "a view DELETE under refuse_delete is refused and the legacy row stays" do
    {view, table, _} =
      install!(
        "column :display, :string",
        "map :display, from: :name",
        branch: ~S|refuse_delete because: "legacy archives"|
      )

    input = refused!(fn -> q!("DELETE FROM #{view}") end)
    assert %{"operation" => "delete", "reason" => "legacy archives"} = input
    assert [[1]] = q!("SELECT count(*)::int FROM #{table}")
  end

  test "a role with only view grants can update through a security_definer union" do
    {view, table, _} =
      install!(
        "column :display, :string",
        "map :display, from: :name",
        union: "security_definer true"
      )

    role = "strangler_viewer_#{System.unique_integer([:positive])}"
    q!("CREATE ROLE #{role}")
    q!("GRANT USAGE ON SCHEMA clinic_union TO #{role}")
    q!("GRANT SELECT, UPDATE ON #{view} TO #{role}")

    q!("SET LOCAL ROLE #{role}")
    q!("UPDATE #{view} SET display = 'Ada L'")
    q!("RESET ROLE")
    assert [["Ada L"]] = q!("SELECT name FROM #{table}")
  end

  test "without security_definer the same role cannot update" do
    {view, _table, _} = install!("column :display, :string", "map :display, from: :name")
    role = "strangler_viewer_#{System.unique_integer([:positive])}"
    q!("CREATE ROLE #{role}")
    q!("GRANT USAGE ON SCHEMA clinic_union TO #{role}")
    q!("GRANT SELECT, UPDATE ON #{view} TO #{role}")
    q!("SET LOCAL ROLE #{role}")

    assert_raise Postgrex.Error, ~r/permission denied/, fn ->
      q!("UPDATE #{view} SET display = 'x'")
    end

    q!("RESET ROLE")
  end

  describe "render_move/2" do
    test "renders no owned table and no trigger, and moves an installed union" do
      {view, table, union} = install!("column :display, :string", "map :display, from: :name")

      move = AshStrangler.Migration.render_move("MoveTest", [union])
      refute move =~ "CREATE TABLE"
      refute move =~ "CREATE TRIGGER"
      assert move =~ "CREATE OR REPLACE VIEW"
      assert move =~ "CREATE OR REPLACE FUNCTION"

      statements = AshStrangler.Union.Sql.move_statements(union)
      for %{up: up} <- statements, do: q!(up)
      q!("UPDATE #{view} SET display = 'moved'")
      assert [["moved"]] = q!("SELECT name FROM #{table}")
    end

    test "creates the extension table of a union that gained one, without an owned table" do
      {view, _table, union} =
        install!(
          "column :display, :string\ncolumn :template, :string",
          "map :display, from: :name\nextension [:template]"
        )

      q!("DROP TABLE #{AshStrangler.Union.Info.extension_table(union)} CASCADE")
      move = AshStrangler.Migration.render_move("MoveTest", [union])
      assert move =~ "CREATE TABLE IF NOT EXISTS"
      refute move =~ ~r/CREATE TABLE[^(]*_owned/
      refute move =~ "CREATE TRIGGER"
      assert is_binary(view)
    end

    test "refuses a changed column list" do
      {view, _table, union} = install!("column :display, :string", "map :display, from: :name")

      q!("DROP VIEW #{view} CASCADE")

      q!(
        "CREATE VIEW #{view} AS SELECT gen_random_uuid() AS id, 'x'::text AS \"__branch\", 'a'::text AS renamed"
      )

      error =
        assert_raise Postgrex.Error, fn ->
          for %{up: up} <- AshStrangler.Union.Sql.move_statements(union), do: q!(up)
        end

      assert error.postgres.message =~ "documentation/topics/phases.md"

      assert AshStrangler.Migration.render_move("MoveTest", [union]) =~
               "documentation/topics/phases.md"
    end
  end
end
