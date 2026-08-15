# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Diagram.SqlTest do
  @moduledoc """
  The one inferred thing in the diagram, and therefore the one worth pinning.

  `AshStrangler` hands `from:` expressions to Postgres verbatim and never parses
  them. Working out which identifiers in one are columns is a heuristic, so the
  interesting cases are the ones where a naive scan gets it wrong: a table name
  hiding inside a string literal, a function name that looks like a column, a
  cast that looks like two.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.Diagram.Sql

  doctest AshStrangler.Diagram.Sql

  describe "columns/2" do
    test "finds the columns a concatenation reads" do
      assert {:ok, ["first_name", "last_name"]} =
               Sql.columns("coalesce(first_name,'') || ' ' || coalesce(last_name,'')")
    end

    test "finds every arm of a CASE, in order, across newlines" do
      expression = """
      CASE
        WHEN is_deleted THEN 'archived'
        WHEN cancelled_at IS NOT NULL THEN 'cancelled'
        WHEN approved_at IS NOT NULL THEN 'active'
        ELSE 'pending'
      END
      """

      assert {:ok, ["is_deleted", "cancelled_at", "approved_at"]} = Sql.columns(expression)
    end

    test "does not mistake a relation named in a string literal for a column" do
      # The key expression contains `'demo_legacy.accounts:'`. A scan that does
      # not strip literals first reports `demo_legacy.accounts` as a column and
      # draws an edge from a table that is not there.
      expression =
        "uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'demo_legacy.accounts:' || id::text)"

      assert {:ok, ["id"]} = Sql.columns(expression)
    end

    test "does not mistake a cast for a column" do
      assert {:ok, ["email"]} = Sql.columns("(email)::citext")
    end

    test "keeps the qualifier on a joined reference" do
      assert {:ok, ["addr.city"]} = Sql.columns("addr.city")
    end

    test "drops SQL keywords, including the words of AT TIME ZONE" do
      assert {:ok, ["deleted_at"]} = Sql.columns("(deleted_at AT TIME ZONE 'UTC')")
    end

    test "reports :unresolved rather than an empty list" do
      # The caller draws a visible marker for this. Returning `[]` would be
      # indistinguishable from a transform that genuinely reads nothing.
      assert :unresolved = Sql.columns("now()")
      assert :unresolved = Sql.columns(nil)
    end

    test "known_columns turns the heuristic into a filter" do
      expression = "CASE WHEN flagged THEN mystery ELSE other END"

      assert {:ok, ["flagged", "mystery", "other"]} = Sql.columns(expression)

      assert {:ok, ["flagged", "other"]} =
               Sql.columns(expression, known_columns: ["flagged", "other", "unused"])
    end

    test "known_columns matches a qualified reference on its bare name" do
      assert {:ok, ["addr.city"]} = Sql.columns("addr.city", known_columns: ["city"])
    end
  end

  describe "summarize/2" do
    test "collapses the whitespace a heredoc mapping carries" do
      assert Sql.summarize("CASE\n  WHEN a THEN 1\n  ELSE 2\nEND") ==
               "CASE WHEN a THEN 1 ELSE 2 END"
    end

    test "truncates without pretending to summarise" do
      assert Sql.summarize(String.duplicate("a", 100), 20) == String.duplicate("a", 17) <> "..."
    end

    test "leaves an expression that fits alone" do
      assert Sql.summarize("email", 64) == "email"
    end
  end
end
