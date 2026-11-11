# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionWriteTest do
  @moduledoc """
  `:dual_write` writes through a union view where the declared columns do not
  line up one to one with the legacy columns: a declared type that differs from
  the legacy type, a column read from the legacy column that forms the key, and
  an insert routed into the legacy table with `insert_through`. DDL runs inside
  the sandbox transaction.
  """

  use AshStrangler.DataCase, async: false

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  defp install!(columns, maps, opts \\ []) do
    n = System.unique_integer([:positive])

    ddl = opts[:table] || "id integer PRIMARY KEY, name text, code integer"
    q!("CREATE TABLE clinic_union.fix#{n} (#{ddl})")

    seed = if Keyword.has_key?(opts, :seed), do: opts[:seed], else: "2, 'ada', 7"
    if seed, do: q!("INSERT INTO clinic_union.fix#{n} VALUES (#{seed})")

    attributes =
      opts[:attributes] ||
        """
        attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
        attribute :name, :string, public?: true
        attribute :code, :integer, public?: true
        """

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
        #{String.trim(attributes)}
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
          phase #{inspect(opts[:phase] || :dual_write)}
          refused_because "north writes"
          key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
          #{maps}
          #{opts[:branch]}
        end

        owned :native
      end
    end
    """)

    if opts[:ledger?] do
      Code.compile_string("""
      defmodule AshStrangler.UnionWriteTest.Ledger#{n} do
        use Ash.Resource,
          domain: AshStrangler.Test.Clinic.Legacy,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Resource]

        postgres do
          table "ledger_view#{n}"
          schema "clinic_union"
          repo AshStrangler.TestRepo
          migrate? false
        end

        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :name, :string, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.UnionWriteTest.Twin#{n} do
            notify? true
            ledger? true
            notify_channel "union_write_ledger_#{n}"

            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            map :name, from: :name
          end
        end
      end
      """)

      ledger = Module.concat(AshStrangler.UnionWriteTest, "Ledger#{n}")

      for %{up: up} <- AshStrangler.Sql.Ledger.build(ledger), do: q!(up)
    end

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

  test "an update assigns only the columns it changes, so a concurrent legacy commit survives" do
    {view, table, _} =
      install!(
        "column :display, :string\ncolumn :code, :string\ncolumn :template, :string",
        "map :display, from: :name\nmap :code, from: :code\nextension [:template]"
      )

    # `bump` stands for a legacy commit landing after the statement scanned the view: the trigger's
    # NEW and OLD still carry the old values of the columns this statement does not set.
    q!("""
    WITH bump AS (UPDATE #{table} SET name = 'parsed', code = 99 RETURNING id)
    UPDATE #{view} SET template = 'tpl-1' FROM bump
    """)

    assert [["parsed", 99]] = q!("SELECT name, code FROM #{table}")
    assert [["tpl-1"]] = q!("SELECT template FROM #{view}")
  end

  test "an extension upsert overwrites only the extension columns it changes" do
    {view, _table, union} =
      install!(
        "column :a, :string\ncolumn :b, :string",
        "extension [:a, :b]"
      )

    q!("UPDATE #{view} SET a = 'a1', b = 'b1'")

    # A second writer's `a` lands between this statement's scan and its trigger.
    ext = AshStrangler.Union.Info.extension_table(union)

    q!("""
    WITH bump AS (UPDATE #{ext} SET a = 'a2' RETURNING 1)
    UPDATE #{view} SET b = 'b2' FROM bump
    """)

    assert [["a2", "b2"]] = q!("SELECT a, b FROM #{view}")
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

  # --- inserts through a legacy branch ------------------------------------------

  @identity_table "id integer PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY, name text"
  @id_name_attributes """
  attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
  attribute :name, :string, public?: true
  """

  test "an insert naming the branch lands in the legacy table with the mapped columns and the constants" do
    {view, table, _} =
      install!(
        "column :display, :string\ncolumn :code, :string",
        "map :display, from: :name\nmap :code, from: :code",
        table: @identity_table <> ", code integer, processed boolean, verified boolean",
        seed: nil,
        attributes:
          @id_name_attributes <>
            """
            attribute :code, :integer, public?: true
            attribute :processed, :boolean, public?: true
            attribute :verified, :boolean, public?: true
            """,
        branch:
          ~S|insert_through because: "the legacy system reads what it writes", set: [processed: true, verified: false]|
      )

    # RETURNING is the whole view row: the key, the branch, then the declared columns.
    assert [[id, "north", "ada", "9"]] =
             q!("""
             INSERT INTO #{view} (__branch, display, code) VALUES ('north', 'ada', '9')
             RETURNING *
             """)

    assert is_binary(id) and byte_size(id) == 16

    # The legacy table allocated its own key, and the route set the constants.
    assert [[legacy_id, "ada", 9, true, false]] =
             q!("SELECT id, name, code, processed, verified FROM #{table}")

    assert is_integer(legacy_id)

    # The view derives the key from the allocated legacy key, so the row reads back.
    assert [[^id, "north"]] = q!("SELECT id, __branch FROM #{view}")
  end

  test "an insert naming the branch upserts its extension columns under the new key" do
    {view, table, union} =
      install!(
        "column :display, :string\ncolumn :template, :string",
        "map :display, from: :name\nextension [:template]",
        table: @identity_table,
        seed: nil,
        attributes: @id_name_attributes,
        branch: ~S|insert_through because: "why"|
      )

    assert [[id, "north", "ada", "tpl-1"]] =
             q!("""
             INSERT INTO #{view} (__branch, display, template) VALUES ('north', 'ada', 'tpl-1')
             RETURNING *
             """)

    assert [[^id, "tpl-1"]] =
             q!("SELECT \"id\", template FROM #{AshStrangler.Union.Info.extension_table(union)}")

    assert [["ada"]] = q!("SELECT name FROM #{table}")
  end

  test "the ledger on the legacy table records one insert" do
    {view, table, _} =
      install!(
        "column :display, :string",
        "map :display, from: :name",
        table: @identity_table,
        seed: nil,
        attributes: @id_name_attributes,
        branch: ~S|insert_through because: "why"|,
        ledger?: true
      )

    source_table = String.replace_prefix(table, "clinic_union.", "")
    q!("INSERT INTO #{view} (__branch, display) VALUES ('north', 'ada')")

    assert [[1]] =
             q!(
               "SELECT count(*)::int FROM legacy_change_events WHERE source_table = $1 AND operation = 'insert'",
               [source_table]
             )

    assert [["ada"]] =
             q!(
               "SELECT new_row->>'name' FROM legacy_change_events WHERE source_table = $1 AND operation = 'insert'",
               [source_table]
             )
  end

  test "an insert naming no branch, or the owned branch, still lands in the owned table" do
    {view, table, union} =
      install!(
        "column :display, :string",
        "map :display, from: :name",
        table: @identity_table,
        seed: nil,
        attributes: @id_name_attributes,
        branch: ~S|insert_through because: "why"|
      )

    assert [[id, "ada", "native"]] =
             q!("INSERT INTO #{view} (display) VALUES ('ada') RETURNING id, display, __branch")

    assert [[id2, "bo", "native"]] =
             q!(
               "INSERT INTO #{view} (__branch, display) VALUES ('native', 'bo') RETURNING id, display, __branch"
             )

    assert [[^id, "ada"], [^id2, "bo"]] =
             q!(
               "SELECT id, display FROM #{AshStrangler.Union.Info.owned_table(union)} ORDER BY display"
             )

    assert [] = q!("SELECT 1 FROM #{table} LIMIT 1")
  end

  test "a column the insert cannot write is refused when supplied non-NULL" do
    {view, _table, _} =
      install!(
        "column :display, :string\ncolumn :stamp, :string\ncolumn :frozen, :string",
        """
        map :display, from: :name
        map :stamp, from: expr(name <> "!")
        constant :frozen, "as-is"
        """,
        table: @identity_table,
        seed: nil,
        attributes: @id_name_attributes,
        branch: ~S|insert_through because: "why"|
      )

    input =
      refused!(fn ->
        q!("INSERT INTO #{view} (__branch, display, stamp) VALUES ('north', 'ada', 'x')")
      end)

    assert %{"branch" => "north", "phase" => "dual_write", "operation" => "insert"} = input
    assert input["reason"] =~ "column stamp"
    assert input["reason"] =~ "no legacy column"

    input =
      refused!(fn ->
        q!("INSERT INTO #{view} (__branch, display, frozen) VALUES ('north', 'ada', 'x')")
      end)

    assert input["reason"] =~ "column frozen"

    input =
      refused!(fn ->
        q!(
          "INSERT INTO #{view} (__branch, id, display) VALUES ('north', gen_random_uuid(), 'ada')"
        )
      end)

    assert input["reason"] == "the key column id is allocated by the legacy table"

    # The same insert without them lands: NULL passes, and the lenses answer.
    assert [[_id, "north", "ada", "ada!", "as-is"]] =
             q!("""
             INSERT INTO #{view} (__branch, display) VALUES ('north', 'ada')
             RETURNING id, __branch, display, stamp, frozen
             """)
  end

  test "a not_written_back column is refused on insert, and the constants are still written" do
    {view, table, _} =
      install!(
        "column :display, :string\ncolumn :marked, :string",
        """
        map :display, from: :name
        map :marked, from: :code
        """,
        table: @identity_table <> ", code integer, processed boolean",
        seed: nil,
        attributes:
          @id_name_attributes <>
            """
            attribute :code, :integer, public?: true
            attribute :processed, :boolean, public?: true
            """,
        branch:
          ~S|not_written_back [:marked], because: "the legacy side stamps it"| <>
            "\n" <> ~S|insert_through because: "why", set: [processed: true]|
      )

    input =
      refused!(fn ->
        q!("INSERT INTO #{view} (__branch, display, marked) VALUES ('north', 'ada', 'x')")
      end)

    assert input["reason"] == "column marked is not written back on insert"

    assert [[_id, "north", "ada", nil]] =
             q!("""
             INSERT INTO #{view} (__branch, display) VALUES ('north', 'ada')
             RETURNING id, __branch, display, marked
             """)

    assert [["ada", true]] = q!("SELECT name, processed FROM #{table}")
  end

  test "a column a set constant claims is refused when supplied non-NULL" do
    {view, table, _} =
      install!(
        "column :display, :string\ncolumn :marked, :string",
        """
        map :display, from: :name
        map :marked, from: :code
        """,
        table: @identity_table <> ", code integer",
        seed: nil,
        attributes: @id_name_attributes <> "\nattribute :code, :integer, public?: true",
        branch: ~S|insert_through because: "why", set: [code: 7]|
      )

    input =
      refused!(fn ->
        q!("INSERT INTO #{view} (__branch, display, marked) VALUES ('north', 'ada', 'x')")
      end)

    assert input["reason"] == "column marked is set to a constant on this branch's inserts"

    q!("INSERT INTO #{view} (__branch, display) VALUES ('north', 'ada')")
    assert [[7]] = q!("SELECT code FROM #{table}")
  end

  test "an insert naming a :read_from_legacy branch is still refused with the declared reason" do
    {view, table, _} =
      install!("column :display, :string", "map :display, from: :name", phase: :read_from_legacy)

    input =
      refused!(fn -> q!("INSERT INTO #{view} (__branch, display) VALUES ('north', 'x')") end)

    assert %{"branch" => "north", "phase" => "read_from_legacy", "operation" => "insert"} = input
    assert input["reason"] == "north writes"
    assert [[1]] = q!("SELECT count(*)::int FROM #{table}")
  end

  describe "render_move/2" do
    test "renders the routed insert function, and refuses nothing else" do
      {view, table, union} =
        install!(
          "column :display, :string",
          "map :display, from: :name",
          table: @identity_table,
          seed: nil,
          attributes: @id_name_attributes,
          branch: ~S|insert_through because: "why"|
        )

      move = AshStrangler.Migration.render_move("MoveTest", [union])
      refute move =~ "CREATE TABLE"
      refute move =~ "CREATE TRIGGER"
      assert move =~ "CREATE OR REPLACE VIEW"
      assert move =~ "CREATE OR REPLACE FUNCTION"
      assert move =~ "INSERT INTO #{table}"

      statements = AshStrangler.Union.Sql.move_statements(union)
      for %{up: up} <- statements, do: q!(up)

      assert [[id, "north", "ada"]] =
               q!("""
               INSERT INTO #{view} (__branch, display) VALUES ('north', 'ada')
               RETURNING id, __branch, display
               """)

      assert is_binary(id)
      assert [["ada"]] = q!("SELECT name FROM #{table}")
    end

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
