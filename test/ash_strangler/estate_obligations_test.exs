# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.EstateObligationsTest.Plugin do
  @moduledoc false
  @behaviour AshStrangler.Estate.Plugin

  alias AshStrangler.Estate.Obligation

  @impl true
  def obligations(_estate) do
    [
      %Obligation{
        id: "O-B-CLEAN",
        summary: "no visit is older than the epoch",
        denominator: "visits",
        sql: "SELECT 0::bigint, 4::bigint"
      },
      %Obligation{
        id: "O-A-DIRTY",
        summary: "no visit is unnamed",
        denominator: "visits",
        sql: "SELECT 2::bigint, 4::bigint"
      },
      %Obligation{
        id: "O-C-SOFT",
        summary: "visits should have a date",
        denominator: "visits",
        sql: "SELECT 1::bigint, 4::bigint",
        severity: :warning
      },
      %Obligation{
        id: "O-D-ROWS",
        summary: "no row names a missing clinic",
        denominator: "the rows returned",
        sql: "SELECT 'a', 1 UNION ALL SELECT 'b', 2",
        shape: :rows
      },
      %Obligation{
        id: "O-E-BROKEN",
        summary: "cannot run",
        denominator: "none",
        sql: "SELECT * FROM clinic_union.no_such_table"
      }
    ]
  end
end

defmodule AshStrangler.EstateObligationsTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.EstateObligationsTest.Defaulted
  end
end

defmodule AshStrangler.EstateObligationsTest.Defaulted do
  @moduledoc "A mapping whose reverse holds only while its default is not a stored value."
  use Ash.Resource,
    domain: AshStrangler.EstateObligationsTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "defaulted_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      coalesce :email, from: :email, default: "none@example.com"
    end
  end
end

