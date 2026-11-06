# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionEstateTest do
  @moduledoc """
  Check E8 (the phase lattice and the carry rule) over unions, with negative
  fixtures: an estate is evaluated with a branch at each phase and each
  disposition of the column the branch does not map.
  """

  # Serial: compiling probes swaps the global :standard_error device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Estate

  @catalog "test/fixtures/snapshot/clinic_union/catalog.json"

  defp compile(source) do
    {modules, _io} =
      with_io(:stderr, fn -> source |> Code.compile_string() |> Enum.map(&elem(&1, 0)) end)

    List.last(modules)
  end

  defp union(north_phase, south_phase, view \\ "visits") do
    name = "AshStrangler.UnionEstateTest.U#{System.unique_integer([:positive])}"
    compile(AshStrangler.Test.Clinic.source(name, north_phase, south_phase, view))
  end

  defp estate(unions, declarations) do
    name = "AshStrangler.UnionEstateTest.E#{System.unique_integer([:positive])}"

    compile("""
    defmodule #{name} do
      use AshStrangler.Estate

      estate do
        snapshot #{inspect(@catalog)}
        resources #{inspect(unions)}
        #{Enum.join(declarations, "\n")}
      end
    end
    """)
    |> Estate.evaluate()
  end

  defp phase_problems(report), do: Enum.filter(report.problems, &(&1.check == :phase))

  test "a union's legacy branches claim what they read, and a dual-write branch writes it" do
    report =
      estate([union(:read_from_legacy, :dual_write)], [
        ~S|deferred "clinic_union.north_visits.ward", wave: :wards, target: "Ward", because: "later"|
      ])

    assert report.problems == []
    south = report.relations["clinic_union.south_visits"].columns["remarks"]
    assert [%{kind: :mapped}] = south.claims
    assert [_] = south.writers
    assert report.relations["clinic_union.north_visits"].columns["patient_name"].writers == []
  end

  describe "the carry rule" do
    test "a branch below :read_from_new may leave a column deferred" do
      report =
        estate([union(:dual_write, :dual_write)], [
          ~S|deferred "clinic_union.north_visits.ward", wave: :wards, target: "Ward", because: "later"|
        ])

      assert phase_problems(report) == []
    end

    test "a branch at :read_from_new with a deferred column is refused, naming the column" do
      report =
        estate([union(:read_from_new, :dual_write)], [
          ~S|deferred "clinic_union.north_visits.ward", wave: :wards, target: "Ward", because: "later"|
        ])

      assert [%{subject: "clinic_union.north_visits.ward", message: message}] =
               phase_problems(report)

      assert message =~ "branch :north is read_from_new"
      assert message =~ "deferred"
    end

    test "a legacy_only column also blocks the move, and so does a whole relation declared so" do
      report =
        estate([union(:decommissioned, :dual_write)], [
          ~S|legacy_only "clinic_union.north_visits.ward", because: "stays"|
        ])

      assert [%{subject: "clinic_union.north_visits.ward"}] = phase_problems(report)

      report =
        estate([union(:read_from_new, :dual_write)], [
          ~S|legacy_only "clinic_union.north_visits", because: "stays"|
        ])

      assert [%{subject: "clinic_union.north_visits"}] = phase_problems(report)
    end

    test "carried or dead columns let the branch move" do
      for declaration <- [
            ~S|carried "clinic_union.north_visits.ward", because: "kept opaque"|,
            ~S|dead "clinic_union.north_visits.ward", because: "nothing reads it"|
          ] do
        report = estate([union(:read_from_new, :dual_write)], [declaration])
        assert report.problems == []
      end
    end
  end

  describe "the lattice rule" do
    test "no one may read a relation a branch has decommissioned" do
      decommissioned = union(:decommissioned, :dual_write, "visits")
      reader = union(:dual_write, :dual_write, "visits_copy")
      carried = ~S|carried "clinic_union.north_visits.ward", because: "kept"|

      report = estate([decommissioned, reader], [carried])

      assert [%{subject: "clinic_union.north_visits", message: message}] = phase_problems(report)
      assert message =~ inspect(reader)
      assert message =~ "decommissioned"

      assert phase_problems(estate([decommissioned], [carried])) == []
    end
  end
end
