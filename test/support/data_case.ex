# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.DataCase do
  @moduledoc """
  Case template for tests that talk to a real PostgreSQL server.

  The plan is explicit that this suite does not mock the database: the whole
  value of the package is that the SQL it generates behaves the way it claims
  to, and a mock would assert the generator agrees with itself.

  The fixture schema and the generated view are installed once in
  `test_helper.exs`, before the sandbox goes into `:manual` mode, so tests
  inherit them and only insert and read inside a transaction that rolls back.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshStrangler.DataCase
      import Ecto.Query

      alias AshStrangler.Test.LegacySchema
      alias AshStrangler.Test.LegacyUser
      alias AshStrangler.TestRepo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshStrangler.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Inserts a row into `legacy.users` with raw SQL and returns its legacy id.

  Raw SQL on purpose: the point of a round-trip test is that a row written by
  the *legacy application*, through a path this package never touches, projects
  correctly. Writing it through Ash would test the wrong direction.
  """
  def insert_legacy_user!(attrs \\ %{}) do
    attrs = Map.new(attrs)
    login = Map.get_lazy(attrs, :login, fn -> "user-#{System.unique_integer([:positive])}" end)

    %Postgrex.Result{rows: [[legacy_id]]} =
      AshStrangler.TestRepo.query!(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, deleted_at, state)
        VALUES ($1, $2, $3, $4, $5, coalesce($6, 'active'))
        RETURNING id
        """,
        [
          login,
          Map.get(attrs, :email),
          Map.get(attrs, :first_name),
          Map.get(attrs, :last_name),
          Map.get(attrs, :deleted_at),
          Map.get(attrs, :state)
        ]
      )

    legacy_id
  end

  @doc """
  Inserts a party into `legacy.clm_parties` with raw SQL and returns its id.
  """
  def insert_legacy_party!(attrs \\ %{}) do
    attrs = Map.new(attrs)
    id = Map.get_lazy(attrs, :id, fn -> Ash.UUID.generate() end)
    name = Map.get_lazy(attrs, :name, fn -> "party-#{System.unique_integer([:positive])}" end)

    %Postgrex.Result{rows: [[raw_id]]} =
      AshStrangler.TestRepo.query!(
        """
        INSERT INTO legacy.clm_parties (id, name, organization_id)
        VALUES ($1, $2, $3)
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(id),
          name,
          Ecto.UUID.dump!(Map.fetch!(attrs, :organization_id))
        ]
      )

    {:ok, ^id} = Ecto.UUID.load(raw_id)
    id
  end

  @doc """
  Inserts a contract into `legacy.clm_contracts` with raw SQL and returns its
  id. Raw SQL on purpose — the read-through test needs a row the legacy
  application wrote, through a path this package never touches.
  """
  def insert_legacy_contract!(attrs \\ %{}) do
    attrs = Map.new(attrs)

    id = Map.get_lazy(attrs, :id, fn -> Ash.UUID.generate() end)

    client_party_id = Map.fetch!(attrs, :client_party_id)
    vendor_party_id = Map.get(attrs, :vendor_party_id)

    %Postgrex.Result{rows: [[raw_id]]} =
      AshStrangler.TestRepo.query!(
        """
        INSERT INTO legacy.clm_contracts
          (id, name, description, value, payment_term, client_party_id, service_provider_party_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(id),
          Map.get_lazy(attrs, :name, fn -> "contract-#{System.unique_integer([:positive])}" end),
          Map.get(attrs, :description),
          Map.get(attrs, :value),
          Map.get(attrs, :payment_term),
          Ecto.UUID.dump!(client_party_id),
          if(vendor_party_id, do: Ecto.UUID.dump!(vendor_party_id), else: nil)
        ]
      )

    {:ok, ^id} = Ecto.UUID.load(raw_id)
    id
  end

  @doc """
  Every value the legacy `state` column actually ranges over.

  This list is the whole reason the round-trip property is worth running.
  Generating over `state_code`'s *modern* value space only ever produces rows
  this package created; the legacy space is the one holding rows the old
  application wrote over fifteen years, and it is the space a mapping has to be
  a bijection on.
  """
  def legacy_states, do: ~w(passive pending active suspended deleted)

  @doc "Reads a legacy row back through the generated view, as an Ash record."
  def read_through_view!(legacy_id) do
    Ash.get!(AshStrangler.Test.LegacyUser, derived_id(legacy_id))
  end

  @doc """
  The modern id for a legacy id, computed **in Elixir**.

  Deliberately not read out of the database: a test that asked Postgres for the
  id and then compared it against Postgres would be a tautology. This is the
  independent side of the SQL/Elixir agreement property.
  """
  def derived_id(legacy_id) do
    AshStrangler.KeyDerivation.uuid_v5(
      AshStrangler.Test.LegacyUser.namespace(),
      AshStrangler.KeyDerivation.name("legacy.users", legacy_id)
    )
  end
end
