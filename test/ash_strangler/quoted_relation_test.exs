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
  alias AshStrangler.QuotedRelationTest.{Items, ReadItem, WriteItem}
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

      for resource <- [ReadItem, WriteItem], statement <- Migration.statements(resource) do
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
end
