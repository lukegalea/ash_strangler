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

  defp install!(columns, maps) do
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
        #{columns}

        legacy :north do
          twin AshStrangler.UnionWriteTest.Twin#{n}
          phase :dual_write
          refused_because "north writes"
          key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
          #{maps}
        end

        owned :native
      end
    end
    """)

    union = Module.concat(AshStrangler.UnionWriteTest, "Union#{n}")
    for %{up: up} <- AshStrangler.Migration.statements(union), do: q!(up)
    {"clinic_union.fixv#{n}", "clinic_union.fix#{n}"}
  end

  test "a declared type that differs from the legacy type is cast back on write" do
    {view, table} =
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
    {view, table} =
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
end
