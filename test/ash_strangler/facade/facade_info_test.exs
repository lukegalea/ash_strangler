# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.InfoTest do
  @moduledoc """
  The declaration is readable, hashable and drawable: the estate places every
  source attribute, the version hash is content-addressed, and the hop chain
  reads hop by hop — a facade over a facade over an owned resource, a facade
  over a strangled resource, and a hop that names its dataset.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.{
    Facade.Info,
    MappingVersion,
    Test.Facades.DocumentView,
    Test.Facades.UserContact,
    Test.Facades.WorkItem,
    Test.Facades.WorkItemRow
  }

  describe "introspection" do
    test "the declaration reads back" do
      assert Info.source(WorkItem) == AshStrangler.Test.Facades.Task
      assert Info.read_action(WorkItem) == :read
      assert Info.read_action(%{facade: nil}) == :read

      assert [%{name: :finish, via: :complete, sets: [state: :finished], accepts: []}] =
               Info.writes(WorkItem) |> Enum.filter(&(&1.name == :finish))

      assert [%{attribute: :internal_notes, because: reason}] = Info.hidden(WorkItem)
      assert reason =~ "vocabulary"
      assert [%{attribute: :legacy_ref}] = Info.deferred(WorkItem)

      assert Enum.map(Info.entries(WorkItem), & &1.attribute) == [
               :id,
               :org_id,
               :title,
               :state,
               :effort_minutes
             ]
    end

    test "the lenses are the facade's, built over the source's fields" do
      lenses = Info.lenses(WorkItem)

      assert Map.keys(lenses) |> Enum.sort() == [:effort_minutes, :id, :org_id, :state, :title]
      assert lenses[:title].combinator == :rename
      assert lenses[:state].combinator == :decode
      assert lenses[:state].invertible == :yes
    end
  end

  describe "the estate" do
    test "every source attribute is in exactly one list" do
      estate = Info.estate(WorkItem)

      assert estate.exposed |> Enum.sort() == [:estimate_minutes, :id, :name, :org_id, :status]
      assert estate.hidden == [:internal_notes]
      assert estate.deferred == [:legacy_ref]
      assert estate.unplaced == []
    end
  end

  describe "the mapping version" do
    test "is stable across calls and 64 hex characters" do
      version = Info.mapping_version(WorkItem)

      assert version =~ ~r/\A[0-9a-f]{64}\z/
      assert Info.mapping_version(WorkItem) == version
    end

    test "changes when a mapping changes, and only that hop's version" do
      variant = probe_over_work_item("map :label, from: :org_id")

      # The probe's own hop hashes its own declaration: changed mapping,
      # changed version. The hop below it — the WorkItem's — is untouched.
      assert Info.mapping_version(variant) != Info.mapping_version(WorkItemRow)

      assert Info.mapping_versions(WorkItemRow) != Info.mapping_versions(variant)
      # The WorkItem hop is the second entry of both chains, and does not move.
      [_, work_item_from_chain, _] = Info.mapping_versions(WorkItemRow)
      [_, work_item_from_variant, _] = Info.mapping_versions(variant)
      assert work_item_from_chain == work_item_from_variant
      assert work_item_from_chain == Info.mapping_version(WorkItem)
    end

    test "the version is computed the way the strangler hashes" do
      # One hash function for every hop: the facade's version and a strangled
      # mapping's are the same kind of value, comparable down a chain.
      assert String.length(Info.mapping_version(WorkItem)) ==
               String.length(MappingVersion.hash(AshStrangler.Test.LegacyUser))
    end

    defp probe_over_work_item(label_mapping) do
      name = "AshStrangler.Facade.InfoTest.Probe#{System.unique_integer([:positive])}"

      {result, _io} =
        with_io(:stderr, fn ->
          Code.eval_string("""
          defmodule #{name} do
            use Ash.Resource,
              domain: AshStrangler.Test.Facades,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshStrangler.Facade]

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
              attribute :label, :string, public?: true
            end

            facade do
              source AshStrangler.Test.Facades.WorkItem

              map :id, from: :id
              #{label_mapping}

              hide :state, because: "The probe shows one fact."
              hide :org_id, because: "The probe shows one fact."
              defer :effort_minutes
            end
          end
          """)
        end)

      {{:module, module, _, _}, _binding} = result
      module
    end
  end

  describe "the hop chain" do
    test "a facade over a facade over an owned resource reads hop by hop" do
      [outer, inner, owned] = Info.hops(WorkItemRow)

      assert outer.kind == :facade
      assert outer.resource == WorkItemRow
      assert outer.source == WorkItem
      assert outer.dataset == nil
      assert outer.mapping_version =~ ~r/\A[0-9a-f]{64}\z/

      assert inner.kind == :facade
      assert inner.resource == WorkItem
      assert inner.source == AshStrangler.Test.Facades.Task

      assert owned.kind == :owned
      assert owned.resource == AshStrangler.Test.Facades.Task
      assert owned.source == nil
      assert owned.mapping_version == nil
      assert owned.edges == []
    end

    test "a facade over a strangled source continues into the twin" do
      [facade_hop, strangled] = Info.hops(UserContact)

      assert facade_hop.kind == :facade
      assert facade_hop.source == AshStrangler.Test.LegacyUser

      assert strangled.kind == :strangled
      assert strangled.resource == AshStrangler.Test.LegacyUser
      assert strangled.source == AshStrangler.Test.Legacy.Users
      assert strangled.mapping_version == MappingVersion.hash(AshStrangler.Test.LegacyUser)
    end

    test "an owned source with a Postgres data layer names its dataset" do
      [facade_hop, owned] = Info.hops(DocumentView)

      assert facade_hop.dataset == nil

      namespace = owned.dataset.namespace
      name = owned.dataset.name

      assert namespace == "postgres://localhost:5432"
      assert name =~ ~r/\A[^.]+\.verified\.facade_documents\z/
    end

    test "the strangled hop names the twin's dataset" do
      [_facade_hop, strangled] = Info.hops(UserContact)

      assert strangled.dataset.namespace == "postgres://localhost:5432"
      assert strangled.dataset.name =~ ~r/\A[^.]+\.legacy\.users\z/
    end

    test "facade edges carry the lens classification" do
      [outer, _inner, _owned] = Info.hops(WorkItemRow)

      by_attribute = Map.new(outer.edges, &{&1.attribute, &1})

      assert by_attribute[:label].subtype == :IDENTITY
      assert by_attribute[:label].invertible == :yes

      # The id lens is a rename too; both carry a source node at one end and a
      # facade node at the other.
      assert by_attribute[:id].combinator == :rename
      assert by_attribute[:id].from =~ ~r/\As_.*id\z/
      assert by_attribute[:id].to =~ ~r/\Af_.*id\z/
    end

    test "mapping_versions lists one version per hop, in hop order" do
      versions = Info.mapping_versions(WorkItemRow)
      hops = Info.hops(WorkItemRow)

      assert length(versions) == length(hops)

      assert Enum.zip(versions, hops)
             |> Enum.all?(fn {version, hop} -> version == hop.mapping_version end)
    end
  end

  describe "reading a source action's changes" do
    @set_note {Ash.Resource.Change.SetAttribute, [attribute: :notes, value: {:_arg, :note}]}
    @wrapper :"Elixir.AshEvents.Events.ReplayChangeWrapper"

    # `ash_events` wraps each change of an event-sourced source, keeping it as an
    # `Ash.Resource.Change` struct; the wrapped pair itself is read too.
    test "a change wrapped for replay reads as the change it wraps, in either shape" do
      struct_wrapped = %{change: {@wrapper, [change: %{change: @set_note}]}}
      pair_wrapped = %{change: {@wrapper, [change: @set_note]}}
      plain = %{change: @set_note}

      for change <- [struct_wrapped, pair_wrapped, plain] do
        action = %{changes: [change]}
        assert Info.changes(action) == [@set_note]
        assert Info.set_attributes(action) == [notes: {:_arg, :note}]
        assert Info.argument_for(action, :notes) == :note
        assert Info.argument_for(action, :title) == nil
      end
    end
  end
end
