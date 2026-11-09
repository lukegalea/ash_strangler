# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Diagram.ReportTest do
  @moduledoc """
  The report is what a person reads in the Clarity tab, so what it must carry is
  the detail itself: the legacy column behind each attribute, the SQL, the
  direction, the phase, and the read-only attributes named with their reasons --
  not that something rendered.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.Diagram.Report
  alias AshStrangler.DiagramTest.{Account, Slim}

  defp report(resources), do: Report.for_resources(resources)

  # The row for one attribute, as its cells.
  defp cells(report, attribute) do
    [line] =
      report |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| `#{attribute}` |"))

    line |> String.split(~r/(?<!\\)\|/, trim: true) |> Enum.map(&String.trim/1)
  end

  describe "a resource" do
    setup do
      %{report: report([Account])}
    end

    test "states the phase, the write mode, the view and every legacy relation", %{report: report} do
      assert report =~ "**Phase:** `read_from_legacy`"
      assert report =~ "**Writes reach the base table:** `triggers`"
      assert report =~ "**View:** `drawn.accounts`"
      assert report =~ "`drawn_legacy.accounts` (primary)"
      assert report =~ "`drawn_legacy.addresses` (LEFT JOIN as address, read only)"
      assert report =~ "LEFT JOIN on `address.account_id = accounts.id`"
    end

    test "a rename names the column it reads", %{report: report} do
      assert [_attr, source, transform, direction, _why] = cells(report, "nickname")
      assert source == "`drawn_legacy.accounts.nick`"
      assert transform == "1:1"
      assert direction == "both ways"
    end

    test "a cast and a decode show the SQL the view runs", %{report: report} do
      assert [_, _, email, "both ways", _] = cells(report, "email")
      assert email =~ "(email)::citext"

      assert [_, "`drawn_legacy.accounts.state`", decode, _, _] = cells(report, "state_code")
      assert decode =~ "WHEN 'active' THEN 0"
      assert decode =~ "WHEN 'deleted' THEN 4"
    end

    test "a column read through a join is attributed to the joined relation", %{report: report} do
      assert [_, "`drawn_legacy.addresses.city`", _, "read only", why] = cells(report, "city")
      assert why =~ "write it through its own resource"
    end

    test "read-only attributes are named with their reason, not counted", %{report: report} do
      assert report =~ "- `city`: Read through a relationship"
      assert report =~ "- `seen_at`: Not stored in legacy at all"
      refute report =~ ~r/\d+ read only/
    end

    test "an unmapped attribute, a constant and the key say what they are", %{report: report} do
      assert [_, "none", "`NULL`", "none", "No provenance for pre-migration rows."] =
               cells(report, "created_by_id")

      assert [_, "none", constant, "none (constant)", _] = cells(report, "tenant_id")
      assert constant =~ "00000000-0000-0000-0000-0000000000fe"

      assert [_, "`drawn_legacy.accounts.id`", key, "derived key", _] = cells(report, "id")
      assert key =~ "uuid_v5"
    end

    test "a pipe in SQL does not break the table", %{report: report} do
      # `||` is concatenation in SQL and a column separator in a Markdown table.
      assert [_attr, _source, transform, _direction, _why] = cells(report, "id")
      assert transform =~ "\\|\\|"
    end

    test "no raw HTML, which Clarity's renderer drops", %{report: report} do
      refute report =~ ~r/<[a-z]+>/
    end
  end

  test "retired and unread legacy columns are named" do
    report = report([Slim])

    assert report =~ "**Phase:** `dual_write` (2 of 4"

    assert report =~
             "Retired (the old application no longer reads): `phone` - Nothing reads the phone number"

    # nick, post_code, email and state belong to the legacy table and nothing maps them.
    assert report =~ ~r/Legacy columns no mapping reads: .*`nick`.*`post_code`/
    refute report =~ ~r/Legacy columns no mapping reads: .*`phone`/
  end

  describe "several resources" do
    setup do
      %{report: report([Account, Slim])}
    end

    test "an index says which resources a legacy relation feeds", %{report: report} do
      assert report =~ "## Legacy relations and what they feed"

      assert report =~
               "| `drawn_legacy.accounts` | `AshStrangler.DiagramTest.Account` | primary |"

      assert report =~ "| `drawn_legacy.accounts` | `AshStrangler.DiagramTest.Slim` | primary |"

      assert report =~
               "| `drawn_legacy.addresses` | `AshStrangler.DiagramTest.Account` | LEFT JOIN as address, read only |"
    end

    test "the summary row names read-only and unmapped attributes and gives the phase", %{
      report: report
    } do
      [account_row] =
        report
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "| `AshStrangler.DiagramTest.Account` | `read"))

      assert account_row =~ "`read_from_legacy`"
      assert account_row =~ "`city`, `seen_at`"
      assert account_row =~ "`created_by_id`"

      assert report =~ "| `AshStrangler.DiagramTest.Slim` | `dual_write` |"
    end

    test "every resource still gets its own full section", %{report: report} do
      assert report =~ "## AshStrangler.DiagramTest.Account\n"
      assert report =~ "## AshStrangler.DiagramTest.Slim\n"
      assert report =~ "`drawn_legacy.accounts.nick`"
    end
  end

  test "domains and applications resolve to their strangled resources" do
    assert Report.for_domains([AshStrangler.DiagramTest.Domain]) =~
             "## AshStrangler.DiagramTest.Slim"

    refute Report.for_domains([AshStrangler.DiagramTest.Domain]) =~ "DiagramTest.Plain"
  end

  test "nothing to report says so rather than rendering an empty page" do
    assert report([AshStrangler.DiagramTest.Plain]) =~ "No resource here has a `strangler` block"
  end
end
