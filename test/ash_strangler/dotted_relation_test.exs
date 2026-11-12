# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.DottedRelationTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.DottedRelationTest.Items
    resource AshStrangler.DottedRelationTest.Mapped
  end
end

defmodule AshStrangler.DottedRelationTest.Items do
  @moduledoc "A legacy relation whose schema and table names both contain a dot."
  use Ash.Resource,
    domain: AshStrangler.DottedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "odd.items"
    schema "odd.schema"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.DottedRelationTest.Mapped do
  @moduledoc "A ledger-backed mapping over the dotted relation."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.DottedRelationTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "dotted_mapped"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.DottedRelationTest.Items do
      notify? true
      ledger?(true)
      notify_channel "ash_strangler_dotted_test"
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :label, from: :label
    end
  end
end

defmodule AshStrangler.DottedRelationTest do
  @moduledoc """
  Every place that used to find a relation's schema by splitting its logical name on a dot,
  against a relation whose schema (`odd.schema`) and table (`odd.items`) both contain one.
  The logical name, `odd.schema.odd.items`, cannot be split back into the two; the parts come
  from the twin.
  """

  use AshStrangler.DataCase, async: false

  import Igniter.Test

  alias AshStrangler.DottedRelationTest.{Items, Mapped}
  alias AshStrangler.Observation.{Baseline, Processor}
  alias AshStrangler.Sql.Ledger
  alias AshStrangler.Test.RecordingObserver
  alias AshStrangler.Twin

  @domain "AshStrangler.DottedRelationTest.Domain"

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params).rows

  setup do
    q!(~s|CREATE SCHEMA IF NOT EXISTS "odd.schema"|)
    q!(~s|CREATE TABLE "odd.schema"."odd.items" (id integer PRIMARY KEY, label text)|)

    for %{up: up} <- Ledger.build(Mapped), do: q!(up)

    q!(~s|INSERT INTO "odd.schema"."odd.items" VALUES (1, 'one')|)

    Application.put_env(:ash_strangler_test, :recording_mode, :ok)
    on_exit(fn -> Application.delete_env(:ash_strangler_test, :recording_mode) end)
    :ok
  end

  test "Twin.schema_and_table/1 reads the parts from the twin" do
    assert Twin.schema_and_table(Items) == {"odd.schema", "odd.items"}
    assert Twin.schema_and_table(AshStrangler.Test.Legacy.Users) == {"legacy", "users"}
    assert Twin.relation(Items) == "odd.schema.odd.items"
  end

  test "the ledger records the dotted schema and table, and the drain finds them" do
    assert [["odd.schema", "odd.items"]] =
             q!(
               "SELECT source_schema, source_table FROM legacy_change_events WHERE source_table = $1",
               ["odd.items"]
             )

    assert {:ok, 1} = Processor.drain(TestRepo, Mapped, [RecordingObserver], batch: 10)
  end

  test "a baseline scans the dotted relation" do
    assert {:ok, %{count: 1}} = Baseline.run(Mapped, repo: TestRepo, isolation: :caller)
  end

  test "the generated ingestion claims events by the dotted schema and table" do
    assert {:ok, ctx} = AshStrangler.Ingester.context(Mapped, AshStrangler.DottedRelationTest.Gen)
    assert ctx.schema == "odd.schema"
    assert ctx.table == "odd.items"
    assert ctx.relation == "odd.schema.odd.items"

    source = AshStrangler.Ingester.render_worker(ctx)
    assert source =~ ~s|["odd.schema", "odd.items", @batch_size]|
  end

  describe "mix ash_strangler.check" do
    defp check do
      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.DottedRelationTest.Domain])

      try do
        Mix.Task.rerun("ash_strangler.check", ["--domain", @domain])
      catch
        :exit, _ -> :ok
      end

      collect()
    end

    defp collect(acc \\ []) do
      receive do
        {:mix_shell, _kind, [message]} -> collect([message | acc])
      after
        0 -> acc |> Enum.reverse() |> Enum.join("\n")
      end
    end

    setup do
      previous = Application.get_env(:ash_strangler, :ash_domains)
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        if previous, do: Application.put_env(:ash_strangler, :ash_domains, previous)
      end)
    end

    test "measures the dotted twin and its ledger backlog" do
      output = check()

      assert output =~ ~r/odd\.schema\.odd\.items — 1 unprocessed event\(s\)/
      refute output =~ "does not exist"
    end
  end

  describe "mix ash_strangler.gen.twin" do
    @relation ~s|"odd.schema"."odd.items"|

    defp catalog_file do
      path =
        Path.join(System.tmp_dir!(), "dotted_catalog_#{System.unique_integer([:positive])}.json")

      catalog = %{
        "format" => AshStrangler.Snapshot.Catalog.format(),
        "schemas" => ["odd.schema"],
        "extensions" => %{},
        "enums" => %{},
        "domains" => %{},
        "relations" => %{
          "odd.schema.odd.items" => %{
            "kind" => "table",
            "definition" => nil,
            "columns" => [
              %{
                "name" => "id",
                "type" => "integer",
                "udt" => "pg_catalog.int4",
                "not_null" => true,
                "array" => false,
                "default" => nil,
                "generated" => nil,
                "identity" => nil
              },
              %{
                "name" => "label",
                "type" => "text",
                "udt" => "pg_catalog.text",
                "not_null" => false,
                "array" => false,
                "default" => nil,
                "generated" => nil,
                "identity" => nil
              }
            ],
            "primary_key" => %{"name" => "items_pkey", "columns" => ["id"]},
            "unique" => [],
            "foreign_keys" => [],
            "checks" => [],
            "triggers" => []
          }
        }
      }

      File.write!(path, Jason.encode!(catalog))
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "names the twin's schema and table from a quoted --relation" do
      path = catalog_file()

      igniter =
        test_project()
        |> Igniter.compose_task("ash_strangler.gen.twin", [
          "--from-snapshot",
          path,
          "--relation",
          @relation,
          "--module",
          "Odd.Items",
          "--domain",
          "Odd.Legacy",
          "--repo",
          "AshStrangler.TestRepo"
        ])
        |> assert_creates("lib/odd/items.ex")

      twin =
        igniter.rewrite |> Rewrite.source!("lib/odd/items.ex") |> Rewrite.Source.get(:content)

      assert twin =~ ~r/table\(?"odd\.items"/
      assert twin =~ ~r/schema\(?"odd\.schema"/
    end

    test "refuses a relation it cannot read, naming it" do
      igniter =
        Igniter.compose_task(test_project(), "ash_strangler.gen.twin", [
          "--relation",
          "a.b.c",
          "--domain",
          "Odd.Legacy",
          "--repo",
          "AshStrangler.TestRepo"
        ])

      assert_has_issue(igniter, ~s|`--relation` expected table or schema.table, got "a.b.c"|)
    end

    test "derives a module name from a dotted table without a dot in it" do
      path = catalog_file()

      igniter =
        test_project()
        |> Igniter.compose_task("ash_strangler.gen.twin", [
          "--from-snapshot",
          path,
          "--relation",
          @relation,
          "--domain",
          "Odd.Legacy",
          "--repo",
          "AshStrangler.TestRepo"
        ])

      assert igniter.issues == []
    end
  end
end
