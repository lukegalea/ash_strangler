# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ContractTest do
  @moduledoc """
  The shared-rows acceptance properties, over `legacy.clm_contracts`:

    1. a legacy SQL edit is visible through the canonical resource with no
       sync job of any kind;
    2. a canonical write is visible to legacy SQL immediately after commit;
    5. a create from either side yields a valid identity in BOTH key spaces
       (here one key space — the legacy key IS the canonical id), and the
       correct derived tenant;
    6. a command touching shared and extension data rolls back atomically.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Test.Contract

  @extension_table Contract.extension_table()

  describe "read-through (legacy edit, canonical read, no sync job)" do
    test "a raw SQL edit is visible through the resource on the next read" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      id = insert_legacy_contract!(client_party_id: party, name: "before")

      # The legacy application's own write path: raw SQL, no Ash, no trigger
      # from this package's side. Nothing to sync -- there is one row.
      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'after' WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

      assert %{name: "after"} = Ash.get!(Contract, id) |> Map.from_struct()
    end

    test "a legacy edit of the joined vendor name reads through the join" do
      org = Ash.UUID.generate()
      client = insert_legacy_party!(organization_id: org)
      vendor = insert_legacy_party!(organization_id: Ash.UUID.generate(), name: "Old Vendor")
      id = insert_legacy_contract!(client_party_id: client, vendor_party_id: vendor)

      assert %{vendor_name: "Old Vendor"} = Ash.get!(Contract, id) |> Map.from_struct()

      TestRepo.query!("UPDATE legacy.clm_parties SET name = 'New Vendor' WHERE id = $1", [
        Ecto.UUID.dump!(vendor)
      ])

      assert %{vendor_name: "New Vendor"} = Ash.get!(Contract, id) |> Map.from_struct()
    end
  end

  describe "write-through (canonical write, legacy read)" do
    test "an Ash update is visible to raw SQL immediately" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      id = insert_legacy_contract!(client_party_id: party, name: "v1")

      record = Ash.get!(Contract, id)
      Ash.update!(record, %{name: "v2", payment_term: "net-60"})

      %Postgrex.Result{rows: [[name, term]]} =
        TestRepo.query!("SELECT name, payment_term FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      assert {name, term} == {"v2", "net-60"}
    end
  end

  describe "identity and tenancy" do
    test "a host create mints the id the legacy row carries, and derives the tenant" do
      org = Ash.UUID.generate()
      client = insert_legacy_party!(organization_id: org)
      vendor = insert_legacy_party!(organization_id: Ash.UUID.generate())

      record =
        Ash.create!(Contract, %{
          name: "host-created",
          value: Decimal.new(100),
          client_party_id: client,
          vendor_party_id: vendor
        })

      # The host minted the id; the legacy row carries it unchanged. One key
      # space, because :identity means the legacy key IS the canonical id.
      %Postgrex.Result{rows: [[legacy_id, org_id]]} =
        TestRepo.query!(
          "SELECT c.id, client_party.organization_id
             FROM legacy.clm_contracts c
             LEFT JOIN legacy.clm_parties client_party ON client_party.id = c.client_party_id
            WHERE c.id = $1",
          [Ecto.UUID.dump!(record.id)]
        )

      assert Ecto.UUID.load(legacy_id) == {:ok, record.id}
      assert Ecto.UUID.load(org_id) == {:ok, org}

      # And the resource derives it too -- the tenant was never in the command.
      assert record.organization_id == org
    end

    test "a legacy-side create is readable through the resource under the same id" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      id = insert_legacy_contract!(client_party_id: party, name: "legacy-created")

      assert %{name: "legacy-created", organization_id: ^org} =
               Ash.get!(Contract, id) |> Map.from_struct()
    end

    test "the tenant attribute refuses a host write" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      id = insert_legacy_contract!(client_party_id: party)
      record = Ash.get!(Contract, id)

      # First line of defense: the actions do not accept the tenant. The
      # second is the trigger's read-only guard (type :masked), which holds
      # even if an action later accepts the attribute -- the reason the lens
      # has no write direction at all.
      assert_raise Ash.Error.Invalid,
                   ~r/No such input `organization_id`/,
                   fn ->
                     Ash.update!(record, %{organization_id: Ash.UUID.generate()})
                   end
    end
  end

  describe "the extension store" do
    test "negotiating notes live beside the shared rows and round-trip" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      id = insert_legacy_contract!(client_party_id: party)

      record = Ash.get!(Contract, id)
      assert record.negotiating_notes == ""

      Ash.update!(record, %{negotiating_notes: "terms under discussion"})

      %Postgrex.Result{rows: [[notes]]} =
        TestRepo.query!("SELECT negotiating_notes FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      assert notes == "terms under discussion"

      # And the shared columns are untouched by the extension write.
      %Postgrex.Result{rows: [[name]]} =
        TestRepo.query!("SELECT name FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      assert name == record.name
    end
  end

  describe "atomicity" do
    test "a command whose legacy write fails leaves neither store touched" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      id = insert_legacy_contract!(client_party_id: party)

      record = Ash.get!(Contract, id)
      original_notes = record.negotiating_notes

      # The legacy CHECK (value >= 0) fails INSIDE the legacy write -- after
      # the transaction opened. The extension upsert must roll back with it.
      assert_raise Ash.Error.Unknown, fn ->
        Ash.update!(record, %{value: Decimal.new(-5), negotiating_notes: "half-written"})
      end

      %Postgrex.Result{num_rows: 0} =
        TestRepo.query!("SELECT 1 FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      %Postgrex.Result{rows: [[value]]} =
        TestRepo.query!("SELECT value FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      assert is_nil(value)

      assert Ash.get!(Contract, id).negotiating_notes == original_notes
    end

    test "a host create whose legacy insert fails leaves no extension row" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)

      assert_raise Ash.Error.Unknown, fn ->
        Ash.create!(Contract, %{
          name: "doomed",
          value: Decimal.new(-1),
          client_party_id: party,
          negotiating_notes: "never committed"
        })
      end

      # The create never returned, so the minted id is unknown -- but the
      # sandbox transaction is fresh: both stores holding zero rows for this
      # party IS the proof nothing half-committed.
      %Postgrex.Result{rows: [[ext_rows]]} =
        TestRepo.query!("SELECT count(*) FROM #{@extension_table}")

      assert ext_rows == 0

      %Postgrex.Result{num_rows: 0} =
        TestRepo.query!("SELECT 1 FROM legacy.clm_contracts WHERE name = 'doomed'")
    end
  end
end
