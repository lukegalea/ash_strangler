# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.RelationTest do
  use ExUnit.Case, async: true

  alias AshStrangler.Sql.Relation

  describe "parse/1" do
    test "a bare name has no schema" do
      assert Relation.parse("users") == {:ok, {nil, "users"}}
    end

    test "an unquoted dot separates schema from table" do
      assert Relation.parse("legacy.users") == {:ok, {"legacy", "users"}}
    end

    test "an unquoted name keeps its case" do
      assert Relation.parse("Legacy.Mixed_Items") == {:ok, {"Legacy", "Mixed_Items"}}
    end

    test "a quoted name may contain dots" do
      assert Relation.parse(~s|"odd.schema".t|) == {:ok, {"odd.schema", "t"}}
      assert Relation.parse(~s|s."odd.table"|) == {:ok, {"s", "odd.table"}}
      assert Relation.parse(~s|"a.b"."c.d"|) == {:ok, {"a.b", "c.d"}}
      assert Relation.parse(~s|"odd.table"|) == {:ok, {nil, "odd.table"}}
    end

    test "a doubled quote inside a quoted name is one quote" do
      assert Relation.parse(~s|"say ""hi"".x"."t"|) == {:ok, {~s|say "hi".x|, "t"}}
    end

    test "malformed input is refused with the input in the message" do
      for bad <- ["", ".t", "s.", "a.b.c", ~s|"open|, ~s|"a"b.t|, ~s|a"b.t|, ~s|""|] do
        assert {:error, message} = Relation.parse(bad)
        assert message =~ inspect(bad), "message for #{inspect(bad)}: #{message}"
      end
    end
  end

  test "parse!/1 raises ArgumentError on a refusal" do
    assert Relation.parse!("s.t") == {"s", "t"}
    assert_raise ArgumentError, ~r/a\.b\.c/, fn -> Relation.parse!("a.b.c") end
  end

  describe "parse_column/1" do
    test "reads schema.table.column, quoted or not" do
      assert Relation.parse_column("s.t.c") == {:ok, {"s", "t", "c"}}
      assert Relation.parse_column(~s|"odd.s".t."c.d"|) == {:ok, {"odd.s", "t", "c.d"}}
    end

    test "refuses anything that is not three names" do
      assert {:error, message} = Relation.parse_column("s.t")
      assert message =~ "schema.table.column"
      assert {:error, _} = Relation.parse_column(~s|s."t|)
    end
  end
end
