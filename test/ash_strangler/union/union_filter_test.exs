# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionFilterTest do
  @moduledoc """
  A legacy branch's `filter`: the branch shows only the twin's rows where the expression holds.
  The union is built inside the test's transaction, over the clinic fixture's legacy tables.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Union.Info

  defmodule DatedVisits do
    @moduledoc false
    use AshStrangler.Union

    union do
      schema "clinic_union"
      view "dated_visits"

      column :patient, :string, null?: false

      legacy :north do
        twin AshStrangler.Test.Clinic.Legacy.NorthVisits
        phase :read_from_legacy
        refused_because "the north system writes these rows until its cutover"
        filter expr(not is_nil(seen_on) and patient_name != "hidden")
        key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
        map :patient, from: :patient_name
      end

      owned :native
    end
  end

  defp q!(sql), do: TestRepo.query!(sql, [], mode: :savepoint).rows

  setup do
    for %{up: up} <- AshStrangler.Migration.statements(DatedVisits), do: q!(up)

    q!("""
    INSERT INTO clinic_union.north_visits (id, patient_name, seen_on) VALUES
      (1, 'ada', '2026-01-02'), (2, 'bo', NULL), (3, 'hidden', '2026-01-04')
    """)

    :ok
  end

  test "the view shows only the rows the filter holds for, and the owned branch whole" do
    q!("INSERT INTO clinic_union.dated_visits (patient) VALUES ('hidden')")

    assert q!("SELECT __branch, patient FROM clinic_union.dated_visits ORDER BY patient") ==
             [["north", "ada"], ["native", "hidden"]]
  end

  test "the filter is part of the branch's declaration" do
    assert %Ash.Query.BooleanExpression{} = Info.branch(DatedVisits, :north).filter
  end

  test "a column only the filter reads is claimed as mapped by the union" do
    {modules, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        """
        defmodule AshStrangler.UnionFilterTest.Estate#{System.unique_integer([:positive])} do
          use AshStrangler.Estate

          estate do
            snapshot "test/fixtures/snapshot/clinic_union/catalog.json"
            resources [AshStrangler.UnionFilterTest.DatedVisits]
          end
        end
        """
        |> Code.compile_string()
        |> Enum.map(&elem(&1, 0))
      end)

    report = AshStrangler.Estate.evaluate(List.last(modules))
    claims = report.relations["clinic_union.north_visits"].columns["seen_on"].claims
    assert Enum.any?(claims, &(&1.kind == :mapped and &1.by == DatedVisits))
  end
end
