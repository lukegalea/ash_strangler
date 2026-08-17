# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Diagram.OverviewTest do
  @moduledoc """
  The overview answers "what shape is this migration" rather than "what happens
  to this column", so what it must get right is the counting and the direction —
  how many mappings a pair carries, how many of them are one-way, and which
  relations are joined rather than primary.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.Diagram.Overview
  alias AshStrangler.DiagramTest.Account

  defp compose(resources),
    do: resources |> Overview.for_resources() |> AshDiagram.compose() |> to_string()

  test "one node per relation and one per resource" do
    composed = compose([Account])

    assert composed =~ "rel_drawn_legacy_accounts[(\"drawn_legacy.accounts\")]"
    assert composed =~ "rel_drawn_legacy_addresses[(\"drawn_legacy.addresses\")]"
    assert composed =~ "res_account["
  end

  test "the resource node carries its view and its write mode" do
    assert compose([Account]) =~ "Account - drawn.accounts (view) - writes: triggers"
  end

  test "the primary relation edge counts only the mappings that read from it" do
    # login, nickname, phone, postcode, email and state_code. `city` belongs to the
    # joined relation and must not be counted here.
    #
    # `seen_at`, `tenant_id` and `created_by_id` are not counted either, and that is
    # the interesting case: a `fragment("now()")`, a `constant` and an `unmapped`
    # read NO legacy column, so attributing them to a relation would claim it feeds
    # something it does not. In 0.1 this distinction could not be drawn -- an
    # expression's sources were guessed from its text, so a mapping reading nothing
    # was indistinguishable from one whose sources the regex failed on.
    assert compose([Account]) =~ "<-->|\"6 mapped\"| res_account"
  end

  test "a joined relation is dotted, named as a join, and always read-only" do
    assert compose([Account]) =~ "-.->|\"LEFT JOIN - 1 mapped, read only\"| res_account"
  end

  test "the subgraph title carries the phase" do
    assert compose([Account]) =~ "The strangled model - phase: read_from_legacy"
  end

  test "several resources over one table share the relation node" do
    composed = compose([AshStrangler.Demo.Customer, AshStrangler.Demo.Organization])

    assert composed =~ "res_customer"
    assert composed =~ "res_organization"
    # One table, drawn once -- the fan-out is the point of the picture.
    assert composed |> String.split("rel_demo_legacy_accounts[(") |> length() == 2
  end

  test "resources without a strangler block are skipped" do
    assert %{entries: [_legacy, _strangled]} =
             Overview.for_resources([AshStrangler.DiagramTest.Plain])
  end
end
