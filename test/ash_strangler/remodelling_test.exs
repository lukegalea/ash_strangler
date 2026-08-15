# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.RemodellingTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.RemodellingTest.Customer
    resource AshStrangler.RemodellingTest.Organization
  end
end

defmodule AshStrangler.RemodellingTest.Customer do
  @moduledoc """
  The person, plus a lifecycle collapsed out of four legacy columns.
  """
  use Ash.Resource,
    domain: AshStrangler.RemodellingTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "customers"
    schema "remodel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :full_name, :string, public?: true
    attribute :status, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "remodel_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :email, "email", cast: :citext

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable back into first and last names."
      end

      # Four legacy columns, one lifecycle. Ordered most-terminal first so the
      # projection stays a total function even when the legacy row contradicts
      # itself -- which it can, because nothing ever stopped it.
      map :status do
        from """
        CASE
          WHEN is_deleted THEN 'archived'
          WHEN cancelled_at IS NOT NULL THEN 'cancelled'
          WHEN approved_at IS NOT NULL THEN 'active'
          ELSE 'pending'
        END
        """

        writable? false

        because "Four legacy columns with no single inverse. Supply `to:`/`into:` before enabling dual-write."
      end
    end
  end
end

defmodule AshStrangler.RemodellingTest.Organization do
  @moduledoc """
  The employer, from the very same rows -- a separate resource with a separate
  view, sharing nothing but the legacy table underneath.
  """
  use Ash.Resource,
    domain: AshStrangler.RemodellingTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "organizations"
    schema "remodel"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
    attribute :vat_number, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "remodel_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :name, "company_name"
      map :vat_number, "company_vat"
    end
  end
end

defmodule AshStrangler.RemodellingTest do
  @moduledoc """
  The reason most people reach for this: not renaming a column, but adopting a
  schema that was designed properly.

  Two moves carry almost all of that, and both are exercised here against a
  deliberately awful legacy table:

    * **Decomposition.** One wide table becomes several well-modelled resources,
      each its own view over the same rows. A legacy `accounts` table that mixes
      a person, their employer and their address becomes `Customer`,
      `Organization` and `Address`.

    * **Collapsing scattered state into one lifecycle.** Four booleans and
      timestamps that encode a state machine badly become a single `status`
      attribute that `ash_state_machine` can then govern.

  Both work today, and this file exists so the README can say so without
  anybody having to take it on faith.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.RemodellingTest.Customer
  alias AshStrangler.RemodellingTest.Organization

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  setup do
    TestRepo.query!("DROP SCHEMA IF EXISTS remodel CASCADE", [])
    TestRepo.query!("DROP SCHEMA IF EXISTS remodel_legacy CASCADE", [])
    TestRepo.query!("CREATE SCHEMA remodel", [])
    TestRepo.query!("CREATE SCHEMA remodel_legacy", [])

    # The kind of table fifteen years produces: a person, their employer and
    # their address in one row, with the lifecycle spread across four columns
    # that can contradict each other.
    TestRepo.query!(
      """
      CREATE TABLE remodel_legacy.accounts (
        id            bigserial PRIMARY KEY,
        email         text NOT NULL,
        first_name    text,
        last_name     text,
        company_name  text,
        company_vat   text,
        addr_line1    text,
        addr_city     text,
        is_active     boolean NOT NULL DEFAULT true,
        is_deleted    boolean NOT NULL DEFAULT false,
        approved_at   timestamp,
        cancelled_at  timestamp
      )
      """,
      []
    )

    :ok
  end

  describe "decomposition: one legacy table becomes several resources" do
    test "each resource is its own view over the same rows, with its own shape" do
      for resource <- [Customer, Organization],
          statement <- AshStrangler.Migration.statements(resource) do
        TestRepo.query!(statement.up, [])
      end

      %Postgrex.Result{rows: [[legacy_id]]} =
        TestRepo.query!(
          """
          INSERT INTO remodel_legacy.accounts
            (email, first_name, last_name, company_name, company_vat, addr_city, approved_at)
          VALUES ('a@example.com', 'Ada', 'Lovelace', 'Analytical Ltd', 'GB123', 'London', now())
          RETURNING id
          """,
          []
        )

      # The same row, read two ways -- neither view exposing the other's columns.
      person = Ash.get!(Customer, derived(legacy_id))
      employer = Ash.get!(Organization, derived(legacy_id))

      assert person.full_name == "Ada Lovelace"
      assert to_string(person.email) == "a@example.com"
      refute Map.has_key?(person, :vat_number)

      assert employer.name == "Analytical Ltd"
      assert employer.vat_number == "GB123"
      refute Map.has_key?(employer, :full_name)
    end
  end

  describe "collapsing scattered state into one lifecycle" do
    setup do
      for statement <- AshStrangler.Migration.statements(Customer) do
        TestRepo.query!(statement.up, [])
      end

      :ok
    end

    test "four legacy columns project to one status value" do
      cases = [
        # {is_active, is_deleted, approved_at, cancelled_at} => status
        {[true, false, nil, nil], "pending"},
        {[true, false, ~N[2024-01-01 00:00:00], nil], "active"},
        {[false, false, ~N[2024-01-01 00:00:00], ~N[2024-02-01 00:00:00]], "cancelled"},
        {[true, true, ~N[2024-01-01 00:00:00], nil], "archived"}
      ]

      for {[active, deleted, approved, cancelled], expected} <- cases do
        %Postgrex.Result{rows: [[legacy_id]]} =
          TestRepo.query!(
            """
            INSERT INTO remodel_legacy.accounts
              (email, is_active, is_deleted, approved_at, cancelled_at)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id
            """,
            [
              "s#{System.unique_integer([:positive])}@example.com",
              active,
              deleted,
              approved,
              cancelled
            ]
          )

        record = Ash.get!(Customer, derived(legacy_id))

        assert record.status == expected,
               "expected #{inspect(expected)} for active=#{active} deleted=#{deleted} " <>
                 "approved=#{inspect(approved)} cancelled=#{inspect(cancelled)}, " <>
                 "got #{inspect(record.status)}"
      end
    end

    test "the precedence is total, so contradictory legacy rows still resolve" do
      # The whole reason the old shape is bad: these four columns can disagree.
      # `is_deleted` AND `cancelled_at` AND still `is_active` is nonsense the
      # legacy app can produce, and the projection has to be a total function
      # over it rather than returning NULL and pushing the problem downstream.
      %Postgrex.Result{rows: [[legacy_id]]} =
        TestRepo.query!(
          """
          INSERT INTO remodel_legacy.accounts
            (email, is_active, is_deleted, approved_at, cancelled_at)
          VALUES ('contradiction@example.com', true, true, now(), now())
          RETURNING id
          """,
          []
        )

      assert Ash.get!(Customer, derived(legacy_id)).status == "archived"
    end
  end

  defp derived(legacy_id) do
    AshStrangler.KeyDerivation.uuid_v5(
      @namespace,
      AshStrangler.KeyDerivation.name("remodel_legacy.accounts", legacy_id)
    )
  end
end
