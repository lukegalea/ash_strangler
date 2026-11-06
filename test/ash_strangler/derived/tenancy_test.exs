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

  @catalog "test/fixtures/snapshot/clinic_union/catalog.json"
  @keys "AshStrangler.Test.ClinicDerived.Keys"
  @north "AshStrangler.Test.Clinic.Legacy.NorthVisits"
  @south "AshStrangler.Test.Clinic.Legacy.SouthVisits"

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

  defp problems(module) do
    name = unique("E")

    compile("""
    defmodule #{name} do
      use AshStrangler.Estate

      estate do
        snapshot #{inspect(@catalog)}
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

  defp tenant_of(kind, from \\ :id),
    do: "tenant_of :clinic, kind: {#{@keys}, #{inspect(kind)}}, from: #{inspect(from)}"

  test "a tenant key kind on every legacy branch is closed" do
    assert problems(union(tenant_of(:clinic), tenant_of(:clinic))) == []
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
