# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.QuotedRelationTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.QuotedRelationTest.Owners
    resource AshStrangler.QuotedRelationTest.Items
  end
end

defmodule AshStrangler.QuotedRelationTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.QuotedRelationTest.ReadItem
    resource AshStrangler.QuotedRelationTest.WriteItem
    resource AshStrangler.QuotedRelationTest.MixedView
    resource AshStrangler.QuotedRelationTest.LedgerItem
    resource AshStrangler.QuotedRelationTest.Reversed
  end
end

defmodule AshStrangler.QuotedRelationTest.Owners do
  @moduledoc "A legacy relation whose name is mixed case, reached through a join."
  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "Mixed_Owners"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :label, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.QuotedRelationTest.Items do
  @moduledoc "A legacy relation whose name is mixed case, with a mixed-case column the join reads."
  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "Mixed_Items"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :name, :string
    attribute :owner_id, :integer, source: :Owner_Id
  end

  relationships do
    belongs_to :owner, AshStrangler.QuotedRelationTest.Owners do
      source_attribute :owner_id
      destination_attribute :id
      define_attribute? false
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.QuotedRelationTest.ReadItem do
  @moduledoc "A read-only view over the mixed-case relation, joined to a second one."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "read_items"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
    attribute :owner_label, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.QuotedRelationTest.Items do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :name, from: :name

      map :owner_label,
        from: expr(owner.label),
        read_only?: true,
        because: "Read through a relationship."
    end
  end

  def namespace, do: @namespace
end

defmodule AshStrangler.QuotedRelationTest.WriteItem do
  @moduledoc "The same relation, written through generated triggers."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "write_items"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.QuotedRelationTest.Items do
      writes :triggers

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :name, from: :name
    end
  end
end

defmodule AshStrangler.QuotedRelationTest.MixedView do
  @moduledoc "A view whose own table name is mixed case, over the mixed-case legacy relation."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "Mixed_View"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.QuotedRelationTest.Items do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      coalesce :name, from: :name, default: "none"
    end
  end
end

defmodule AshStrangler.QuotedRelationTest.Reversed do
  @moduledoc "The reverse view at :read_from_new, which takes the mixed-case relation's name."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "reversed_items"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :legacy_id, :integer, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_new

    source AshStrangler.QuotedRelationTest.Items do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :name, from: :name

      unmapped [:legacy_id], as: :null, because: "Carried by the backfill, not projected."
      retired [:owner_id], because: "Nothing reads the owner any more."
    end
  end
end

defmodule AshStrangler.QuotedRelationTest.LedgerItem do
  @moduledoc "A ledger-enabled mapping over the mixed-case relation, for the observation baseline."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.QuotedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "ledger_items"
    schema "qrel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.QuotedRelationTest.Items do
      notify? true
      ledger? true
      notify_channel "ash_strangler_quoted_relation_ledger"

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :name, from: :name
    end
  end
end

defmodule AshStrangler.QuotedRelationTest.MixedUnion do
  @moduledoc "A union over the mixed-case relation."
  use AshStrangler.Union

  union do
    schema "qrel"
    view "mixed_union"

    column :name, :string

    legacy :items do
      twin AshStrangler.QuotedRelationTest.Items
      phase :dual_write
      refused_because "the legacy system still owns deletes"
      key :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      map :name, from: :name
    end

    owned :native
  end
end

defmodule AshStrangler.QuotedRelationTest.Keys do
  @moduledoc false
  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x0C12
    logical(:mixed_row, 0x010)
  end
end

defmodule AshStrangler.QuotedRelationTest.MixedDerived do
  @moduledoc "A derived view over the mixed-case relation."
  use AshStrangler.Derived

  derived do
    schema "qrel"
    view "mixed_derived"
    twin AshStrangler.QuotedRelationTest.Items
    registry(AshStrangler.QuotedRelationTest.Keys)
    kind :mixed_row
    from [:id]

    column :item, :integer, null?: false
    column :label, :string

    slot :named do
      filter expr(not is_nil(name))
      map :item, from: :id
      map :label, from: :name
    end
  end
end

