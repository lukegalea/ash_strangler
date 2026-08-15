# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Diagram.MappingTest do
  @moduledoc """
  The diagram is generated from the mapping, so these are assertions about the
  mapping's *meaning* rather than about pixels.

  Three of them encode findings that cost a render each to discover, and every
  one of them fails silently rather than loudly when it regresses — which is why
  they are pinned here:

    * every edge must point legacy to new, because one edge pointing back
      reverses the layout ranking and Mermaid draws the whole diagram mirrored;
    * the invisible `~~~` chains must be emitted, because Mermaid ignores a
      subgraph's `direction` as soon as a node in it has an edge leaving the
      subgraph, which is every node here;
    * SQL must survive the label unmangled.
  """

  use ExUnit.Case, async: true

  alias AshDiagram.Flowchart.Edge
  alias AshDiagram.Flowchart.Node
  alias AshDiagram.Flowchart.Subgraph
  alias AshStrangler.Diagram.Mapping
  alias AshStrangler.DiagramTest.Account

  defp diagram(options \\ []), do: Mapping.for_resources([Account], options)

  defp compose(options \\ []), do: options |> diagram() |> AshDiagram.compose() |> to_string()

  defp edges(diagram), do: Enum.filter(diagram.entries, &is_struct(&1, Edge))

  defp subgraph(diagram, id) do
    Enum.find(diagram.entries, fn
      %Subgraph{id: ^id} -> true
      _ -> false
    end)
  end

  describe "direction" do
    test "every edge points from legacy to new" do
      # The whole diagram is mirrored by a single edge pointing the other way,
      # so a write-back is drawn as a bidirectional edge rather than a reversed
      # one. Nothing in the resource subgraph may be the source of an edge.
      for %Edge{from: from} <- edges(diagram()) do
        refute String.starts_with?(to_string(from), "n_"),
               "edge originates on the new side: #{to_string(from)}"
      end
    end

    test "a write-back is bidirectional and names the column it writes into" do
      assert compose() =~ "<-->|\"write -> state\"|"
    end

    test "a read-only mapping is dotted and carries its own reason" do
      assert compose() =~ "-.->|\"read only - Read from a joined relation"
    end
  end

  describe "ordering" do
    test "each subgraph chains its nodes with invisible edges" do
      for id <- ["legacy_drawn_legacy_accounts", "resource_account"] do
        sub = subgraph(diagram(), id)
        nodes = Enum.filter(sub.entries, &is_struct(&1, Node))
        chain = Enum.filter(sub.entries, &match?(%Edge{type: :invisible}, &1))

        assert length(chain) == length(nodes) - 1
      end
    end
  end

  describe "labels" do
    test "SQL survives the label unmangled" do
      composed = compose()

      assert composed =~ "CASE state WHEN 'active' THEN 0 ELSE 1 END"
      assert composed =~ "'00000000-0000-0000-0000-0000000000fe'::uuid"
    end

    test "labels are quoted, because ash_diagram does not quote them" do
      # Quoting is what lets a nested `[...]` and a bare `||` survive at all.
      assert compose() =~ "l_drawn_legacy_accounts__email[\"email\"]"
      assert compose() =~ "n_account__id([\"id : UUID PK\"])"
    end
  end

  describe "bundling" do
    test "collapses plain 1:1 mappings and names them" do
      composed = compose()

      assert composed =~ "4 columns mapped 1:1"
      assert composed =~ "nick -> nickname"
      # A bundled attribute must not also get a node of its own, or Mermaid
      # places the second declaration outside the subgraph.
      refute composed =~ "n_account__login"
    end

    test "verbose? draws them individually instead" do
      composed = compose(verbose?: true)

      refute composed =~ "columns mapped 1:1"
      assert composed =~ "n_account__login"
    end
  end

  describe "constructs" do
    test "a joined relation gets its own subgraph, labelled with the join type" do
      sub = subgraph(diagram(), "legacy_drawn_legacy_addresses")

      assert to_string(sub.label) =~ "drawn_legacy.addresses AS addr (LEFT JOIN)"
    end

    test "a constant is a source-less transform with a thick edge" do
      assert compose() =~ "==>|\"constant\"| n_account__tenant_id"
    end

    test "an unmapped attribute is drawn as NULL, with the reason" do
      assert compose() =~ "-.->|\"unmapped - No provenance for pre-migration rows.\"|"
    end

    test "the derived key is a transform, not a plain edge" do
      assert compose() =~ "t_account__id{{\"uuid_v5(ns, 'drawn_legacy.accounts:' || id)\"}}"
    end

    test "an expression with no resolvable source says so rather than drawing nothing" do
      composed = compose()

      assert composed =~ "source columns not resolved"
      assert composed =~ "u_t_account__seen_at"
    end
  end

  describe "selection" do
    test "resources without a strangler block are skipped" do
      assert %{entries: []} = Mapping.for_resources([AshStrangler.DiagramTest.Plain])
    end

    test "a domain draws only the resources that are mapped" do
      composed =
        [AshStrangler.DiagramTest.Domain]
        |> Mapping.for_domains()
        |> AshDiagram.compose()
        |> to_string()

      assert composed =~ "resource_account"
      refute composed =~ "resource_plain"
    end
  end
end
