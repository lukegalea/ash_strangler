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
    * a label must survive being a Mermaid label unmangled.

  And one test asserts something is **impossible** rather than correct. 0.1 drew a
  rhombus reading *"source columns not resolved"* when its regex could not work out
  which columns an expression read. There is no such node any more, because lineage
  is read off an expression that was constructed. A test that the node is absent is
  the only way to notice if inference ever creeps back in.
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

    test "a mapping with a derived reverse is bidirectional, labelled with its combinator" do
      # `<-->` is `invertible: :yes`, computed by `AshStrangler.Lens.classify/1`
      # rather than read off an author's `writable?` claim.
      assert compose() =~ "<-->|\"decode\"| n_account__state_code"
    end

    test "a read-only mapping is dotted and carries its own reason" do
      assert compose() =~ "-.->|\"read only - Read through a relationship"
    end

    test "an opaque mapping is a dotted LINE, because it is proven neither way" do
      # The distinction the notation could not make in 0.1, where every `from:`
      # string was uniformly opaque and a read-only mapping and a raw-SQL one drew
      # identically. `-.-` says "no direction was established", where `-.->` says
      # "the forward direction holds and the reverse does not exist".
      assert compose() =~ "-.-|\"opaque - Not stored in legacy at all"
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
    test "a transform is labelled with its combinator, not with truncated SQL" do
      composed = compose()

      # In 0.1 this label was the `from:` string cut to 64 characters, because
      # there was nothing else to say about it -- and a truncated `CASE` is a label
      # that may have dropped an arm, which is a diagram that lies.
      assert composed =~ "t_account__state_code{{\"decode\"}}"
      assert composed =~ "t_account__tenant_id{{\"constant\"}}"
      assert composed =~ "t_account__seen_at{{\"opaque\"}}"
    end

    test "a legacy column carries its type, which the label could not do before the twin" do
      assert compose() =~ "l_drawn_legacy_accounts__email[\"email : String\"]"
      assert compose() =~ "l_drawn_legacy_accounts__state[\"state : Atom\"]"
    end

    test "labels are quoted, because ash_diagram does not quote them" do
      # Quoting is what lets a nested `[...]` and a bare `||` survive at all.
      assert compose() =~ "n_account__id([\"id : UUID PK\"])"
      assert compose() =~ "t_account__id{{\"uuid_v5(ns, 'drawn_legacy.accounts:' || id)\"}}"
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
    test "a relation reached through a relationship gets its own subgraph, named by the relationship" do
      # The alias is the relationship name -- `address` -- because that is what the
      # mapping wrote (`expr(address.city)`). 0.1 took an `as:` string and matched it
      # against the mapping's column text, which is a heuristic over SQL with the
      # same failure mode as the deleted lineage regex.
      sub = subgraph(diagram(), "legacy_drawn_legacy_addresses")

      assert to_string(sub.label) =~ "drawn_legacy.addresses AS address (LEFT JOIN)"
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

    test "there is no unresolved-source node, because lineage cannot fail" do
      # The failure 0.1 degraded from. `Diagram.Sql.columns/2` returned
      # `:unresolved` when its regex found nothing, and the mapping diagram drew a
      # rhombus saying so -- while its OTHER consumer, the entity-relationship hook,
      # degraded the same value to `[]` and the column vanished from every diagram
      # the application drew.
      #
      # `seen_at` here is `expr(fragment("now()"))`: an expression reading no
      # columns at all, which is the case that produced the rhombus. It is now drawn
      # as what it is -- opaque -- and the diagram knows exactly which columns feed
      # it, namely none.
      composed = compose()

      refute composed =~ "source columns not resolved"
      refute composed =~ "u_t_account__seen_at"
      assert composed =~ "t_account__seen_at{{\"opaque\"}}"
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
