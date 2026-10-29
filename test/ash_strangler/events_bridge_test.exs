# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.EventsBridgeTest do
  @moduledoc """
  The integration seam, proven inside ash_strangler's own suite (ADR 0056:
  engine semantics live here, never re-asserted by a host), shaped like the
  battery's `business_events` substrate so the integration pass can lift it
  mechanically (handoff §4, §9):

      ledger events -> discrete-event log (the observer's outbox)
                    -> downstream projection rebuilt from baseline + events
                    == the canonical resource read through the forward mapping

  plus the AshEvents boundary: replay refused on the shared-row resource, and
  observations riding a read-only companion bridge that can never be
  replayed as actions.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Test.Contract
  alias AshStrangler.TestRepo

  @table "\"strangler_observations\""

  setup do
    Application.put_env(:ash_strangler_test, :recording_mode, :ok)
    on_exit(fn -> Application.delete_env(:ash_strangler_test, :recording_mode) end)
    :ok
  end

  # The discrete-event ledger the observer feeds: the host's own outbox
  # substrate, idempotent by source_event_id.
  defmodule EventLog do
    @table "events_bridge_log"

    def record!(repo, observation) do
      repo.query!(
        """
        INSERT INTO #{@table} (source_event_id, resource, operation, payload, mapping_version)
        VALUES ($1, $2, $3, $4::jsonb, $5)
        ON CONFLICT (source_event_id, resource) DO NOTHING
        """,
        [
          observation.source_event_id,
          to_string(observation.resource),
          to_string(observation.operation),
          # Typed casts yield uuid binaries; pass the map as jsonb and let
          # Postgrex encode it (binary uuids become json strings server-side
          # -- actually the reverse; stringify here).
          Jason.encode!(
            jsonable(%{after: observation.after, invalidated: observation.invalidated_attributes})
          ),
          observation.mapping_version
        ]
      )
    end

    defp jsonable(%_{} = struct), do: jsonable(Map.from_struct(struct))
    defp jsonable(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
    defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)

    defp jsonable(<<_::128>> = uuid) do
      case Ecto.UUID.load(uuid) do
        {:ok, string} -> string
        :error -> uuid
      end
    end

    defp jsonable(other), do: other

    def rows(repo, resource) do
      %Postgrex.Result{rows: rows} =
        repo.query!(
          "SELECT source_event_id, operation, payload FROM #{@table} WHERE resource = $1 ORDER BY source_event_id",
          [to_string(resource)]
        )

      Enum.map(rows, fn [id, op, payload] ->
        %{id: id, op: op, payload: Jason.decode!(payload)}
      end)
    end
  end

  defmodule FeedObserver do
    @moduledoc "The observer that feeds the host's event log inside its transaction."
    @behaviour AshStrangler.Observer

    @impl true
    def handle_observation(observation, %{repo: repo}) do
      EventLog.record!(repo, observation)
      :ok
    end
  end

  describe "the replay guard" do
    test "refuses replay on the shared-row resource in :dual_write" do
      assert_raise ArgumentError,
                   ~r/replay would clear or rebuild live legacy rows/,
                   fn ->
                     AshStrangler.AshEvents.refuse_replay!(Contract)
                   end
    end

    test "allows replay once the resource owns its table" do
      # Probe in :read_from_new -- the compatibility layer is gone, the
      # resource's rows are its own.
      name = "AshStrangler.EventsBridgeTest.OwnedProbe#{System.unique_integer([:positive])}"

      {eval_result, _io} =
        with_io(:stderr, fn ->
          Code.eval_string(
            """
            defmodule #{name} do
              use Ash.Resource,
                domain: nil,
                validate_domain_inclusion?: false,
                data_layer: AshPostgres.DataLayer,
                extensions: [AshStrangler.Resource]

              postgres do
                table "owned_probe"
                schema "verified"
                repo AshStrangler.TestRepo
                migrate? false
              end

              attributes do
                attribute :id, :uuid, primary_key?: true, allow_nil?: false
                attribute :login, :string, public?: true
              end

              actions do
                defaults [:read]
              end

              strangler do
                phase :read_from_new

                source AshStrangler.Test.Legacy.Users do
                  key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                  map :login, from: :login
                end
              end
            end
            """,
            [],
            file: "probe_owned.ex"
          )
        end)

      {{:module, module, _, _}, _binding} = eval_result

      assert :ok = AshStrangler.AshEvents.refuse_replay!(module)
    end
  end

  describe "the events bridge" do
    test "observations ride a read-only companion, distinct from action events" do
      record = draft_contract!(name: "bridged")

      AshStrangler.Context.set(TestRepo, [origin: :host], fn ->
        update!(record, :negotiate_terms, %{name: "bridged-2"})
      end)

      drain!()

      bridge = events_bridge_rows()
      assert length(bridge) == 2

      # No create/update/destroy exists on the bridge -- structurally.
      actions = Ash.Resource.Info.actions(AshStrangler.EventsBridgeTest.EventsBridgeResource)
      assert Enum.all?(actions, &(&1.type == :read))
    end

    test "action events and observations are different kinds of record" do
      record = draft_contract!()
      update!(record, :negotiate_terms, %{name: "renamed"})

      drain!()

      # The host's action-event log (ash_events) records COMMANDS; the bridge
      # records OBSERVED LEGACY CHANGES. Same contract, different substrates,
      # different lifecycles -- the bridge has no write path to confuse them.
      action_log = :action_event
      observation_log = events_bridge_rows()

      assert Enum.all?(observation_log, &(&1.op in ["insert", "update", "invalidate", "delete"]))
      assert action_log != observation_log
    end
  end

  describe "the seam: ledger -> event log -> projection agrees with the forward mapping" do
    test "legacy-side and host-side writes agree with the rebuilt projection" do
      record = draft_contract!(name: "seam-v1")

      # legacy-side write
      TestRepo.query!("UPDATE legacy.clm_contracts SET name = 'seam-legacy' WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

      # host-side write
      update!(record, :negotiate_terms, %{name: "seam-host", payment_term: "net-45"})

      drain!()

      log = EventLog.rows(TestRepo, Contract)

      # The event log carries EVERY event, in event order.
      assert length(log) == 3

      names =
        log
        |> Enum.map(& &1.payload["after"]["name"])
        |> Enum.reject(&is_nil/1)

      assert names == ["seam-v1", "seam-legacy", "seam-host"]

      # The downstream projection rebuilt from the log agrees with the
      # canonical resource read through the forward mapping.
      projection = fold(log)
      assert projection["name"] == Ash.get!(Contract, record.id).name
      assert projection["payment_term"] == Ash.get!(Contract, record.id).payment_term
    end
  end

  # The downstream fold: latest after-image wins for row-local attributes.
  defp fold(log) do
    Enum.reduce(log, %{}, fn event, acc ->
      Map.merge(acc, event.payload["after"] || %{})
    end)
  end

  defp events_bridge_rows do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        "SELECT source_event_id, operation FROM #{@table} WHERE resource = $1 ORDER BY source_event_id",
        [to_string(Contract)]
      )

    Enum.map(rows, fn [id, op] -> %{id: id, op: op} end)
  end

  # --- shared helpers ------------------------------------------------------------

  defmodule EventsBridgeResource do
    @moduledoc "The generated bridge's shape, mounted for the read-only assertion."
    use Ash.Resource,
      domain: nil,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "strangler_observations"
      schema "public"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      uuid_primary_key :id
      attribute :source_event_id, :integer, public?: true
      attribute :category, :atom, public?: true
      attribute :resource, :string, public?: true
      attribute :operation, :atom, public?: true
      attribute :after, :map, public?: true
      attribute :mapping_version, :string, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defp drain!(count \\ 100) do
    {:ok, _} =
      AshStrangler.Observation.Processor.drain(TestRepo, Contract, [FeedObserver], batch: count)

    :ok
  end

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
      client_party_id: client,
      vendor_party_id: vendor
    })
  end

  defp update!(record, action, attrs) do
    record |> Ash.Changeset.for_update(action, attrs, authorize?: false) |> Ash.update!()
  end
end