defmodule AshStrangler.EstateObligationsTest do
  @moduledoc """
  The obligation registry and report: what is collected from the estate's
  resources, plug-ins and derived views, how each is measured against
  PostgreSQL, and the shape and stability of the JSON.
  """

  # Serial: compiling probes swaps the global :standard_error device.
  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Estate.Obligations
  alias AshStrangler.Snapshot.Catalog

  @catalog "test/fixtures/snapshot/clinic_union/catalog.json"

  defp estate(resources, plugins \\ [], declarations \\ []) do
    name = "AshStrangler.EstateObligationsTest.E#{System.unique_integer([:positive])}"

    {modules, _io} =
      with_io(:stderr, fn ->
        """
        defmodule #{name} do
          use AshStrangler.Estate

          estate do
            snapshot #{inspect(@catalog)}
            resources #{inspect(resources)}
            plugins #{inspect(plugins)}
            #{Enum.join(declarations, "\n")}
          end
        end
        """
        |> Code.compile_string()
        |> Enum.map(&elem(&1, 0))
      end)

    List.last(modules)
  end

  defp clean_estate(plugins) do
    estate([], plugins, [
      ~S|legacy_only "clinic_union.north_visits", because: "not strangled here"|,
      ~S|legacy_only "clinic_union.south_visits", because: "not strangled here"|
    ])
  end

  defp by_id(report), do: Map.new(report["obligations"], &{&1["id"], &1})

  defp visit!(id, metadata),
    do:
      TestRepo.query!(
        "INSERT INTO clinic_derived.visits (id, metadata) VALUES ($1, $2::jsonb)",
        [id, metadata],
        mode: :savepoint
      )

  describe "the report over plug-in obligations" do
    setup do
      %{report: Obligations.report(clean_estate([__MODULE__.Plugin]), repo: TestRepo)}
    end

    test "each obligation has a status from its severity and its measurement", %{report: report} do
      rows = by_id(report)

      assert %{"status" => "pass", "violations" => 0, "total" => 4} = rows["O-B-CLEAN"]
      assert %{"status" => "fail", "violations" => 2, "total" => 4} = rows["O-A-DIRTY"]
      assert %{"status" => "warn", "violations" => 1, "severity" => "warning"} = rows["O-C-SOFT"]

      assert %{
               "status" => "fail",
               "violations" => 2,
               "total" => nil,
               "detail" => [["a", 1], ["b", 2]]
             } =
               rows["O-D-ROWS"]

      assert %{"status" => "error", "violations" => nil, "detail" => detail} = rows["O-E-BROKEN"]
      assert detail =~ "no_such_table"
    end

    test "the summary counts every status", %{report: report} do
      assert report["summary"] == %{
               "total" => 5,
               "pass" => 1,
               "warn" => 1,
               "fail" => 2,
               "error" => 1,
               "skipped" => 0
             }
    end

    test "obligations are sorted by id", %{report: report} do
      ids = Enum.map(report["obligations"], & &1["id"])
      assert ids == Enum.sort(ids)
    end

    test "the report is keyed by the catalog and carries the plug-in as source", %{report: report} do
      assert report["format"] == "ash_strangler.obligations/1"
      assert report["catalog"]["path"] == @catalog
      assert report["catalog"]["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert by_id(report)["O-A-DIRTY"]["source"] == inspect(__MODULE__.Plugin)
    end

    test "the same estate over the same rows gives the same bytes", %{report: report} do
      again = Obligations.report(clean_estate([__MODULE__.Plugin]), repo: TestRepo)
      assert Map.delete(again, "estate") == Map.delete(report, "estate")
      assert {:ok, decoded} = Jason.decode(Catalog.encode(report))
      assert decoded["summary"] == report["summary"]
    end

    test "a failed or unmeasurable obligation fails the gate", %{report: report} do
      assert Obligations.failed?(report)
    end
  end

  test "warnings and passes alone do not fail the gate" do
    plugin = Module.concat(__MODULE__, "WarnOnly#{System.unique_integer([:positive])}")

    {_, _} =
      with_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(plugin)} do
          @behaviour AshStrangler.Estate.Plugin
          alias AshStrangler.Estate.Obligation

          @impl true
          def obligations(_estate) do
            [
              %Obligation{id: "O-1", summary: "s", denominator: "d", sql: "SELECT 1::bigint, 9::bigint", severity: :warning},
              %Obligation{id: "O-2", summary: "s", denominator: "d", sql: "SELECT 0::bigint, 9::bigint"}
            ]
          end
        end
        """)
      end)

    report = Obligations.report(clean_estate([plugin]), repo: TestRepo)
    assert report["problems"] == []
    assert report["summary"]["warn"] == 1
    refute Obligations.failed?(report)
  end

  test "measure?: false skips every query and says nothing was measured" do
    report =
      Obligations.report(clean_estate([__MODULE__.Plugin]), repo: TestRepo, measure?: false)

    assert report["measured"] == false
    assert report["summary"]["skipped"] == 5

    assert Enum.all?(
             report["obligations"],
             &(&1["status"] == "skipped" and &1["violations"] == nil)
           )

    refute Obligations.failed?(report)
  end

  test "an estate problem fails the gate even when every obligation passes" do
    report = Obligations.report(estate([]), repo: TestRepo)
    assert report["problems"] != []
    assert Obligations.failed?(report)
  end

  describe "obligations the library collects" do
    test "an element source of a derived view yields a census of refused elements" do
      visit!(1, %{propertyIds: [3, 12.5, "12", 7]})
      visit!(2, %{propertyIds: [1.0e10]})

      report =
        Obligations.report(estate([AshStrangler.Test.ClinicDerived.Properties]), repo: TestRepo)

      assert %{
               "status" => "warn",
               "violations" => 3,
               "total" => 5,
               "severity" => "warning",
               "source" => "AshStrangler.Test.ClinicDerived.Properties"
             } = by_id(report)["element:clinic_derived.properties.listed"]
    end

    test "a clean element census passes" do
      visit!(1, %{propertyIds: [3, 7]})

      report =
        Obligations.report(estate([AshStrangler.Test.ClinicDerived.Properties]), repo: TestRepo)

      assert %{"status" => "pass", "violations" => 0, "total" => 2} =
               by_id(report)["element:clinic_derived.properties.listed"]
    end

    test "the assertions a resource's mappings could not decide become obligations" do
      resource = AshStrangler.EstateObligationsTest.Defaulted
      ids = for o <- Obligations.registry(estate([resource])), do: o.id

      assert Enum.any?(ids, &String.contains?(&1, "#{inspect(resource)}.email"))

      insert_legacy_user!(email: "none@example.com")
      report = Obligations.report(estate([resource]), repo: TestRepo)

      statuses =
        for {id, row} <- by_id(report),
            String.contains?(id, "#{inspect(resource)}.email"),
            do: row["status"]

      assert statuses != [] and Enum.all?(statuses, &(&1 in ["warn", "fail"]))
    end

    test "a count assertion reports the count, not the number of rows it returned" do
      resource = AshStrangler.EstateObligationsTest.Defaulted
      for _ <- 1..37, do: insert_legacy_user!(email: "none@example.com")

      report = Obligations.report(estate([resource]), repo: TestRepo)

      assert [%{"violations" => 37, "status" => "warn"}] =
               for({id, row} <- by_id(report), String.contains?(id, ".email"), do: row)
    end

    test "an undecoded value of 0 is a violation, not a clean zero" do
      n = System.unique_integer([:positive])

      TestRepo.query!(
        "CREATE TABLE clinic_union.dec#{n} (id integer PRIMARY KEY, status integer)",
        [],
        mode: :savepoint
      )

      {modules, _io} =
        with_io(:stderr, fn ->
          """
          defmodule AshStrangler.EstateObligationsTest.DecTwin#{n} do
            use Ash.Resource,
              domain: AshStrangler.EstateObligationsTest.Domain,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Twin]

            postgres do
              table "dec#{n}"
              schema "clinic_union"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
              attribute :status, :integer, public?: true
            end

            actions do
              defaults [:read]
            end
          end

          defmodule AshStrangler.EstateObligationsTest.Dec#{n} do
            use Ash.Resource,
              domain: AshStrangler.EstateObligationsTest.Domain,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "dec#{n}_v"
              schema "strangler"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
              attribute :s, :atom, public?: true, constraints: [one_of: [:a, :b]]
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :read_from_legacy

              source AshStrangler.EstateObligationsTest.DecTwin#{n} do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                decode :s, from: :status, values: %{"1": :a, "2": :b}
              end
            end
          end
          """
          |> Code.compile_string()
          |> Enum.map(&elem(&1, 0))
        end)

      resource = List.last(modules)
      TestRepo.query!("INSERT INTO clinic_union.dec#{n} VALUES (1, 0)", [], mode: :savepoint)

      report = Obligations.report(estate([resource]), repo: TestRepo)

      assert [%{"violations" => 1, "status" => status}] =
               for({id, row} <- by_id(report), String.starts_with?(id, "GetTotal"), do: row)

      assert status in ["warn", "fail"]
    end
  end

  describe "mix ash_strangler.check --estate" do
    setup do
      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)

      previous = Application.get_env(:ash_strangler, :repo)
      Application.put_env(:ash_strangler, :repo, TestRepo)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_strangler, :repo, previous),
          else: Application.delete_env(:ash_strangler, :repo)
      end)

      path =
        Path.join(System.tmp_dir!(), "obligations-#{System.unique_integer([:positive])}.json")

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    defp check(estate, extra) do
      Mix.Tasks.AshStrangler.Check.run(["--estate", inspect(estate) | extra])
      :ok
    catch
      :exit, reason -> {:exit, reason}
    end

    test "writes the report as canonical JSON and exits 1 on a failed obligation", %{path: path} do
      estate = clean_estate([__MODULE__.Plugin])

      assert {:exit, {:shutdown, 1}} = check(estate, ["--report", path])
      assert {:ok, report} = path |> File.read!() |> Jason.decode()
      assert report["format"] == "ash_strangler.obligations/1"
      assert report["summary"]["fail"] == 2
      assert File.read!(path) == Catalog.encode(report)
    end

    test "--no-data skips the queries and passes a clean estate", %{path: path} do
      estate = clean_estate([__MODULE__.Plugin])

      assert :ok = check(estate, ["--no-data", "--report", path])

      assert %{"measured" => false, "summary" => %{"skipped" => 5}} =
               path |> File.read!() |> Jason.decode!()
    end
  end
end
