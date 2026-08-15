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

  test "the primary relation edge counts the mappings and the one-way ones" do
    # login, nickname, phone, postcode, email, state_code and seen_at read from
    # the primary relation; only seen_at is read-only. `city` belongs to the
    # join and must not be counted here.
    assert compose([Account]) =~ "<-->|\"7 mapped, 1 read only\"| res_account"
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
