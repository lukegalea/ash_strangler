# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionWriteBackTest do
  @moduledoc """
  What a `:dual_write` branch writes back to its legacy table: a declared type that
  differs from the legacy type, and a column that feeds the key.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Test.UnionEdges

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  defp install!(columns, mappings) do
    for sql <- UnionEdges.ddl(), do: q!(sql)

    module = "AshStrangler.UnionWriteBackTest.V#{System.unique_integer([:positive])}"
    [{union, _}] = module |> UnionEdges.source(columns, mappings) |> Code.compile_string()
    for %{up: up} <- AshStrangler.Migration.statements(union), do: q!(up)
    q!("INSERT INTO union_edges.east_visits VALUES (1, 'ada', 7)")
  end

  test "a column whose declared type differs from the legacy type is cast back" do
    install!(
      "column :display, :string, null?: false\n column :code, :string",
      "map :display, from: :name\n map :code, from: :code\n"
    )

    q!("UPDATE union_edges.visits SET display = 'Ada L' WHERE display = 'ada'")
    assert [["Ada L", 7]] = q!("SELECT name, code FROM union_edges.east_visits")

    q!("UPDATE union_edges.visits SET code = '9' WHERE display = 'Ada L'")
    assert [["Ada L", 9]] = q!("SELECT name, code FROM union_edges.east_visits")
  end

  test "a column that feeds the key is refused, and no row is re-keyed or blanked" do
    install!(
      "column :display, :string, null?: false\n column :legacy_no, :integer",
      "map :display, from: :name\n map :legacy_no, from: :id\n"
    )

    assert_raise Postgrex.Error, ~r/column legacy_no has no legacy column/, fn ->
      q!("UPDATE union_edges.visits SET legacy_no = 50 WHERE legacy_no = 1 RETURNING *")
    end

    assert [[1, "ada"]] = q!("SELECT id, name FROM union_edges.east_visits")

    # Updating the other columns still works, with legacy_no unchanged.
    assert [[_id, "east", "ada!", 1]] =
             q!("UPDATE union_edges.visits SET display = 'ada!' WHERE legacy_no = 1 RETURNING *")
  end
end
