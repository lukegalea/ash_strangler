# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.BaselineTest do
  @moduledoc """
  Baseline + subsequent events reconstruct exactly what the forward mapping
  reports now, stamped with the mapping version that produced them.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Observation.Baseline
  alias AshStrangler.Test.Contract

  # Every legacy contract needs a client party: the tenant derives from it.
  defp contract!(attrs) do
    attrs =
      Map.new(attrs)
      |> Map.put_new_lazy(:client_party_id, fn ->
        insert_legacy_party!(organization_id: Ash.UUID.generate())
      end)

    insert_legacy_contract!(attrs)
  end

  @table "\"strangler_observations\""

  test "a baseline snapshots every legacy row through the forward mapping" do
    id = contract!(name: "baselined", value: Decimal.new(5))

    {:ok, %{group: group, count: count}} =
      Baseline.run(Contract, repo: TestRepo, isolation: :caller)

    assert count == 1
    assert is_binary(group)

    assert [row] = observations(resource: to_string(Contract), group: group)
    assert row["record_id"] == id
    assert row["category"] == "baseline"
    assert row["operation"] == "insert"
    assert decode(row["after"])["name"] == "baselined"
    assert decode(row["after"])["value"] == "5"

    # Baselines are never business events: no before, no changed set, and
    # unknown origin -- the snapshot SAW the row, it did not see anything
    # happen.
    assert is_nil(row["before"])
    assert row["origin"] == "unknown"
    assert decode(row["changed_attributes"]) == []
  end

  test "the baseline stamps the mapping version that produced it" do
    contract!(name: "versioned")
    id = contract!(name: "versioned-2")

    {:ok, _} = Baseline.run(Contract, repo: TestRepo, isolation: :caller)

    rows = observations(resource: to_string(Contract))
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1["mapping_version"] == AshStrangler.MappingVersion.hash(Contract)))

    # And the record ids are the legacy keys themselves (:identity).
    assert Enum.map(rows, & &1["record_id"]) |> Enum.sort() == Enum.sort([id, fetch_other_id(id)])
  end

  defp fetch_other_id(not_this) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!("SELECT id FROM legacy.clm_contracts WHERE id <> $1", [
        Ecto.UUID.dump!(not_this)
      ])

    {:ok, id} = Ecto.UUID.load(rows |> hd() |> hd())
    id
  end

  test "re-running with the same group inserts nothing" do
    contract!(name: "idempotent")

    {:ok, %{group: group, count: first}} =
      Baseline.run(Contract, repo: TestRepo, isolation: :caller)

    assert first == 1

    {:ok, %{group: ^group, count: 0}} =
      Baseline.run(Contract, repo: TestRepo, group: group, isolation: :caller)
  end

  test "baseline plus subsequent events reconstruct the forward state" do
    id = contract!(name: "reconstructed", value: Decimal.new(9))

    {:ok, _} = Baseline.run(Contract, repo: TestRepo, isolation: :caller)

    # The stream takes over: a legacy edit lands as an observation.
    TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'edited' WHERE id = $1", [
      Ecto.UUID.dump!(id)
    ])

    {:ok, _} = AshStrangler.Observation.Processor.drain(TestRepo, Contract, [], batch: 100)

    rows = observations(resource: to_string(Contract))

    # The baseline's captured_at is NOW (it ran after both events), so order
    # semantically: baseline first, then events by id.
    assert [baseline_row, insert_row, edit] =
             Enum.sort_by(rows, &{&1["source_event_id"] != nil, &1["source_event_id"]})

    [baseline_after, insert_after, edit_after] =
      Enum.map([baseline_row, insert_row, edit], &decode(&1["after"]))

    assert insert_after["name"] == "reconstructed"
    assert edit_after["name"] == "edited"

    # Reconstruct: baseline + events == what the forward mapping reports now.
    assert Ash.get!(Contract, id).name == edit_after["name"]
    assert baseline_after["name"] == "reconstructed"
  end

  test "default run owns a transaction outside the sandbox" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
      party_id = insert_legacy_party!(organization_id: Ash.UUID.generate())
      id = insert_legacy_contract!(name: "baseline-repeatable-read", client_party_id: party_id)
      group = Ash.UUID.generate()

      try do
        assert {:ok, %{group: ^group, count: count}} =
                 Baseline.run(Contract, repo: TestRepo, group: group)

        assert count >= 1

        %Postgrex.Result{rows: rows} =
          TestRepo.query!(
            "SELECT record_id FROM #{@table} WHERE baseline_group = $1 AND resource = $2",
            [Ecto.UUID.dump!(group), to_string(Contract)]
          )

        assert Enum.any?(rows, fn [record_id] -> record_id == to_string(id) end)
      after
        TestRepo.query!("DELETE FROM #{@table} WHERE baseline_group = $1", [
          Ecto.UUID.dump!(group)
        ])

        TestRepo.query!("DELETE FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

        TestRepo.query!(
          "DELETE FROM \"legacy_change_events\" WHERE source_schema = $1 AND source_table = $2 AND primary_key ->> 'id' = $3",
          ["legacy", "clm_contracts", to_string(id)]
        )

        TestRepo.query!("DELETE FROM legacy.clm_parties WHERE id = $1", [
          Ecto.UUID.dump!(party_id)
        ])
      end
    end)
  end

  test "a resource without a ledger is refused -- a snapshot without a stream loses everything after it" do
    assert {:error, :no_ledger} = Baseline.run(AshStrangler.Test.LegacyUser, repo: TestRepo)
  end

  # --- harness -----------------------------------------------------------------

  defp observations(resource: resource, group: group) do
    rows =
      TestRepo.query!(
        """
        SELECT record_id, category, operation, after, before, changed_attributes,
               origin, mapping_version, source_event_id, captured_at
          FROM #{@table}
         WHERE resource = $1 AND baseline_group = $2
         ORDER BY captured_at
        """,
        [resource, Ecto.UUID.dump!(group)]
      )

    %Postgrex.Result{rows: rows} = rows

    Enum.map(rows, fn row ->
      ~w(record_id category operation after before changed_attributes origin mapping_version source_event_id captured_at)
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  defp observations(resource: resource) do
    rows =
      TestRepo.query!(
        """
        SELECT record_id, category, operation, after, before, changed_attributes,
               origin, mapping_version, source_event_id, captured_at
          FROM #{@table}
         WHERE resource = $1
         ORDER BY captured_at
        """,
        [resource]
      )

    %Postgrex.Result{rows: rows} = rows

    Enum.map(rows, fn row ->
      ~w(record_id category operation after before changed_attributes origin mapping_version source_event_id captured_at)
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(nil), do: nil
  defp decode(other), do: other
end
