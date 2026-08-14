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
        INSERT INTO legacy.users (login, email, first_name, last_name, deleted_at)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id
        """,
        [
          login,
          Map.get(attrs, :email),
          Map.get(attrs, :first_name),
          Map.get(attrs, :last_name),
          Map.get(attrs, :deleted_at)
        ]
      )

    legacy_id
  end

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
