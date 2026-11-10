# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.AdditiveRegenerationTest do
  @moduledoc """
  Regenerating a migration after a column was declared. The owned table gains the
  column (`ADD COLUMN IF NOT EXISTS`), and a view whose column list changed shape is
  dropped and rebuilt, with its `INSTEAD OF` triggers, instead of being refused.
  DDL runs inside the sandbox transaction.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Test.ExtendedUser

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  defp ups(module), do: for(%{up: up} <- AshStrangler.Migration.statements(module), do: up)

  # A union over one legacy table. `view` is shared by every version of the declaration, so the
  # versions stand for the same union before and after a column was added.
  defp define!(view, version, columns) do
    twin = Module.concat(__MODULE__, "Twin#{view}")

    unless Code.ensure_loaded?(twin) do
      q!(
        "CREATE TABLE clinic_union.#{view}_src (id integer PRIMARY KEY, name text, code integer)"
      )

      Code.compile_string("""
      defmodule #{inspect(twin)} do
        use Ash.Resource,
          domain: AshStrangler.Test.Clinic.Legacy,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Twin]

        postgres do
          table "#{view}_src"
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
      """)
    end

    declared =
      Enum.map_join(columns, "\n", fn {name, {_, type, opts}} ->
        "column :#{name}, :#{type}#{opts}"
      end)

    maps =
      Enum.map_join(columns, "\n", fn
        {:name, _} -> "map :name, from: :name"
        {:code, _} -> "map :code, from: :code"
        {name, _} -> "unmapped [:#{name}], because: \"owned only\""
      end)

    module = Module.concat(__MODULE__, "Union#{view}V#{version}")

    {_result, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use AshStrangler.Union

          union do
            schema "clinic_union"
            view "#{view}"
            #{declared}

            legacy :north do
              twin #{inspect(twin)}
              phase :dual_write
              refused_because "north writes"
              key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
              #{maps}
            end

            owned :native
          end
        end
        """)
      end)

    module
  end

  defp columns(view),
    do:
      for(
        [name] <-
          q!("""
          SELECT attname FROM pg_attribute
          WHERE attrelid = to_regclass('clinic_union.#{view}') AND attnum > 0 AND NOT attisdropped
          ORDER BY attnum
          """),
        do: name
      )

  defp oid(relation), do: q!("SELECT to_regclass($1)::oid::bigint", [relation]) |> hd() |> hd()

  describe "the rendered SQL" do
    test "an owned table gaining a column is followed by ADD COLUMN IF NOT EXISTS for each column" do
      v1 = define!("add_sql", 1, name: {:name, :string, ""}, code: {:code, :integer, ""})
      statements = AshStrangler.Migration.statements(v1)

      names = Enum.map(statements, & &1.name)
      create = Enum.find_index(names, &(&1 == :strangler_add_sql_owned_table))
      assert Enum.at(names, create + 1) == :strangler_add_sql_owned_table_add_columns

      alter = Enum.at(statements, create + 1)
      assert alter.up =~ ~s|ALTER TABLE "clinic_union"."add_sql_owned"|
      assert alter.up =~ ~s|ADD COLUMN IF NOT EXISTS "name" text|
      assert alter.up =~ ~s|ADD COLUMN IF NOT EXISTS "code" bigint|
      # Never destroys rows: the down of an added column is a no-op.
      assert alter.down == "SELECT 1;"
    end

    test "the view is reshaped before it is created, and the triggers come after it" do
      v1 = define!("order_sql", 1, name: {:name, :string, ""})
      names = v1 |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      reshape = Enum.find_index(names, &(&1 == :strangler_order_sql_view_reshape))
      view = Enum.find_index(names, &(&1 == :strangler_order_sql_view))

      triggers =
        for op <- [:insert, :update, :delete],
            do: Enum.find_index(names, &(&1 == :"strangler_order_sql_#{op}_trigger"))

      assert reshape + 1 == view
      assert Enum.all?(triggers, &(&1 > view))

      reshape_up = AshStrangler.Migration.statements(v1) |> Enum.at(reshape) |> Map.fetch!(:up)
      assert reshape_up =~ ~s|EXECUTE 'DROP VIEW "clinic_union"."order_sql"'|
      refute reshape_up =~ "CASCADE"
    end

    test "a NOT NULL column with no default is guarded, a nullable one is not" do
      v =
        define!("guard_sql", 1,
          name: {:name, :string, ""},
          req: {:req, :string, ", null?: false"}
        )

      names = v |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      assert :strangler_guard_sql_owned_table_add_columns_guard in names

      alter =
        Enum.find(
          AshStrangler.Migration.statements(v),
          &(&1.name == :strangler_guard_sql_owned_table_add_columns)
        )

      assert alter.up =~ ~s|ADD COLUMN IF NOT EXISTS "req" text NOT NULL|

      nullable = define!("guard_sql2", 1, name: {:name, :string, ""})

      refute :strangler_guard_sql2_owned_table_add_columns_guard in Enum.map(
               AshStrangler.Migration.statements(nullable),
               & &1.name
             )
    end

    test "an extension table gets ADD COLUMN IF NOT EXISTS for its columns" do
      statements = AshStrangler.Migration.statements(ExtendedUser)
      alter = Enum.find(statements, &(&1.name == :strangler_extended_users_extension_add_columns))

      assert alter.up =~ ~s|ALTER TABLE "strangler"."extended_users_extension"|
      assert alter.up =~ ~s|ADD COLUMN IF NOT EXISTS "notes" text|
      assert alter.up =~ ~s|ADD COLUMN IF NOT EXISTS "risk_score" bigint|
      refute alter.up =~ "NOT NULL"
    end

    test "the rendered migration still parses without diagnostics" do
      v1 = define!("render_sql", 1, name: {:name, :string, ""})
      source = AshStrangler.Migration.render("Elixir.AdditiveRender", [v1])
      {_ast, stderr} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.string_to_quoted!(source) end)
      assert stderr == ""
    end
  end

  describe "Migration.only/2" do
    test "keeps the named modules in declared order and refuses an unknown name" do
      v1 = define!("only_a", 1, name: {:name, :string, ""})
      v2 = define!("only_b", 1, name: {:name, :string, ""})

      assert AshStrangler.Migration.only([v1, v2], [inspect(v2)]) == [v2]

      assert AshStrangler.Migration.only([v1, v2], ["Elixir." <> inspect(v2), inspect(v1)]) == [
               v1,
               v2
             ]

      assert_raise ArgumentError, ~r/Nope/, fn ->
        AshStrangler.Migration.only([v1, v2], ["Nope"])
      end
    end
  end

  describe "against the database" do
    test "a column added mid-list reaches the owned table and the view, and regenerating again is a no-op" do
      v1 = define!("regen", 1, name: {:name, :string, ""}, code: {:code, :integer, ""})
      Enum.each(ups(v1), &q!/1)

      q!("""
      INSERT INTO clinic_union.regen (__branch, name, code) VALUES ('native', 'ada', 7)
      """)

      assert columns("regen") == ["id", "__branch", "name", "code"]
      # Running the same migration again changes nothing.
      Enum.each(ups(v1), &q!/1)

      # `extra` goes in the middle, `tail` at the end.
      v2 =
        define!("regen", 2,
          name: {:name, :string, ""},
          extra: {:extra, :string, ""},
          code: {:code, :integer, ""},
          tail: {:tail, :string, ""}
        )

      Enum.each(ups(v2), &q!/1)

      assert columns("regen") == ["id", "__branch", "name", "extra", "code", "tail"]
      assert columns("regen_owned") == ["id", "name", "code", "extra", "tail"]

      # The row written before the column existed is intact, and the new columns read NULL.
      assert [["ada", nil, 7, nil]] = q!("SELECT name, extra, code, tail FROM clinic_union.regen")

      # The INSTEAD OF triggers survived the view being rebuilt.
      q!(
        "INSERT INTO clinic_union.regen (__branch, name, extra, code, tail) VALUES ('native', 'bob', 'x', 8, 'y')"
      )

      q!("UPDATE clinic_union.regen SET extra = 'z' WHERE name = 'bob'")
      assert [["z", "y"]] = q!("SELECT extra, tail FROM clinic_union.regen WHERE name = 'bob'")
      q!("DELETE FROM clinic_union.regen WHERE name = 'bob'")

      # And again: idempotent over the new shape.
      Enum.each(ups(v2), &q!/1)
      assert columns("regen") == ["id", "__branch", "name", "extra", "code", "tail"]
    end

    test "appending a column does not drop the view" do
      v1 = define!("append", 1, name: {:name, :string, ""})
      Enum.each(ups(v1), &q!/1)
      before = oid("clinic_union.append")

      v2 = define!("append", 2, name: {:name, :string, ""}, tail: {:tail, :string, ""})
      Enum.each(ups(v2), &q!/1)

      assert columns("append") == ["id", "__branch", "name", "tail"]
      assert oid("clinic_union.append") == before
    end

    test "a view that depends on the rebuilt view makes the migration fail instead of being dropped" do
      v1 = define!("dep", 1, name: {:name, :string, ""}, code: {:code, :integer, ""})
      Enum.each(ups(v1), &q!/1)
      q!("CREATE VIEW clinic_union.dep_report AS SELECT id, name FROM clinic_union.dep")

      v2 =
        define!("dep", 2,
          name: {:name, :string, ""},
          extra: {:extra, :string, ""},
          code: {:code, :integer, ""}
        )

      assert_raise Postgrex.Error, ~r/depend/, fn -> Enum.each(ups(v2), &q!/1) end
      assert oid("clinic_union.dep_report") != nil
    end

    test "a NOT NULL column with no default is refused clearly while rows exist, and added when the table is empty" do
      v1 = define!("nn", 1, name: {:name, :string, ""})
      Enum.each(ups(v1), &q!/1)

      empty = define!("nn", 2, name: {:name, :string, ""}, req: {:req, :string, ", null?: false"})
      Enum.each(ups(empty), &q!/1)
      assert "req" in columns("nn_owned")

      v3 = define!("nn2", 1, name: {:name, :string, ""})
      Enum.each(ups(v3), &q!/1)
      q!("INSERT INTO clinic_union.nn2 (__branch, name) VALUES ('native', 'ada')")
      full = define!("nn2", 2, name: {:name, :string, ""}, req: {:req, :string, ", null?: false"})

      error = assert_raise Postgrex.Error, fn -> Enum.each(ups(full), &q!/1) end
      assert Exception.message(error) =~ "column req is NOT NULL with no default"
      refute "req" in columns("nn2_owned")
    end
  end
end
