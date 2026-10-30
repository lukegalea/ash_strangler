# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ObservationTest do
  @moduledoc """
  The observation acceptance properties, against the real ledger and the
  real consumer:

    7. capture during observer downtime loses nothing, intermediates
       preserved;
    8. replay duplicates neither effects nor events; a host write through
       `AshStrangler.Context` produces correlated capture with no duplicate
       effect;
    and the invalidation rule: an event on relation R unmoors every OTHER
    strangled resource that gathers from R.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Observation.Processor
  alias AshStrangler.Test.{Contract, RecordingObserver}

  # Local copies of the ContractTest helpers -- private there, and these tests
  # drive the same commands.
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
      client_party_id: client,
      vendor_party_id: vendor
    })
  end

  defp update!(record, action, attrs) do
    record |> Ash.Changeset.for_update(action, attrs, authorize?: false) |> Ash.update!()
  end

  setup do
    Application.put_env(:ash_strangler_test, :recording_mode, :ok)
    on_exit(fn -> Application.delete_env(:ash_strangler_test, :recording_mode) end)
    :ok
  end

  defp drain!(count \\ 100) do
    {:ok, n} = Processor.drain(TestRepo, Contract, [RecordingObserver], batch: count)
    n
  end

  defp observations_for(resource) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT source_event_id, operation, after, before, changed_attributes,
               origin, correlation_id, mapping_version, invalidated_attributes
          FROM "strangler_observations"
         WHERE resource = $1
         ORDER BY source_event_id
        """,
        [to_string(resource)]
      )

    keys = [
      :source_event_id,
      :operation,
      :after,
      :before,
      :changed_attributes,
      :origin,
      :correlation_id,
      :mapping_version,
      :invalidated_attributes
    ]

    Enum.map(rows, fn row ->
      keys
      |> Enum.zip(row)
      |> Map.new(fn
        {k, v} when k in [:after, :before, :changed_attributes, :invalidated_attributes] ->
          {k, if(is_binary(v), do: Jason.decode!(v), else: v)}

        {k, v} ->
          {k, v}
      end)
    end)
  end

  describe "capture during downtime" do
    test "N rapid legacy changes drain to N observations with every intermediate" do
      record = draft_contract!(name: "v0")

      # The observer is DOWN: nothing drains while the legacy application
      # keeps writing.
      names = ["v1", "v2", "v3"]

      Enum.each(names, fn name ->
        TestRepo.query!("UPDATE legacy.clm_contracts SET name = $1 WHERE id = $2", [
          name,
          Ecto.UUID.dump!(record.id)
        ])
      end)

      # One INSERT (the create) plus the three updates.
      assert drain!() == 4

      observations = observations_for(Contract)
      assert length(observations) == 4

      # Every intermediate preserved, in event order -- not collapsed to the
      # latest value.
      afters =
        Enum.map(observations, & &1.after["name"])
        |> Enum.filter(&(&1 in names))

      assert afters == names
    end

    test "replay duplicates neither observations nor effects" do
      record = draft_contract!()

      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'replayed' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      drain!()
      effects_after_first = length(RecordingObserver.effects(TestRepo))
      observations_after_first = observations_for(Contract) |> length()

      assert effects_after_first >= 1

      # The drain is idempotent: same events, same store, same effects.
      drain!()

      assert observations_for(Contract) |> length() == observations_after_first
      assert length(RecordingObserver.effects(TestRepo)) == effects_after_first
    end
  end

  describe "correlated capture" do
    test "a host write through Context captures origin, correlation and actor" do
      record = draft_contract!()

      AshStrangler.Context.set(
        TestRepo,
        [origin: :host, actor: "luke", correlation_id: "corr-42", causation_id: "cause-7"],
        fn ->
          update!(record, :negotiate_terms, %{name: "contextual"})
        end
      )

      drain!()

      assert [observation] =
               Enum.filter(observations_for(Contract), &(&1.after["name"] == "contextual"))

      assert observation.origin == "host"
      assert observation.correlation_id == "corr-42"
    end

    test "a legacy write without context stays unknown" do
      record = draft_contract!()

      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'legacy edit' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      drain!()

      assert [observation] =
               Enum.filter(observations_for(Contract), &(&1.after["name"] == "legacy edit"))

      assert observation.origin == "unknown"
    end

    test "a host write produces no duplicate consumer effect" do
      record = draft_contract!()

      AshStrangler.Context.set(TestRepo, [origin: :host], fn ->
        update!(record, :negotiate_terms, %{name: "once"})
      end)

      drain!()
      effects_after_first = length(RecordingObserver.effects(TestRepo))

      drain!()

      assert length(RecordingObserver.effects(TestRepo)) == effects_after_first
    end
  end

  describe "receipts" do
    test "an erroring observer accumulates attempts without effects, then recovers" do
      record = draft_contract!()

      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'receipted' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      Application.put_env(:ash_strangler_test, :recording_mode, {:error, :boom})

      assert {:error, {:observer_errors, _}} =
               Processor.drain(TestRepo, Contract, [RecordingObserver], batch: 100)

      events = Enum.filter(observations_for(Contract), &(&1.after["name"] == "receipted"))
      assert [%{source_event_id: event_id}] = events

      receipt = RecordingObserver.receipt(TestRepo, receipt_observation_id(event_id))
      assert %{state: "error", attempts: 1} = receipt
      assert RecordingObserver.effects(TestRepo) == []

      assert {:error, {:observer_errors, _}} =
               Processor.drain(TestRepo, Contract, [RecordingObserver], batch: 100)

      assert %{state: "error", attempts: 2} =
               RecordingObserver.receipt(TestRepo, receipt_observation_id(event_id))

      # The observer recovers: the next drain records the effect and the
      # receipt closes.
      Application.put_env(:ash_strangler_test, :recording_mode, :ok)
      drain!()

      # A closed receipt resets attempts: they are the retry policy's state,
      # not history. The recorded errors are gone with it -- replay and the
      # observation log are the record.
      assert %{state: "ok", attempts: 0} =
               RecordingObserver.receipt(TestRepo, receipt_observation_id(event_id))

      # The recovered observation's effect arrives exactly once (the create
      # effect was recorded while the observer was healthy).
      effects = RecordingObserver.effects(TestRepo)
      assert length(Enum.filter(effects, fn [id, _] -> id == event_id end)) == 1

      # And a closed receipt is never re-delivered.
      drain!()

      assert %{state: "ok"} =
               RecordingObserver.receipt(TestRepo, receipt_observation_id(event_id))
    end

    test "quarantine is immediate and stops auto-retry" do
      record = draft_contract!()

      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'quarantined' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      Application.put_env(:ash_strangler_test, :recording_mode, :quarantine)
      drain!()

      event_id =
        observations_for(Contract)
        |> Enum.find(&(&1.after["name"] == "quarantined"))
        |> Map.fetch!(:source_event_id)

      receipt = RecordingObserver.receipt(TestRepo, receipt_observation_id(event_id))
      assert %{state: "quarantined", attempts: 0} = receipt

      Application.put_env(:ash_strangler_test, :recording_mode, :ok)
      drain!()

      # Quarantined receipts are not retried: replay (--replay) is the way
      # back, and that deletes receipts rather than flipping states.
      assert %{state: "quarantined"} =
               RecordingObserver.receipt(TestRepo, receipt_observation_id(event_id))

      assert RecordingObserver.effects(TestRepo) == []

      TestRepo.query!("DELETE FROM \"strangler_receipts\" WHERE consumer = $1", [
        to_string(RecordingObserver)
      ])

      drain!()
      # Two events (create + update), each delivered exactly once.
      assert length(RecordingObserver.effects(TestRepo)) == 2
    end
  end

  # The invalidation rule, end to end: an event on the addresses relation
  # unmoors the Customer resource's gathered `city`, whose source row is the
  # one that moved.
  describe "invalidations" do
    test "an event on a gathered relation invalidates the gathering resource" do
      install_joined_fixtures()

      %Postgrex.Result{rows: [[account_id]]} =
        TestRepo.query!(
          "INSERT INTO joined_legacy.accounts (email) VALUES ('a@example.com') RETURNING id"
        )

      %Postgrex.Result{rows: [[address_id]]} =
        TestRepo.query!(
          "INSERT INTO joined_legacy.addresses (account_id, city) VALUES ($1, 'Lisbon') RETURNING id",
          [account_id]
        )

      TestRepo.query!("UPDATE joined_legacy.addresses SET city = 'Porto' WHERE id = $1", [
        address_id
      ])

      {:ok, _} =
        Processor.drain(TestRepo, AshStrangler.ObservationTest.AddressLedgerProbe, [],
          batch: 100,
          scope: [
            AshStrangler.ObservationTest.AddressLedgerProbe,
            AshStrangler.ObservationTest.JoinProbe
          ]
        )

      invalidations =
        observations_for(AshStrangler.ObservationTest.JoinProbe)
        |> Enum.filter(&(&1.operation == "invalidate"))

      # One invalidation per event (the fixture's insert and the city edit),
      # each naming exactly the gathered attribute.
      assert invalidations != []
      assert Enum.all?(invalidations, &(&1.invalidated_attributes == ["city"]))

      # Never a re-read presented as history.
      assert Enum.all?(invalidations, &(&1.after == nil))
    end
  end

  defmodule ObsLegacy do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshStrangler.ObservationTest.ObsLegacy.Accounts
      resource AshStrangler.ObservationTest.ObsLegacy.Addresses
      resource AshStrangler.ObservationTest.AddressLedgerProbe
      resource AshStrangler.ObservationTest.JoinProbe
    end
  end

  defmodule ObsLegacy.Accounts do
    @moduledoc false
    use Ash.Resource,
      domain: AshStrangler.ObservationTest.ObsLegacy,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Twin]

    postgres do
      table "accounts"
      schema "joined_legacy"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :email, :string, allow_nil?: false, public?: true
    end

    relationships do
      has_one :address, AshStrangler.ObservationTest.ObsLegacy.Addresses do
        public? true
        destination_attribute :account_id
      end
    end

    actions do
      defaults [:read]
    end
  end

  defmodule ObsLegacy.Addresses do
    @moduledoc false
    use Ash.Resource,
      domain: AshStrangler.ObservationTest.ObsLegacy,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Twin]

    postgres do
      table "addresses"
      schema "joined_legacy"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :account_id, :integer, allow_nil?: false, public?: true
      attribute :city, :string, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule AddressLedgerProbe do
    @moduledoc "A ledger on the ADDRESSES relation: its events unmoor JoinProbe's city."
    use Ash.Resource,
      domain: AshStrangler.ObservationTest.ObsLegacy,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Resource]

    postgres do
      table "address_ledger_v"
      schema "joined"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
      attribute :city, :string, public?: true
    end

    actions do
      defaults [:read]
    end

    strangler do
      phase :read_from_legacy

      source AshStrangler.ObservationTest.ObsLegacy.Addresses do
        notify? true
        ledger? true
        notify_channel "ash_strangler_address_observation"

        key :id,
          from: :id,
          strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

        map :city, from: :city
      end
    end
  end

  defmodule JoinProbe do
    @moduledoc "Gathers the address's city through the account--address join."
    use Ash.Resource,
      domain: AshStrangler.ObservationTest.ObsLegacy,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Resource]

    postgres do
      table "join_probe_v"
      schema "joined"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
      attribute :city, :string, public?: true
    end

    actions do
      defaults [:read]
    end

    strangler do
      phase :read_from_legacy

      source AshStrangler.ObservationTest.ObsLegacy.Accounts do
        key :id,
          from: :id,
          strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

        map :city,
          from: expr(address.city),
          read_only?: true,
          because: "The address owns its city."
      end
    end
  end

  defp install_joined_fixtures do
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS joined", [])
    TestRepo.query!("DROP SCHEMA IF EXISTS joined_legacy CASCADE", [])
    TestRepo.query!("CREATE SCHEMA joined_legacy", [])

    TestRepo.query!("CREATE TABLE joined_legacy.plans (id bigserial PRIMARY KEY, name text)", [])

    TestRepo.query!(
      "CREATE TABLE joined_legacy.accounts (id bigserial PRIMARY KEY, email text NOT NULL)",
      []
    )

    TestRepo.query!(
      "CREATE TABLE joined_legacy.addresses (id bigserial PRIMARY KEY, account_id bigint NOT NULL REFERENCES joined_legacy.accounts(id), city text)",
      []
    )

    for resource <- [AddressLedgerProbe, JoinProbe] do
      for stmt <- AshStrangler.Migration.statements(resource), do: TestRepo.query!(stmt.up, [])
    end
  end

  defp receipt_observation_id(source_event_id) do
    %Postgrex.Result{rows: [[id]]} =
      TestRepo.query!(
        "SELECT id FROM \"strangler_observations\" WHERE source_event_id = $1 AND resource = $2",
        [source_event_id, to_string(Contract)]
      )

    {:ok, uuid} = Ecto.UUID.load(id)
    uuid
  end
end
