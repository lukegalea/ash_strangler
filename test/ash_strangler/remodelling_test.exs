# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.RemodellingTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.RemodellingTest.Legacy.Accounts
  end
end

defmodule AshStrangler.RemodellingTest.Legacy.Accounts do
  @moduledoc """
  The twin for the deliberately awful legacy table these tests remodel.

  Declaring it once is what lets both resources below map *typed* columns instead
  of repeating `source "remodel_legacy.accounts"` and naming columns in strings.
  It is also what makes the `collapse` guards mean something: `expr(is_deleted)`
  resolves to a `:boolean` attribute here, and `expr(not is_nil(cancelled_at))`
  to a `:naive_datetime` one, so `AshStrangler.Obligations` can enumerate the
  guard lattice rather than guess at a SQL string.

  `is_active` is declared and never read by any mapping, which is deliberate:
  four columns encode the lifecycle badly and only three of them carry
  information the model wants.
  """

  use Ash.Resource,
    domain: AshStrangler.RemodellingTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "remodel_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :email, :string, allow_nil?: false
    attribute :first_name, :string
    attribute :last_name, :string
    attribute :company_name, :string
    attribute :company_vat, :string
    attribute :addr_line1, :string
    attribute :addr_city, :string
    attribute :is_active, :boolean, allow_nil?: false
    attribute :is_deleted, :boolean, allow_nil?: false
    attribute :approved_at, :naive_datetime
    attribute :cancelled_at, :naive_datetime
  end

  actions do
    defaults [:read]
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

    # An atom with a declared value set, which is what makes the collapse's
    # surjectivity obligation decidable: a state the attribute permits but no
    # clause can produce is a clause somebody meant to write.
    attribute :status, :atom do
      public? true
      constraints one_of: [:pending, :active, :cancelled, :archived]
    end
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.RemodellingTest.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      # The cast to `citext` is derived from the twin's `:string` against this
      # resource's `:ci_string`. Nothing types it.
      map :email, from: :email

      # `split_part` is the reverse of a `concat`, and it is correct only while
      # the separator is absent from every operand -- which `'de la Cruz'`
      # violates. So the honest declaration is read-only, and
      # `AshStrangler.Obligations` still emits the separator-absence query for
      # `mix ash_strangler.check` to measure rather than assuming either way.
      concat :full_name,
        from: [:first_name, :last_name],
        separator: " ",
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no separator fixes it."

      # Four legacy columns, one lifecycle, and both directions from one block.
      # Most-terminal clause first, so the projection is a total function over
      # rows the old application was never stopped from writing -- and
      # `:otherwise` is what makes that a guarantee rather than a hope.
      collapse :status do
        hit_policy :first

        state :archived,
          when: expr(is_deleted),
          set: [is_deleted: true, cancelled_at: nil, approved_at: nil]

        state :cancelled,
          when: expr(not is_nil(cancelled_at)),
          set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]

        state :active,
          when: expr(not is_nil(approved_at)),
          set: [is_deleted: false, cancelled_at: nil, approved_at: touch()]

        state :pending,
          when: :otherwise,
          set: [is_deleted: false, cancelled_at: nil, approved_at: nil]
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

    source AshStrangler.RemodellingTest.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :name, from: :company_name
      map :vat_number, from: :company_vat
    end
  end
end

defmodule AshStrangler.RemodellingTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.RemodellingTest.Customer
    resource AshStrangler.RemodellingTest.Organization
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
      a person and their employer becomes `Customer` and `Organization`.

    * **Collapsing scattered state into one lifecycle.** Four booleans and
      timestamps that encode a state machine badly become a single `status`
      attribute that `ash_state_machine` can then govern.

  Both work today, and this file exists so the README can say so without
  anybody having to take it on faith.

  ## The second move is the one that needs a mechanism of its own

  `status` is the shape a SQL string cannot carry. Written as an irreversible
  `CASE` it has no inverse at all, and the honest `because:` for it said as much:
  *"Four legacy columns with no single inverse. Supply `to:`/`into:` before
  enabling dual-write."* That is an invitation to hand-write a second SQL string
  nothing will ever compare to the first, which is precisely how a wrong inverse
  came to rewrite three of five lifecycle states in this package's own fixtures.

  `collapse` states both directions per clause. Because each clause's `set:`
  names **every** legacy column the table touches, the backward direction is
  total and canonical by construction -- there is no "which of the four do I
  write" question left to get wrong -- and the guards are expressions over typed
  twin columns, so completeness and reachability are decided at compile time.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Lens
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
        {[true, false, nil, nil], :pending},
        {[true, false, ~N[2024-01-01 00:00:00], nil], :active},
        {[false, false, ~N[2024-01-01 00:00:00], ~N[2024-02-01 00:00:00]], :cancelled},
        {[true, true, ~N[2024-01-01 00:00:00], nil], :archived}
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

      assert Ash.get!(Customer, derived(legacy_id)).status == :archived
    end

    test "the totality is `:otherwise`, not luck -- dropping it leaves rows projecting NULL" do
      # Stated as a test because it is the guarantee the whole clause exists for.
      # A row that is neither deleted, cancelled nor approved matches no *guard*;
      # what makes `status` a value rather than a NULL is the fallback clause, and
      # `AshStrangler.Obligations` refuses a table without one unless the guards
      # cover the lattice.
      lens = Lens.by_attribute(Customer)[:status]

      assert Enum.any?(lens.entry.states, &(&1.when == :otherwise))
      assert List.last(lens.entry.states).when == :otherwise
    end

    test "the inverse is derived, and names every legacy column the table touches" do
      # The property that removes the "which of the four do I write" question, and
      # therefore the property that removes the bug. `writes` is built from the
      # clauses' `set:` lists rather than from a second hand-written SQL string, so
      # the two directions cannot disagree.
      lens = Lens.by_attribute(Customer)[:status]

      assert Enum.sort(Enum.map(lens.writes, fn {column, _expression} -> column end)) ==
               [:approved_at, :cancelled_at, :is_deleted]

      # `touch()` is the one declared loss: round-tripping `:cancelled` cannot
      # recover the instant it was cancelled at, so the table reverses modulo it.
      assert lens.invertible == :semi
    end
  end

  defp derived(legacy_id) do
    AshStrangler.KeyDerivation.uuid_v5(
      @namespace,
      AshStrangler.KeyDerivation.name("remodel_legacy.accounts", legacy_id)
    )
  end
end
