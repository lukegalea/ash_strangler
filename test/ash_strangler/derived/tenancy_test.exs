# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TenancyTest do
  @moduledoc """
  Estate check E5 (tenant closure) over unions and derived views, with negative
  fixtures: each way a branch or source can fail to derive its tenant through a
  tenant key kind.
  """

  # Serial: compiling probes swaps the global :standard_error device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Estate

  @fixture "test/fixtures/snapshot/clinic_union/catalog.json"
  @catalog Path.join(System.tmp_dir!(), "ash_strangler_tenancy_catalog.json")
  @keys "AshStrangler.Test.ClinicDerived.Keys"
  @north "AshStrangler.Test.Clinic.Legacy.NorthVisits"
  @south "AshStrangler.Test.Clinic.Legacy.SouthVisits"

  # The union fixture's catalog, with the columns the tenant keys read: `clinic_id` closes onto the
  # clinics relation by a validated foreign key; `site_id` has none onto it, only onto a site, whose
  # own `clinic_id` closes (the chain a `through:` declares). `clinic_union.loose` is a relation no
  # foreign key reaches.
  setup_all do
    catalog = @fixture |> File.read!() |> Jason.decode!()

    fk = %{
      "columns" => ["clinic_id"],
      "name" => "visits_clinic_id_fkey",
      "on_delete" => "no_action",
      "on_update" => "no_action",
      "references" => %{"columns" => ["id"], "relation" => "clinic_derived.clinics"},
      "validated" => true
    }

    column = fn name ->
      %{
        "array" => false,
        "default" => nil,
        "generated" => nil,
        "identity" => nil,
        "name" => name,
        "not_null" => false,
        "type" => "integer",
        "udt" => "pg_catalog.int4"
      }
    end

    relations =
      for {name, extra} <- [
            {"clinic_union.north_visits", [column.("clinic_id"), column.("site_id")]},
            {"clinic_union.south_visits", [column.("clinic_id")]}
          ],
          into: catalog["relations"] do
        relation = catalog["relations"][name]

        {name, %{relation | "columns" => relation["columns"] ++ extra, "foreign_keys" => [fk]}}
      end

    derived =
      relations["clinic_union.south_visits"]
      |> Map.put("columns", [column.("id"), column.("clinic_id")])

    site_fk = %{
      "columns" => ["site_id"],
      "name" => "visits_site_id_fkey",
      "on_delete" => "no_action",
      "on_update" => "no_action",
      "references" => %{"columns" => ["id"], "relation" => "clinic_union.sites"},
      "validated" => true
    }

    relations =
      relations
      |> update_in(["clinic_union.north_visits", "foreign_keys"], &(&1 ++ [site_fk]))
      |> Map.put("clinic_derived.visits", derived)
      |> Map.put("clinic_union.sites", %{
        derived
        | "columns" => [column.("id"), column.("clinic_id")],
          "foreign_keys" => [fk]
      })
      |> Map.put("clinic_union.loose", %{
        derived
        | "columns" => [column.("id"), column.("clinic_id")],
          "foreign_keys" => [fk]
      })

    File.write!(@catalog, Jason.encode!(%{catalog | "relations" => relations}))
    :ok
  end

  defp compile(source) do
    {modules, _io} =
      with_io(:stderr, fn -> source |> Code.compile_string() |> Enum.map(&elem(&1, 0)) end)

    List.last(modules)
  end

  defp unique(prefix),
    do: "AshStrangler.TenancyTest.#{prefix}#{System.unique_integer([:positive])}"

  defp union(north, south, opts \\ []) do
    name = unique("U")
    column = opts[:column] || "column :clinic, :uuid, null?: false"

    compile("""
    defmodule #{name} do
      use AshStrangler.Union

      union do
        schema "clinic_union"
        view "visits"
        #{if opts[:tenant] == false, do: "", else: "tenant :clinic"}

        #{column}
        column :patient, :string

        legacy :north do
          twin #{@north}
          phase :read_from_legacy
          refused_because "north writes"
          key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
          map :patient, from: :patient_name
          #{north}
        end

        legacy :south do
          twin #{@south}
          phase :read_from_legacy
          refused_because "south writes"
          key :id, strategy: {:uuid_v5, namespace: "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d"}
          map :patient, from: :name
          #{south}
        end

        owned :native
      end
    end
    """)
  end

  defp problems(module, catalog \\ @catalog) do
    name = unique("E")

    compile("""
    defmodule #{name} do
      use AshStrangler.Estate

      estate do
        snapshot #{inspect(catalog)}
        resources [#{inspect(module)}]
        deferred "clinic_union.north_visits", wave: :later, target: "X", because: "later"
        deferred "clinic_union.south_visits", wave: :later, target: "X", because: "later"
      end
    end
    """)
    |> Estate.evaluate()
    |> Map.fetch!(:problems)
    |> Enum.filter(&(&1.check == :tenant))
  end

  defp tenant_of(kind, from \\ :clinic_id),
    do: "tenant_of :clinic, kind: {#{@keys}, #{inspect(kind)}}, from: #{inspect(from)}"

  test "a tenant key kind on every legacy branch is closed" do
    assert problems(union(tenant_of(:clinic), tenant_of(:clinic))) == []
  end

  test "a tenant key packing a column that is not the tenant is refused" do
    assert [%{message: message}] =
             problems(union(tenant_of(:clinic, :id), tenant_of(:clinic)))

    assert message =~ "branch :north"
    assert message =~ "clinic_union.north_visits.id, which is not clinic_derived.clinics.id"
    assert message =~ "no validated foreign key"
  end

  test "a column with no foreign key onto the tenant is refused" do
    assert [%{message: message}] =
             problems(union(tenant_of(:clinic, :site_id), tenant_of(:clinic)))

    assert message =~ "clinic_union.north_visits.site_id"
  end

  describe "a tenant reached through a declared chain (`through:`)" do
    defp through(chains),
      do:
        "tenant_of :clinic, kind: {#{@keys}, :clinic}, from: :site_id, through: #{inspect(chains)}"

    @site [{"clinic_union.sites", :id, :clinic_id}]

    test "is closed when every hop follows a validated foreign key and the chain ends on the home" do
      assert problems(union(through([@site]), tenant_of(:clinic))) == []
    end

    test "takes alternative chains, each held to the rule" do
      fallback = [{"clinic_union.sites", :id, :id}]

      assert problems(union(through([@site, @site]), tenant_of(:clinic))) == []

      assert [%{message: message}] =
               problems(union(through([@site, fallback]), tenant_of(:clinic)))

      assert message =~ "`through:` chain 2"
    end

    test "an undeclared chain is still refused: the same column without `through:`" do
      assert [%{message: message}] =
               problems(union(tenant_of(:clinic, :site_id), tenant_of(:clinic)))

      assert message =~
               "clinic_union.north_visits.site_id, which is not clinic_derived.clinics.id"
    end

    test "a hop no validated foreign key reaches is refused" do
      assert [%{message: message}] =
               problems(
                 union(through([[{"clinic_union.loose", :id, :clinic_id}]]), tenant_of(:clinic))
               )

      assert message =~ "branch :north"
      assert message =~ "chain 1"

      assert message =~
               "clinic_union.north_visits.site_id reaches clinic_union.loose.id by no validated foreign key"
    end

    test "a chain that does not end on the tenant is refused" do
      assert [%{message: message}] =
               problems(union(through([[{"clinic_union.sites", :id, :id}]]), tenant_of(:clinic)))

      assert message =~ "ends on clinic_union.sites.id, which is not clinic_derived.clinics.id"
    end

    test "a hop over a relation or a column the catalog lacks is refused" do
      assert [%{message: missing}] =
               problems(
                 union(through([[{"clinic_union.nope", :id, :clinic_id}]]), tenant_of(:clinic))
               )

      assert missing =~ "the estate catalog has no relation `clinic_union.nope`"

      assert [%{message: column}] =
               problems(
                 union(through([[{"clinic_union.sites", :id, :nope}]]), tenant_of(:clinic))
               )

      assert column =~ "`clinic_union.sites` has no column `nope`"
    end

    test "a kind that is not a tenant kind is refused before the chain is read" do
      assert [%{message: message}] =
               problems(
                 union(
                   "tenant_of :clinic, kind: {#{@keys}, :site}, from: :site_id, through: #{inspect([@site])}",
                   tenant_of(:clinic)
                 )
               )

      assert message =~ "is not declared `tenant?: true`"
    end

    test "the view packs the end of the chain, and carries it as the tenant part" do
      module = union(through([@site, [{"clinic_union.sites", :id, :id}]]), tenant_of(:clinic))

      view =
        module
        |> AshStrangler.Migration.statements()
        |> Enum.map_join("\n", & &1.up)

      chain =
        ~s|(SELECT (SELECT strangler_t0_0.clinic_id FROM "clinic_union"."sites" strangler_t0_0 | <>
          ~s|WHERE strangler_t0_0.id = strangler_c0.v ORDER BY strangler_t0_0.clinic_id LIMIT 1) | <>
          ~s|FROM (SELECT site_id AS v) strangler_c0)|

      assert view =~ "coalesce(#{chain}, "
      assert view =~ ~r/coalesce\(\(SELECT \(SELECT strangler_t0_0[^\n]*\) AS "__tenant_p0"/
    end
  end

  test "a relation the catalog lacks cannot show closure" do
    assert [%{message: message}] =
             problems(
               union(tenant_of(:clinic), tenant_of(:clinic)),
               "test/fixtures/snapshot/lending/catalog.json"
             )
             |> Enum.take(1)

    assert message =~ "the estate catalog has no relation"
  end

  test "a union without a tenant column is not tenant-scoped" do
    assert problems(
             union("unmapped [:clinic], because: \"x\"", "unmapped [:clinic], because: \"x\"",
               tenant: false
             )
           ) == []
  end

  test "an unmapped tenant on one branch is refused, naming the branch" do
    assert [%{message: message}] =
             problems(union(tenant_of(:clinic), "unmapped [:clinic], because: \"none\""))

    assert message =~ "branch :south"
    assert message =~ "`unmapped`"
  end

  test "a constant tenant is refused" do
    assert [%{message: message}] = problems(union(tenant_of(:clinic), ~S|constant :clinic, "0"|))
    assert message =~ "`constant`"
  end

  test "a plain map of the tenant is refused" do
    assert [%{message: message}] = problems(union("map :clinic, from: :id", tenant_of(:clinic)))
    assert message =~ "branch :north"
    assert message =~ "a `map`"
  end

  test "a kind that is not a tenant kind is refused" do
    assert [%{message: message}] = problems(union(tenant_of(:site), tenant_of(:clinic)))
    assert message =~ "is not declared `tenant?: true`"
  end

  test "a kind the registry does not declare is refused" do
    assert [%{message: message}] = problems(union(tenant_of(:nope), tenant_of(:clinic)))
    assert message =~ "declares no kind :nope"
  end

  test "both branches failing gives two problems" do
    assert [_, _] =
             problems(
               union("unmapped [:clinic], because: \"a\"", "unmapped [:clinic], because: \"b\"")
             )
  end

  test "a nullable tenant column is refused" do
    assert [%{message: message}] =
             problems(
               union(tenant_of(:clinic), tenant_of(:clinic), column: "column :clinic, :uuid")
             )

    assert message =~ "null?: false"
  end

  test "a derived view's sources are held to the same rule" do
    assert problems(AshStrangler.Test.ClinicDerived.Properties) == []

    module =
      compile("""
      defmodule #{unique("D")} do
        use AshStrangler.Derived

        derived do
          schema "clinic_derived"
          view "bad"
          twin AshStrangler.Test.ClinicDerived.Legacy.Visits
          registry #{@keys}
          kind :property
          from [:id]
          tenant :clinic

          column :clinic, :uuid, null?: false

          slot :lead do
            map :clinic, from: :id
          end
        end
      end
      """)

    assert [%{message: message}] = problems(module)
    assert message =~ "source :lead"
    assert message =~ "a `map`"
  end
end
