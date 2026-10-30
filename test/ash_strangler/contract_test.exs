# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ContractTest do
  @moduledoc """
  The shared-rows acceptance properties, over `legacy.clm_contracts`:

    1. a legacy SQL edit is visible through the canonical resource with no
       sync job of any kind;
    2. a canonical write is visible to legacy SQL immediately after commit;
    3. transitions write the declared backward `set:` and legacy reads the
       expected flags;
    4. unrepresentable states behave as declared;
    5. a create from either side yields a valid identity in BOTH key spaces
       (here one key space — the legacy key IS the canonical id), and the
       correct derived tenant;
    6. a command touching shared and extension data rolls back atomically.

  There is no primary `:update` on the fixture: every state change is a named
  command whose only transition is its own, and editing a draft goes through
  `negotiate_terms` — the same shape the host's real contract model takes.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Test.Contract

  @extension_table Contract.extension_table()

  test "the mapping fragment target is checked even when both modules share a file" do
    assert :ok = AshStrangler.Mapping.verify_target(Contract)
  end

  # --- helpers -----------------------------------------------------------------

  defp draft_contract!(attrs \\ []) do
    attrs = Map.new(attrs)
    org = Map.get_lazy(attrs, :organization_id, fn -> Ash.UUID.generate() end)

    client =
      Map.get_lazy(attrs, :client_party_id, fn -> insert_legacy_party!(organization_id: org) end)

    vendor =
      Map.get_lazy(attrs, :vendor_party_id, fn ->
        insert_legacy_party!(organization_id: Ash.UUID.generate())
      end)

    Ash.create!(Contract, %{
      name: Map.get(attrs, :name, "contract-#{System.unique_integer([:positive])}"),
      value: Map.get(attrs, :value),
      payment_term: Map.get(attrs, :payment_term),
      client_party_id: client,
      vendor_party_id: vendor
    })
  end

  defp update!(record, action, attrs) do
    record |> Ash.Changeset.for_update(action, attrs, authorize?: false) |> Ash.update!()
  end

  defp legacy_flags!(id) do
    %Postgrex.Result{rows: [[processed, verified]]} =
      TestRepo.query!("SELECT processed, verified FROM legacy.clm_contracts WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    {processed, verified}
  end

  describe "read-through (legacy edit, canonical read, no sync job)" do
    test "a raw SQL edit is visible through the resource on the next read" do
      record = draft_contract!(name: "before")

      # The legacy application's own write path: raw SQL, no Ash, no trigger
      # from this package's side. Nothing to sync -- there is one row.
      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'after' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      assert %{name: "after"} = Ash.reload!(record) |> Map.from_struct() |> Map.take([:name])
    end

    test "a legacy edit of the joined vendor name reads through the join" do
      record = draft_contract!()
      vendor_id = record.vendor_party_id

      assert %{vendor_name: name} = Ash.reload!(record) |> Map.from_struct()
      assert is_binary(name)

      TestRepo.query!("UPDATE legacy.clm_parties SET name = 'New Vendor' WHERE id = $1", [
        Ecto.UUID.dump!(vendor_id)
      ])

      assert %{vendor_name: "New Vendor"} = Ash.reload!(record) |> Map.from_struct()
    end
  end

  describe "write-through (canonical write, legacy read)" do
    test "a canonical update is visible to raw SQL immediately" do
      record = draft_contract!(name: "v1")
      update!(record, :negotiate_terms, %{name: "v2", payment_term: "net-60"})

      %Postgrex.Result{rows: [[name, term]]} =
        TestRepo.query!("SELECT name, payment_term FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
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
      record = draft_contract!()

      # First line of defense: the actions do not accept the tenant. The
      # second is the trigger's read-only guard (type :masked), which holds
      # even if an action later accepts the attribute -- the reason the lens
      # has no write direction at all.
      assert_raise Ash.Error.Invalid,
                   ~r/No such input `organization_id`/,
                   fn ->
                     update!(record, :negotiate_terms, %{organization_id: Ash.UUID.generate()})
                   end
    end
  end

  describe "the extension store" do
    test "negotiating notes live beside the shared rows and round-trip" do
      record = draft_contract!()
      assert record.negotiating_notes == ""

      update!(record, :negotiate_terms, %{negotiating_notes: "terms under discussion"})

      %Postgrex.Result{rows: [[notes]]} =
        TestRepo.query!("SELECT negotiating_notes FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert notes == "terms under discussion"

      # And the shared columns are untouched by the extension write.
      %Postgrex.Result{rows: [[name]]} =
        TestRepo.query!("SELECT name FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert name == record.name
    end

    test "provenance lives in the extension table and rolls back with the command" do
      org = Ash.UUID.generate()
      party = insert_legacy_party!(organization_id: org)
      actor = Ash.UUID.generate()

      record =
        Ash.create!(Contract, %{
          name: "provenance",
          client_party_id: party,
          created_by_id: actor
        })

      %Postgrex.Result{rows: [[stored]]} =
        TestRepo.query!("SELECT created_by_id FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert Ecto.UUID.load(stored) == {:ok, actor}

      # A legacy constraint failure rolls provenance back with the shared row
      # and the rest of the extension write.
      assert_raise Ash.Error.Unknown, fn ->
        Ash.create!(Contract, %{
          name: "provenance-doomed",
          value: Decimal.new(-1),
          client_party_id: party,
          created_by_id: actor
        })
      end

      %Postgrex.Result{rows: [[count]]} =
        TestRepo.query!(
          "SELECT count(*) FROM #{@extension_table} WHERE created_by_id = $1",
          [Ecto.UUID.dump!(actor)]
        )

      assert count == 1
    end
  end

  describe "atomicity" do
    test "a command whose legacy write fails leaves neither store touched" do
      record = draft_contract!()
      original_notes = record.negotiating_notes

      # The legacy CHECK (value >= 0) fails INSIDE the legacy write -- after
      # the transaction opened. The extension upsert must roll back with it.
      assert_raise Ash.Error.Unknown, fn ->
        update!(record, :negotiate_terms, %{
          value: Decimal.new(-5),
          negotiating_notes: "half-written"
        })
      end

      # The extension row itself was created by the CREATE (INSERT always
      # writes one); what must NOT be there is the command's half-written
      # note. The rollback covers the extension write with the legacy one.
      %Postgrex.Result{rows: [[notes]]} =
        TestRepo.query!("SELECT negotiating_notes FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert is_nil(notes)

      %Postgrex.Result{rows: [[value]]} =
        TestRepo.query!("SELECT value FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert is_nil(value)

      assert Ash.reload!(record).negotiating_notes == original_notes
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

  describe "the lifecycle over the collapse" do
    test "execute writes the declared backward set; legacy reads the flags" do
      record = draft_contract!()
      assert record.lifecycle_state == :draft
      assert legacy_flags!(record.id) == {false, false}

      record = update!(record, :negotiate_terms, %{})
      record = update!(record, :finalise_terms, %{})

      # :ready_to_execute is LOSSY: legacy only knows un-executed contracts as
      # draft, and the read-back says so.
      assert record.lifecycle_state == :draft
      assert legacy_flags!(record.id) == {false, false}

      record = update!(record, :execute, %{})

      assert record.lifecycle_state == :active
      assert legacy_flags!(record.id) == {true, true}
    end

    test "archive stamps the legacy timestamp through the declared set" do
      record = draft_contract!()

      record =
        record
        |> update!(:negotiate_terms, %{})
        |> update!(:finalise_terms, %{})
        |> update!(:execute, %{})
        |> update!(:terminate, %{})

      assert record.lifecycle_state == :terminated
      assert legacy_flags!(record.id) == {true, false}

      %Postgrex.Result{rows: [[archived]]} =
        TestRepo.query!("SELECT archived FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert is_nil(archived)

      record = update!(record, :archive, %{})

      assert record.lifecycle_state == :archived

      %Postgrex.Result{rows: [[archived]]} =
        TestRepo.query!("SELECT archived FROM legacy.clm_contracts WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert %NaiveDateTime{} = archived
    end

    test "negotiating stores in the extension and round-trips" do
      record = draft_contract!()
      record = update!(record, :negotiate_terms, %{})

      assert record.lifecycle_state == :negotiating

      %Postgrex.Result{rows: [[stored]]} =
        TestRepo.query!(
          "SELECT lifecycle_state FROM #{@extension_table} WHERE id = $1",
          [Ecto.UUID.dump!(record.id)]
        )

      assert stored == "negotiating"

      # An unrelated legacy edit does not disturb the extension state, and the
      # read-back still says negotiating.
      TestRepo.query!("UPDATE legacy.clm_contracts SET payment_term = 'net-30' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      assert Ash.reload!(record).lifecycle_state == :negotiating
    end

    test "cancel raises the declared refusal and changes nothing" do
      record = draft_contract!()

      assert_raise Ash.Error.Unknown,
                   ~r/no cancelled encoding; cancelling is refused while legacy is authoritative/,
                   fn ->
                     update!(record, :cancel, %{})
                   end

      assert legacy_flags!(record.id) == {false, false}
      assert Ash.reload!(record).lifecycle_state == :draft
    end

    test "the machine guard refuses cancel from :active before the trigger ever speaks" do
      record = draft_contract!()

      record =
        record
        |> update!(:negotiate_terms, %{})
        |> update!(:finalise_terms, %{})
        |> update!(:execute, %{})

      error =
        assert_raise Ash.Error.Invalid, fn ->
          update!(record, :cancel, %{})
        end

      # The MACHINE's refusal, not the trigger's: the message is about the
      # target state being invalid from here, not about the legacy encoding.
      refute Exception.message(error) =~ "unrepresentable in legacy"
    end

    test "expired is derived: shift expiry_date in SQL and the read follows" do
      record = draft_contract!(value: Decimal.new(1))
      assert record.lifecycle_state == :draft

      TestRepo.query!(
        "UPDATE legacy.clm_contracts SET expiry_date = CURRENT_DATE - 1 WHERE id = $1",
        [Ecto.UUID.dump!(record.id)]
      )

      assert Ash.reload!(record).lifecycle_state == :expired
    end

    test "there is no generic edit path, and the state attribute is not accepted" do
      record = draft_contract!()

      assert_raise ArgumentError, ~r/No such update action/, fn ->
        update!(record, :update, %{name: "edited"})
      end

      assert_raise Ash.Error.Invalid, ~r/No such input `lifecycle_state`/, fn ->
        update!(record, :negotiate_terms, %{lifecycle_state: :active})
      end
    end

    test "the declared loss is reported by the check task" do
      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      previous = Application.get_env(:ash_strangler, :ash_domains)
      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.Test.Domain])

      on_exit(fn ->
        Application.put_env(:ash_strangler, :ash_domains, previous)
        Mix.shell(shell)
      end)

      Mix.Task.rerun("ash_strangler.check", ["--domain", "AshStrangler.Test.Domain", "--no-data"])

      output = drain()

      assert output =~ "declared losses"
      assert output =~ "terms finalised but not executed"
      assert output =~ "legacy only knows un-executed contracts as draft"
    end
  end

  defp drain(collected \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> drain([message | collected])
    after
      0 -> collected |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
