# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.LineageTest.IdentityKeyed do
  @moduledoc """
  A resource whose key is passed through rather than derived, so the one edge that
  is genuinely an `IDENTITY` has somewhere to be asserted.

  Defined here rather than borrowed from another test file: ExUnit loads test files
  independently, so a module defined in `sql/view_test.exs` is not reliably loaded
  when this file runs alone.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "identity_keyed"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.LineageTest.Legacy.Rows do
      key :id, from: :row_uuid, strategy: :identity
      map :login, from: :login
    end
  end
end

defmodule AshStrangler.LineageTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.LineageTest.Legacy.Rows
  end
end

defmodule AshStrangler.LineageTest.Legacy.Rows do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.LineageTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "rows"
    schema "lineage_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :row_uuid, :uuid, primary_key?: true, allow_nil?: false
    attribute :login, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.LineageTest do
  @moduledoc """
  The lineage model, over the fixtures that are also the round-trip suite's fixtures.

  Two things are worth testing about a lineage graph, and only one of them is
  obvious.

  The obvious one is that the classification is right — a rename is `IDENTITY`, a
  `decode` is an invertible `TRANSFORMATION`, a read-only expression is masked. Those
  assertions matter because the classification is not decoration: `IDENTITY |
  TRANSFORMATION | MASKED` *is* the invertibility decision, so the diagram and
  `AshStrangler.Info.writes/1` compute from one source instead of agreeing by
  coincidence. A wrong edge here is a wrong writability decision there.

  The one that matters more is that **an unresolved node is unrepresentable**. 0.1
  inferred lineage with a regex over a SQL string and returned `:unresolved` when it
  found nothing, and it had two consumers: `AshStrangler.Diagram.Sql` drew a rhombus
  reading *"source columns not resolved"*, which is at least honest, and
  `AshStrangler.Resource.legacy_columns/1` degraded the same value to `[]` — so a
  column the regex could not parse vanished, silently, from every
  entity-relationship diagram the application drew. Lineage is now
  `AshStrangler.Expr.refs/1` over a tree that was *constructed*, so there is no
  inference to fail. That is a claim about a whole class of value, which is why the
  test for it is a fold over every mapped fixture rather than an example: every
  reference every lens declares has to arrive as an edge, and every edge has to land
  on a node that exists.

  `AshStrangler.Lineage.OpenLineage` is exercised here too rather than in a file of
  its own, because an exporter has nothing of its own to be right about. Its tests
  are assertions that the model's vocabulary survived the reshaping into JSON.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.{Lens, Lineage}
  alias AshStrangler.Lineage.OpenLineage

  @mapped [
    AshStrangler.Test.LegacyUser,
    AshStrangler.Test.DualWriteUser,
    AshStrangler.Test.MixedUser,
    AshStrangler.Demo.Customer,
    AshStrangler.Demo.Organization,
    AshStrangler.Demo.Address,
    AshStrangler.DiagramTest.Account
  ]

  describe "the edge says what the mapping says" do
    test "a rename is IDENTITY, DIRECT and fully invertible" do
      # No transformation at all, so nothing to describe and no `description` to put on
      # the edge. It is also the only classification under which PostgreSQL leaves the
      # view column auto-updatable, which is why the distinction between this and a
      # derived cast is not cosmetic.
      edge = edge!(AshStrangler.Test.LegacyUser, :login)

      assert edge.type == :DIRECT
      assert edge.subtype == :IDENTITY
      assert edge.invertible == :yes
      refute edge.masking?
      assert edge.description == nil
    end

    test "a derived cast is a TRANSFORMATION that is still fully invertible" do
      # `email` is `:string` on the twin and `:ci_string` on the resource, so
      # `AshStrangler.Lens` derives `(email)::citext` — nobody typed `cast:`. It is a
      # transformation because the value's type changes and `:yes` because a cast is a
      # bijection, and the two facts together are what let the mapping stay writable
      # while costing the column its auto-updatability.
      edge = edge!(AshStrangler.Test.LegacyUser, :email)

      assert edge.subtype == :TRANSFORMATION
      assert edge.invertible == :yes
      assert edge.description == "cast"
      assert edge.combinator == :cast
    end

    test "a zone carries the zone in the description, because the zone is the transform" do
      # A label reading "transformation" would be true and useless. The reviewer's
      # question about a naive column read as an instant is *which zone*, and the
      # answer is the only part of the mapping that cannot be recovered from the
      # schema.
      edge = edge!(AshStrangler.Test.LegacyUser, :archived_at)

      assert edge.subtype == :TRANSFORMATION
      assert edge.invertible == :yes
      assert edge.description == "AT TIME ZONE 'UTC'"
    end

    test "a decode is a TRANSFORMATION, fully invertible, and CONDITIONAL" do
      # The mapping 0.1 got wrong. One declaration now yields both directions, so they
      # cannot disagree, and `AshStrangler.Obligations` decides `GetTotal` against the
      # twin's declared value set — which is what makes `:yes` a proof rather than an
      # assertion. `CONDITIONAL` is OpenLineage's INDIRECT subtype for a value that
      # depends on a branch, and it rides alongside the DIRECT classification rather
      # than replacing it.
      edge = edge!(AshStrangler.Test.DualWriteUser, :state_code)

      assert edge.type == :DIRECT
      assert edge.subtype == :TRANSFORMATION
      assert edge.invertible == :yes
      assert edge.transformation == :CONDITIONAL
      refute edge.masking?
    end

    test "a collapse carrying touch() is :semi, and says what it is modulo" do
      # `:semi` is the classification the notation added in v2, and this is the mapping
      # that needs it: round-tripping `:cancelled` cannot recover the original instant,
      # because `touch()` is a declared loss. Without a `touch()` the same decision
      # table is a total bijection — the three columns and four states are otherwise
      # exhaustive — so `:semi` here is carried by the `touch()` and nothing else.
      for edge <- edges!(AshStrangler.Demo.Customer, :status) do
        assert edge.subtype == :TRANSFORMATION
        assert edge.invertible == :semi
        assert edge.transformation == :CONDITIONAL
        assert edge.description == "collapse - invertible modulo a declared default"
        refute edge.masking?
      end

      # Four legacy columns collapse into one attribute, and all three the decision
      # table reads are edges. Drawing only the first would describe a lifecycle that
      # depends on one boolean.
      assert edges!(AshStrangler.Demo.Customer, :status) |> Enum.map(& &1.from) |> Enum.sort() ==
               [
                 "l_demo_legacy_accounts__approved_at",
                 "l_demo_legacy_accounts__cancelled_at",
                 "l_demo_legacy_accounts__is_deleted"
               ]
    end

    test "a read-only expression is masked, and carries its own because: as the label" do
      # `masking?` is the third arm of the invertibility classification, not a separate
      # flag: a masked mapping has no reverse, so `invertible` is `:no` and
      # `AshStrangler.Info.writes/1` reads the same fact. The `because:` is on the edge
      # because carrying *why* a value cannot travel back is half the point of drawing
      # the mapping at all.
      for edge <- edges!(AshStrangler.Test.LegacyUser, :full_name) do
        assert edge.masking?
        assert edge.invertible == :no
        assert edge.description =~ "read only - Not decomposable: 'de la Cruz' splits wrong"
      end
    end

    test "an opaque fragment is masked and says so, and still names the column it reads" do
      # Opaque and read-only are different states and the label distinguishes them.
      # `read only` means a reverse could exist and was declined; `opaque` means the
      # transform itself is unproven, because `AshStrangler.Obligations` cannot evaluate
      # a `fragment` in the BEAM and has to re-emit its obligations as SQL assertions.
      #
      # The important half is what it still knows. `expr(fragment("upper(?::text)",
      # state))` reads `state`, exactly, because the tree was constructed — where 0.1's
      # regex over the same SQL would have had to guess.
      edge = edge!(AshStrangler.Test.MixedUser, :state_label)

      assert edge.masking?
      assert edge.invertible == :no
      assert edge.description =~ "opaque - "
      assert Lens.by_attribute(AshStrangler.Test.MixedUser)[:state_label].opaque?
      assert node!(AshStrangler.Test.MixedUser, edge.from).column == "state"
    end

    test "a read-only concat is masked, and the declared opt-out is what makes it so" do
      # `concat` is a partial isomorphism — invertible modulo the separator, since
      # 'de la Cruz' splits wrong — so the combinator alone would classify `:semi`.
      # Both `concat`s in these fixtures declare `read_only?: true` with that reason,
      # and `AshStrangler.Lens.apply_read_only/2` runs *after* the lens is built, so the
      # declaration wins and the edge is masked.
      #
      # That ordering is deliberate rather than incidental: building the reverse first
      # is what lets `AshStrangler.Verifiers.VerifyDerivedWritability` see that a
      # reverse *was* constructible and refuse a `read_only?` that is not telling the
      # truth. In 0.1 nothing objected to a mapping claiming "not decomposable" about
      # something perfectly decomposable.
      lens = Lens.by_attribute(AshStrangler.Demo.Customer)[:full_name]

      assert lens.combinator == :concat
      assert lens.read_only?

      for edge <- edges!(AshStrangler.Demo.Customer, :full_name) do
        assert edge.masking?
        assert edge.invertible == :no
      end
    end

    test "a derived key is DIRECT and a TRANSFORMATION, not INDIRECT" do
      # Worth spelling out, because the tempting reading is the other one: the modern
      # id is a UUIDv5 rather than a copy, so it feels like the legacy column
      # *determines* the value without flowing into it, which is what `INDIRECT`
      # means.
      #
      # It is not. `uuid_generate_v5(ns, 'legacy.users:' || id::text)` reads `id` and
      # computes the output from it — the value flows in, hashed. `INDIRECT` is for a
      # column that influenced which rows exist rather than what a value is: a
      # `GROUP BY` key, a join predicate, a filter. That is also why the facet's
      # INDIRECT subtypes are exactly `JOIN | GROUP_BY | FILTER | SORT | WINDOW |
      # CONDITIONAL` and `IDENTITY`/`TRANSFORMATION` are DIRECT ones — pairing
      # `INDIRECT` with either is not a judgement call, it is invalid, and a strict
      # validator rejects it.
      #
      # `:no` is right for a different reason and is unaffected: nothing writes a
      # value back through a hash.
      edge = edge!(AshStrangler.Test.LegacyUser, :id)

      assert edge.type == :DIRECT
      assert edge.subtype == :TRANSFORMATION
      assert edge.invertible == :no
      assert edge.description == "key"
    end

    test "an :identity key is DIRECT and IDENTITY, because the value really is copied" do
      edge = edge!(AshStrangler.LineageTest.IdentityKeyed, :id)

      assert edge.type == :DIRECT
      assert edge.subtype == :IDENTITY
    end
  end

  describe "a column read through a relationship" do
    test "lands on the joined relation's node, not on the primary relation's" do
      # The subtle one, and the reason `AshStrangler.Expr.refs/1` re-roots rather than
      # folds. `map :city, from: expr(address.city)` reads `drawn_legacy.addresses`,
      # and `city` is the kind of column that plausibly exists on both relations — so
      # an edge attributed to the primary table would be drawn confidently and be
      # wrong, which is worse than a missing edge.
      edge = edge!(AshStrangler.DiagramTest.Account, :city)
      source = node!(AshStrangler.DiagramTest.Account, edge.from)

      assert source.relation == "drawn_legacy.addresses"
      assert source.column == "city"
      refute source.relation == "drawn_legacy.accounts"
    end

    test "is marked JOIN, so the fan-out is visible rather than implied" do
      # A joined read can multiply rows, which is a property of the *data* rather than
      # of the declaration. `JOIN` is what says the edge crosses a relation boundary,
      # and it is what makes a reader ask about cardinality.
      assert edge!(AshStrangler.DiagramTest.Account, :city).transformation == :JOIN
    end

    test "the joined relation gets its own node, typed from the joined twin" do
      {nodes, _edges} = Lineage.for_resource(AshStrangler.DiagramTest.Account)

      relations = nodes |> Enum.filter(&(&1.side == :legacy)) |> Enum.map(& &1.relation)

      assert "drawn_legacy.accounts" in relations
      assert "drawn_legacy.addresses" in relations
    end
  end

  describe "an unresolved node is unrepresentable" do
    test "every reference every lens declares arrives as an edge" do
      # The sharpest form of the claim. `column_node/2` returns `nil` when a source
      # cannot be resolved against the twin, and a `nil` source silently drops its
      # edge — which is the one remaining shape of the 0.1 failure. Counting sources
      # against edges is what proves none of the fixtures drops one, and it is a
      # property of the whole model rather than an example.
      for resource <- @mapped do
        declared =
          resource
          |> Lens.for_resource()
          |> Enum.flat_map(& &1.sources)
          |> length()

        {_nodes, edges} = Lineage.for_resource(resource)

        assert length(edges) == declared,
               "#{inspect(resource)} declares #{declared} source references but produced " <>
                 "#{length(edges)} edges"
      end
    end

    test "every edge lands on a node that exists, on both ends" do
      for resource <- @mapped do
        {nodes, edges} = Lineage.for_resource(resource)
        ids = MapSet.new(nodes, & &1.id)

        for edge <- edges do
          assert MapSet.member?(ids, edge.from),
                 "#{inspect(resource)}: dangling from #{edge.from}"

          assert MapSet.member?(ids, edge.to), "#{inspect(resource)}: dangling to #{edge.to}"
        end
      end
    end

    test "by_attribute/1 resolves every edge, which is where a dangling one would raise" do
      # `by_attribute/1` looks each edge's source up with `Map.fetch!/2`, so it is the
      # function a dangling edge would take down — and it is the function both exporters
      # and `AshStrangler.Resource`'s entity-relationship hook go through. Calling it
      # over every fixture is the cheapest total check there is.
      for resource <- @mapped do
        by_attribute = Lineage.for_resources([resource]) |> Lineage.by_attribute()

        for {attribute, sources} <- by_attribute do
          assert is_atom(attribute)

          for {node, edge} <- sources do
            assert node.side == :legacy
            assert is_binary(node.relation) and node.relation != ""
            assert is_binary(node.column) and node.column != ""
            assert edge.attribute == attribute
          end
        end
      end
    end

    test "no node describes itself as unknown or unresolved" do
      # 0.1's rhombus read "source columns not resolved". There is no value in the model
      # that can render it: a node is a `{side, relation, column}` triple read off a
      # typed twin, and a mapping with no legacy source contributes no source node at
      # all rather than an unresolved one.
      %Lineage{nodes: nodes} = Lineage.for_resources(@mapped)

      for node <- nodes do
        refute node.relation =~ ~r/unresolved|unknown/i
        refute node.column =~ ~r/unresolved|unknown/i
        assert node.side in [:legacy, :new]
      end
    end

    test "a mapping with no legacy source contributes a target node and no edges" do
      # The positive half of the same claim, and the distinction the old `:unresolved`
      # could not draw. A `constant` and an `unmapped` have nothing upstream, and saying
      # so is a fact the mapping declared — not a failure to work one out.
      {nodes, edges} = Lineage.for_resource(AshStrangler.Test.LegacyUser)

      for attribute <- [:organization_id, :created_by_id] do
        assert Enum.any?(nodes, &(&1.side == :new and &1.column == to_string(attribute)))
        assert Enum.filter(edges, &(&1.attribute == attribute)) == []
      end
    end
  end

  describe "for_resources/1" do
    test "resources without a strangler block are skipped rather than drawn empty" do
      lineage =
        Lineage.for_resources([AshStrangler.DiagramTest.Account, AshStrangler.DiagramTest.Plain])

      assert lineage.resources == [AshStrangler.DiagramTest.Account]
    end

    test "three resources over one legacy table share its column nodes" do
      # The case this package exists for. Modelling `legacy.users` three times would
      # hide exactly the fan-out worth seeing — that one wide legacy table is being
      # read by three modern resources — which is the fact a reviewer most needs and
      # the one a per-resource diagram cannot show.
      resources = [
        AshStrangler.Test.LegacyUser,
        AshStrangler.Test.DualWriteUser,
        AshStrangler.Test.MixedUser
      ]

      %Lineage{nodes: nodes, edges: edges} = Lineage.for_resources(resources)

      legacy = Enum.filter(nodes, &(&1.side == :legacy))

      assert Enum.uniq_by(legacy, & &1.id) == legacy
      assert Enum.all?(legacy, &(&1.relation == "legacy.users"))

      login = Enum.find(legacy, &(&1.column == "login"))

      assert edges |> Enum.filter(&(&1.from == login.id)) |> length() == 3
    end
  end

  describe "AshStrangler.Lineage.OpenLineage" do
    test "the facet is the model's own vocabulary, reshaped rather than reclassified" do
      # The property that keeps the exporter free. Every string in a transformation
      # comes off a `%Lineage.Edge{}` field, so there is no second classification here
      # to drift from the first — and if one ever appears, the diagram and the
      # writability decision have gone back to agreeing by coincidence.
      facet = OpenLineage.facet(AshStrangler.Test.DualWriteUser)

      assert facet["_producer"] =~ "ash_strangler"
      assert facet["_schemaURL"] =~ "ColumnLineageDatasetFacet"

      assert facet["fields"]["login"]["inputFields"] == [
               %{
                 "namespace" => namespace(),
                 "name" => "legacy.users",
                 "field" => "login",
                 "transformations" => [
                   %{
                     "type" => "DIRECT",
                     "subtype" => "IDENTITY",
                     "description" => nil,
                     "masking" => false
                   }
                 ]
               }
             ]
    end

    test "a masked field carries masking: true and the reason the mapping gave" do
      # The rows a data owner actually reads. `AshStrangler` makes a column that cannot
      # travel back explicit and reasoned rather than inferred, and exporting the reason
      # puts it in front of the only reader who can tell whether it is true.
      facet = OpenLineage.facet(AshStrangler.Test.LegacyUser)

      for input <- facet["fields"]["full_name"]["inputFields"] do
        assert [%{"masking" => true, "description" => description}] = input["transformations"]
        assert description =~ "Not decomposable"
      end
    end

    test "an INDIRECT subtype rides alongside the DIRECT one rather than replacing it" do
      # The facet allows several transformations per input field, which is what lets a
      # `decode` say both things that are true of it: the value is transformed, and the
      # transformation is conditional.
      [_direct, indirect] =
        OpenLineage.facet(AshStrangler.Test.DualWriteUser)["fields"]["state_code"][
          "inputFields"
        ]
        |> hd()
        |> Map.fetch!("transformations")

      assert indirect == %{
               "type" => "INDIRECT",
               "subtype" => "CONDITIONAL",
               "description" => "decode",
               "masking" => false
             }
    end

    test "a joined read names the joined relation, so the graph connects to the right dataset" do
      # A namespace or relation name that disagrees with the rest of a catalogue does
      # not fail; it quietly produces a second dataset nothing is connected to. Naming
      # the *joined* relation here is the same correctness question as the node test
      # above, one layer out.
      [input] =
        OpenLineage.facet(AshStrangler.DiagramTest.Account)["fields"]["city"]["inputFields"]

      assert input["name"] == "drawn_legacy.addresses"
      assert input["field"] == "city"
      assert Enum.any?(input["transformations"], &(&1["subtype"] == "JOIN"))
    end

    test "a structural mapping is listed with no inputFields, which is not the same as absent" do
      # Deliberately a present field with an empty list. Omitting it would say *lineage
      # unknown* — the statement 0.1's regex made when it gave up, and the one this
      # model exists to make unrepresentable. An empty `inputFields` says *this column
      # has no legacy source*, which is what `constant` and `unmapped` declare out loud.
      fields = OpenLineage.facet(AshStrangler.Test.LegacyUser)["fields"]

      assert fields["organization_id"] == %{"inputFields" => []}
      assert fields["created_by_id"] == %{"inputFields" => []}
    end

    test "the dataset is named after the modern relation and the repo's connection" do
      dataset = OpenLineage.dataset(AshStrangler.Test.LegacyUser)

      assert dataset["name"] == "strangler.users"
      assert dataset["namespace"] == namespace()
      assert Map.has_key?(dataset["facets"], "columnLineage")
    end

    test "the namespace is overridable, because a catalogue behind a bouncer is named after neither" do
      dataset =
        OpenLineage.dataset(AshStrangler.Test.LegacyUser, namespace: "postgres://prod:6432")

      assert dataset["namespace"] == "postgres://prod:6432"

      for {_field, %{"inputFields" => inputs}} <- dataset["facets"]["columnLineage"]["fields"],
          input <- inputs do
        assert input["namespace"] == "postgres://prod:6432"
      end
    end

    test "datasets/2 drops resources that carry no mapping" do
      names =
        [AshStrangler.DiagramTest.Account, AshStrangler.DiagramTest.Plain]
        |> OpenLineage.datasets()
        |> Enum.map(& &1["name"])

      assert names == ["drawn.accounts"]
    end

    test "the whole export is JSON, which is the only reason any of this is worth doing" do
      # An export a lineage catalogue cannot ingest is a diagram with extra steps.
      json = OpenLineage.encode!(@mapped)

      assert {:ok, decoded} = Jason.decode(json)
      assert length(decoded) == length(@mapped)

      assert Enum.all?(decoded, fn dataset ->
               is_binary(dataset["name"]) and
                 is_map(dataset["facets"]["columnLineage"]["fields"])
             end)
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp edges!(resource, attribute) do
    {_nodes, edges} = Lineage.for_resource(resource)

    case Enum.filter(edges, &(&1.attribute == attribute)) do
      [] -> flunk("#{inspect(resource)} has no lineage edge for #{inspect(attribute)}")
      found -> found
    end
  end

  defp edge!(resource, attribute) do
    case edges!(resource, attribute) do
      [edge] -> edge
      many -> flunk("expected one edge for #{inspect(attribute)}, got #{length(many)}")
    end
  end

  defp node!(resource, id) do
    {nodes, _edges} = Lineage.for_resource(resource)

    Enum.find(nodes, &(&1.id == id)) || flunk("no node #{id}")
  end

  # Read from the repo rather than written down, so the assertions are about the
  # exporter deriving the namespace from the connection and not about this file
  # agreeing with `config/test.exs`.
  defp namespace do
    config = AshStrangler.TestRepo.config()

    "postgres://#{Keyword.fetch!(config, :hostname)}:#{Keyword.fetch!(config, :port)}"
  end
end