defmodule AshStrangler.QuotedRelationTest do
  @moduledoc """
  A legacy relation whose name is mixed case is spelled through the printer's
  identifier rule wherever the generated SQL names it.

  PostgreSQL folds an unquoted identifier to lowercase, so `legacy.Mixed_Items`
  reads `legacy.mixed_items`. Everything here runs against real tables named
  `qrel."Mixed_Items"` and `qrel."Mixed_Owners"`: the view, the join, the key
  index and its drop, and the `INSTEAD OF` triggers.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Migration

  alias AshStrangler.Observation.Baseline

  alias AshStrangler.QuotedRelationTest.{
    Items,
    LedgerItem,
    MixedDerived,
    MixedUnion,
    MixedView,
    ReadItem,
    Reversed,
    WriteItem
  }

  alias AshStrangler.Twin

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
      TestRepo.query!("DROP SCHEMA IF EXISTS qrel CASCADE", [])
      TestRepo.query!("CREATE SCHEMA qrel", [])

      TestRepo.query!(
        ~s|CREATE TABLE qrel."Mixed_Owners" (id bigserial PRIMARY KEY, label text)|,
        []
      )

      TestRepo.query!(
        """
        CREATE TABLE qrel."Mixed_Items" (
          id bigserial PRIMARY KEY,
          name text,
          "Owner_Id" bigint
        )
        """,
        []
      )

      for resource <- [ReadItem, WriteItem, MixedView, LedgerItem],
          statement <- Migration.statements(resource) do
        TestRepo.query!(statement.up, [])
      end
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!("DROP SCHEMA IF EXISTS qrel CASCADE", [])
      end)
    end)

    :ok
  end

  defp items,
    do: TestRepo.query!(~s|SELECT id, name FROM qrel."Mixed_Items" ORDER BY id|, []).rows

  defp drain(collected \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> drain([message | collected])
    after
      0 -> collected |> Enum.reverse() |> Enum.join("\n")
    end
  end

  describe "the relation's SQL spelling" do
    test "a plain lowercase relation stays bare, a mixed-case one is quoted per part" do
      assert Twin.sql_relation(AshStrangler.Test.Legacy.Users) == "legacy.users"
      assert Twin.sql_relation(Items) == ~s|qrel."Mixed_Items"|
      # The logical name is unchanged: it is what a derived key hashes and what a
      # report prints.
      assert Twin.relation(Items) == "qrel.Mixed_Items"
    end
  end

  describe "the view" do
    test "reads rows from the mixed-case relation, through a join to another" do
      TestRepo.query!(~s|INSERT INTO qrel."Mixed_Owners" (id, label) VALUES (7, 'Ada')|, [])

      TestRepo.query!(
        ~s|INSERT INTO qrel."Mixed_Items" (id, name, "Owner_Id") VALUES (1, 'one', 7), (2, 'two', NULL)|,
        []
      )

      rows =
        ReadItem |> Ash.read!() |> Enum.sort_by(& &1.name) |> Enum.map(&{&1.name, &1.owner_label})

      assert rows == [{"one", "Ada"}, {"two", nil}]
    end

    test "the key index is created on, and dropped from, the mixed-case relation" do
      %{key_index: index} = AshStrangler.Sql.View.build(ReadItem)

      assert index.up =~ ~s|ON qrel."Mixed_Items"|
      assert index.down == "DROP INDEX IF EXISTS qrel.strangler_read_items_key_idx;"

      # `up` already ran in setup_all and IF NOT EXISTS makes a second run a no-op;
      # the drop is the statement that names the schema, so run it and put it back.
      TestRepo.query!(index.down, [])
      TestRepo.query!(index.up, [])

      assert %{rows: [[1]]} =
               TestRepo.query!(
                 "SELECT count(*) FROM pg_indexes WHERE indexname = 'strangler_read_items_key_idx'",
                 []
               )
    end
  end

  describe "the logical name" do
    # Lineage names a joined relation by `Twin.relation/1`, and the diagram finds
    # the join by that name: a join that carried the SQL spelling would lose its
    # `AS owner (LEFT JOIN)` label.
    test "a join keeps it, beside its SQL spelling" do
      assert [join] = AshStrangler.Info.joins(ReadItem)

      assert join.relation == "qrel.Mixed_Owners"
      assert join.sql_relation == ~s|qrel."Mixed_Owners"|
    end

    test "the diagram still labels the joined relation with its alias" do
      diagram = AshStrangler.Diagram.Mapping.for_resources([ReadItem], [])

      labels =
        for %AshDiagram.Flowchart.Subgraph{label: label} <- diagram.entries, do: to_string(label)

      assert Enum.any?(labels, &(&1 =~ "AS owner (LEFT JOIN)"))
    end
  end

  describe "every other module that names the relation in SQL" do
    @quoted ~s|qrel."Mixed_Items"|

    defp up(module), do: module |> Migration.statements() |> Enum.map_join("\n", & &1.up)

    # The logical name still appears inside a key's hash input, which is meant to be stable;
    # what must not appear is the unquoted spelling as a relation.
    defp refute_unquoted(sql),
      do: refute(sql =~ ~r/\b(FROM|ON|UPDATE|INTO|JOIN|VIEW|EXISTS) qrel\.Mixed_Items/)

    test "the backfill plan, flag column and passes run against it" do
      plan = AshStrangler.Backfill.plan(ReadItem)

      # The plan carries the logical name; the backfill spells it as SQL does.
      assert plan[:relation] == "qrel.Mixed_Items"

      TestRepo.query!(
        ~s|INSERT INTO qrel."Mixed_Items" (id, name) VALUES (21, 'a'), (22, 'b')|,
        []
      )

      AshStrangler.Backfill.add_flag_column!(TestRepo, plan[:relation])
      assert AshStrangler.Backfill.pending_count(TestRepo, plan[:relation]) >= 2

      assert {:ok, %{complete?: true}} = AshStrangler.Backfill.run(TestRepo, plan)
      assert AshStrangler.Backfill.pending_count(TestRepo, plan[:relation]) == 0
      AshStrangler.Backfill.drop_flag_column!(TestRepo, plan[:relation])
    end

    test "the reconciler counts and checksums a mixed-case legacy relation and view" do
      TestRepo.query!(~s|INSERT INTO qrel."Mixed_Items" (id, name) VALUES (31, 'c')|, [])

      for resource <- [ReadItem, MixedView] do
        assert %{agrees?: true} = AshStrangler.Reconciler.count_drift(resource)
        assert %{agrees?: true} = AshStrangler.Reconciler.checksum_drift(resource)
      end
    end

    test "derived views read from it" do
      sql = up(MixedDerived)
      assert sql =~ "FROM #{@quoted}"
      refute_unquoted(sql)

      for %{up: up} <- Migration.statements(MixedDerived),
          do: TestRepo.query!(up, [], mode: :savepoint)

      TestRepo.query!(~s|INSERT INTO qrel."Mixed_Items" (id, name) VALUES (41, 'd')|, [])
      assert [[41, "d"]] = TestRepo.query!("SELECT item, label FROM qrel.mixed_derived", []).rows
    end

    test "union views, key indexes and write-back name it quoted" do
      sql = up(MixedUnion)
      assert sql =~ "FROM #{@quoted}"
      assert sql =~ "ON #{@quoted}"
      assert sql =~ "UPDATE #{@quoted}"
      assert sql =~ "DELETE FROM #{@quoted}"
      refute_unquoted(sql)

      for %{up: up} <- Migration.statements(MixedUnion),
          do: TestRepo.query!(up, [], mode: :savepoint)

      TestRepo.query!(~s|INSERT INTO qrel."Mixed_Items" (id, name) VALUES (51, 'u')|, [])

      assert [["items", "u"]] =
               TestRepo.query!("SELECT __branch, name FROM qrel.mixed_union", []).rows
    end

    test "the reverse view and its triggers take the mixed-case relation's name" do
      view = AshStrangler.Sql.ReverseView.build(Reversed) |> Enum.map_join("\n", & &1.up)
      assert view =~ "CREATE OR REPLACE VIEW #{@quoted} AS"
      refute_unquoted(view)

      down = AshStrangler.Sql.ReverseView.build(Reversed) |> Enum.map_join("\n", & &1.down)
      assert down =~ "DROP VIEW IF EXISTS #{@quoted};"

      triggers = AshStrangler.Sql.ReverseTriggers.build(Reversed) |> Enum.map_join("\n", & &1.up)
      assert triggers =~ "ON #{@quoted}"
      assert triggers =~ "'qrel.\"Mixed_Items\"'"
      refute_unquoted(triggers)
    end

    test "obligation assertions name it quoted, and run" do
      assertions = AshStrangler.Obligations.assertions(MixedView)
      assert [_ | _] = assertions

      for %{assertion: sql} <- assertions do
        assert sql =~ "FROM #{@quoted}"
        TestRepo.query!(sql, [], mode: :savepoint)
      end
    end
  end

  describe "a mixed-case schema" do
    # Compile-only: the statements are read, not run, so there is no schema to build.
    test "is quoted in the relation, the key index and the drop of the index" do
      id = System.unique_integer([:positive])

      {_result, _io} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          Code.eval_string("""
          defmodule AshStrangler.QuotedRelationTest.CaseTwin#{id} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Twin]

            postgres do
              table "Mixed_Items"
              schema "Qrel_Schema"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :integer, primary_key?: true, allow_nil?: false
              attribute :name, :string
            end

            actions do
              defaults [:read]
            end
          end

          defmodule AshStrangler.QuotedRelationTest.CaseView#{id} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "case_items"
              schema "case_view"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
              attribute :name, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :read_from_legacy

              source AshStrangler.QuotedRelationTest.CaseTwin#{id} do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                map :name, from: :name
              end
            end
          end
          """)
        end)

      twin = Module.concat(AshStrangler.QuotedRelationTest, "CaseTwin#{id}")
      view = Module.concat(AshStrangler.QuotedRelationTest, "CaseView#{id}")

      assert Twin.sql_relation(twin) == ~s|"Qrel_Schema"."Mixed_Items"|

      %{view: view_sql, key_index: index} = AshStrangler.Sql.View.build(view)

      assert view_sql.up =~ ~s|FROM "Qrel_Schema"."Mixed_Items"|
      assert index.up =~ ~s|ON "Qrel_Schema"."Mixed_Items"|
      assert index.down == ~s|DROP INDEX IF EXISTS "Qrel_Schema".strangler_case_items_key_idx;|
    end
  end

  describe "mix ash_strangler.check" do
    setup do
      previous = Application.get_env(:ash_strangler, :ash_domains)

      Application.put_env(:ash_strangler, :ash_domains, [
        AshStrangler.QuotedRelationTest.Domain,
        AshStrangler.QuotedRelationTest.Legacy
      ])

      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Application.put_env(:ash_strangler, :ash_domains, previous)
        Mix.shell(shell)
      end)

      :ok
    end

    test "measures the join fan-out over the mixed-case relation" do
      TestRepo.query!(~s|INSERT INTO qrel."Mixed_Owners" (id, label) VALUES (7, 'Ada')|, [])

      TestRepo.query!(
        ~s|INSERT INTO qrel."Mixed_Items" (id, name, "Owner_Id") VALUES (1, 'one', 7), (2, 'two', NULL)|,
        []
      )

      output =
        try do
          Mix.Task.rerun("ash_strangler.check", [
            "--domain",
            "AshStrangler.QuotedRelationTest.Domain"
          ])

          drain()
        catch
          :exit, _reason -> drain()
        end

      assert output =~ ~r/ok.*join fan-out\n\s+one row in, one row out/
      refute output =~ "does not exist"
    end
  end

  describe "the INSTEAD OF triggers" do
    test "insert, update and delete reach the mixed-case relation" do
      item = Ash.create!(WriteItem, %{name: "first"})
      assert [[_, "first"]] = Enum.filter(items(), &(List.last(&1) == "first"))

      item |> Ash.Changeset.for_update(:update, %{name: "renamed"}) |> Ash.update!()
      assert Enum.any?(items(), &(List.last(&1) == "renamed"))
      refute Enum.any?(items(), &(List.last(&1) == "first"))

      Ash.destroy!(item)
      refute Enum.any?(items(), &(List.last(&1) == "renamed"))
    end
  end

  describe "the observation baseline" do
    # `Baseline.run/2` keyset-scans `SELECT * FROM <schema>.<table>`, with each part
    # spelled through the printer's identifier rule. This is the test of that
    # spelling: the scan must find `qrel."Mixed_Items"`, which an unquoted
    # `qrel.Mixed_Items` does not name.
    test "reads the mixed-case relation" do
      TestRepo.query!(~s|INSERT INTO qrel."Mixed_Items" (id, name) VALUES (61, 'baselined')|, [])

      assert {:ok, %{count: 1, group: group}} =
               Baseline.run(LedgerItem, repo: TestRepo, isolation: :caller)

      assert [row] = baseline_rows(group)
      assert row["operation"] == "insert"
      assert decode(row["after"])["name"] == "baselined"

      # The record id is the key the mapping derives: the row the baseline read
      # is the row the compatibility view serves.
      assert row["record_id"] == LedgerItem |> Ash.read!() |> Enum.map(& &1.id) |> hd()
    end
  end

  defp baseline_rows(group) do
    %Postgrex.Result{columns: columns, rows: rows} =
      TestRepo.query!(
        """
        SELECT record_id, operation, after
          FROM "strangler_observations"
         WHERE resource = $1 AND baseline_group = $2 AND category = 'baseline'
        """,
        [to_string(LedgerItem), Ecto.UUID.dump!(group)]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(other), do: other
end
