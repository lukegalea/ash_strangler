# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.JoinTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.JoinTest.Customer
  end
end

defmodule AshStrangler.JoinTest.Customer do
  @moduledoc """
  A resource that gathers columns the legacy schema scattered across three
  tables — the other direction from decomposition, and the one a properly
  designed model usually also needs.
  """
  use Ash.Resource,
    domain: AshStrangler.JoinTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  postgres do
    table "customers"
    schema "joined"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :city, :string, public?: true
    attribute :plan_name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source "joined_legacy.accounts" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: @namespace}

      # LEFT by default: an account with no address must not vanish from the
      # view, which an INNER JOIN would do silently.
      join("joined_legacy.addresses", as: "addr", on: "addr.account_id = accounts.id")
      join("joined_legacy.plans", as: "plan", on: "plan.id = accounts.plan_id")

      map :email, "email", cast: :citext

      map :city, "addr.city" do
        writable? false
        because "Read from a joined relation; write it through its own resource."
      end

      map :plan_name, "plan.name" do
        writable? false
        because "Read from a joined relation; write it through its own resource."
      end
    end
  end

  def namespace, do: @namespace
end

defmodule AshStrangler.JoinTest do
  @moduledoc """
  Gathering: several legacy relations composed into one resource.

  The counterpart to `AshStrangler.RemodellingTest`, which splits one wide table
  apart. A model taken top-down usually needs both moves — some legacy tables
  are too wide, and others hold one concept spread across several.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.JoinTest.Customer

  setup do
    TestRepo.query!("DROP SCHEMA IF EXISTS joined CASCADE", [])
    TestRepo.query!("DROP SCHEMA IF EXISTS joined_legacy CASCADE", [])
    TestRepo.query!("CREATE SCHEMA joined", [])
    TestRepo.query!("CREATE SCHEMA joined_legacy", [])

    TestRepo.query!(
      "CREATE TABLE joined_legacy.plans (id bigserial PRIMARY KEY, name text)",
      []
    )

    TestRepo.query!(
      """
      CREATE TABLE joined_legacy.accounts (
        id bigserial PRIMARY KEY,
        email text NOT NULL,
        plan_id bigint REFERENCES joined_legacy.plans(id)
      )
      """,
      []
    )

    TestRepo.query!(
      """
      CREATE TABLE joined_legacy.addresses (
        id bigserial PRIMARY KEY,
        account_id bigint NOT NULL REFERENCES joined_legacy.accounts(id),
        city text
      )
      """,
      []
    )

    for statement <- AshStrangler.Migration.statements(Customer) do
      TestRepo.query!(statement.up, [])
    end

    :ok
  end

  defp insert_account!(email, opts \\ []) do
    plan_id =
      case opts[:plan] do
        nil ->
          nil

        name ->
          %Postgrex.Result{rows: [[id]]} =
            TestRepo.query!("INSERT INTO joined_legacy.plans (name) VALUES ($1) RETURNING id", [
              name
            ])

          id
      end

    %Postgrex.Result{rows: [[account_id]]} =
      TestRepo.query!(
        "INSERT INTO joined_legacy.accounts (email, plan_id) VALUES ($1, $2) RETURNING id",
        [email, plan_id]
      )

    if city = opts[:city] do
      TestRepo.query!(
        "INSERT INTO joined_legacy.addresses (account_id, city) VALUES ($1, $2)",
        [account_id, city]
      )
    end

    account_id
  end

  defp derived(legacy_id) do
    AshStrangler.KeyDerivation.uuid_v5(
      Customer.namespace(),
      AshStrangler.KeyDerivation.name("joined_legacy.accounts", legacy_id)
    )
  end

  describe "gathering several relations into one resource" do
    test "columns from every joined relation arrive on the resource" do
      legacy_id = insert_account!("ada@example.com", city: "London", plan: "Enterprise")

      customer = Ash.get!(Customer, derived(legacy_id))

      assert to_string(customer.email) == "ada@example.com"
      assert customer.city == "London"
      assert customer.plan_name == "Enterprise"
    end

    test "a row with no match on the joined side survives, with nulls" do
      # The reason LEFT is the default. Under an INNER JOIN this account would
      # simply not exist for the new application, and nothing would say so --
      # the row count would just be lower than the legacy app's.
      legacy_id = insert_account!("noaddress@example.com")

      customer = Ash.get!(Customer, derived(legacy_id))

      assert to_string(customer.email) == "noaddress@example.com"
      assert customer.city == nil
      assert customer.plan_name == nil
    end

    test "the generated SQL joins with LEFT JOIN and aliases the primary relation" do
      %{view: view} = AshStrangler.Sql.View.build(Customer)

      assert view.up =~ "FROM joined_legacy.accounts AS accounts"

      assert view.up =~
               ~s(LEFT JOIN joined_legacy.addresses AS addr ON addr.account_id = accounts.id)

      assert view.up =~ ~s(LEFT JOIN joined_legacy.plans AS plan ON plan.id = accounts.plan_id)

      # The key must qualify once a join makes a bare `id` ambiguous.
      assert view.up =~ "'joined_legacy.accounts:' || accounts.id::text"
    end
  end

  describe "the expression index still applies" do
    test "the index exists on the base table" do
      %Postgrex.Result{rows: rows} =
        TestRepo.query!(
          "SELECT indexdef FROM pg_indexes WHERE schemaname = 'joined_legacy' AND indexname = $1",
          ["strangler_customers_key_idx"]
        )

      assert [[indexdef]] = rows
      assert indexdef =~ "uuid_generate_v5"
    end

    test "a lookup by derived id can use it, despite the view qualifying the column" do
      # The index is created on the base table with an UNqualified expression
      # while the view qualifies it by the alias. Postgres resolves the alias at
      # parse time so both reference the same column -- but "should match" and
      # "does match" are different claims, and a mismatch degrades silently to a
      # sequential scan at production volumes.
      #
      # `enable_seqscan = off` because a 200-row table is genuinely cheaper to
      # scan and the planner is right to; the question here is whether the index
      # is USABLE at all, not whether it is chosen at toy sizes.
      for n <- 1..200, do: insert_account!("bulk#{n}@example.com")
      TestRepo.query!("ANALYZE joined_legacy.accounts", [])

      target = insert_account!("needle@example.com")

      TestRepo.query!("SET LOCAL enable_seqscan = off", [])

      %Postgrex.Result{rows: rows} =
        TestRepo.query!(
          "EXPLAIN SELECT * FROM joined.customers WHERE id = $1",
          [Ecto.UUID.dump!(derived(target))]
        )

      plan = rows |> List.flatten() |> Enum.join("\n")

      assert plan =~ "strangler_customers_key_idx",
             "expected the expression index to be usable, got:\n#{plan}"
    end
  end

  describe "writability" do
    test "a join forces the trigger path, because the view is not auto-updatable" do
      # Auto-updatability requires exactly one base table. With a join there is
      # no free write path, so triggers are the only option and the derivation
      # has to know that.
      assert AshStrangler.Info.writes(Customer) == :triggers
    end

    test "a writable mapping onto a joined relation is refused" do
      resource =
        define("""
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :city, :string, public?: true
        end

        strangler do
          phase :read_from_legacy

          source "joined_legacy.accounts" do
            key :id, from: "id", strategy: {:uuid_v5, namespace: "#{Customer.namespace()}"}
            join "joined_legacy.addresses", as: "addr", on: "addr.account_id = accounts.id"
            map :city, "addr.city"
          end
        end
        """)

      assert {:error, error} =
               AshStrangler.Verifiers.VerifyJoinedMappingsReadOnly.verify(
                 resource.spark_dsl_config()
               )

      message = Exception.message(error)
      assert message =~ ":city"
      assert message =~ "__legacy_id"
      assert message =~ "its own resource"
    end
  end

  describe "fan-out detection" do
    test "a one-to-many join makes the view return duplicates for one primary key" do
      # The hazard no compile-time check can see, because it depends entirely on
      # the data. Two addresses for one account and the view has two rows with
      # the same primary key -- perfectly valid SQL, and wrong.
      legacy_id = insert_account!("two@example.com", city: "London")

      TestRepo.query!(
        "INSERT INTO joined_legacy.addresses (account_id, city) VALUES ($1, 'Paris')",
        [legacy_id]
      )

      %Postgrex.Result{rows: [[count]]} =
        TestRepo.query!("SELECT count(*) FROM joined.customers WHERE id = $1", [
          Ecto.UUID.dump!(derived(legacy_id))
        ])

      assert count == 2, "expected the join to fan out, which is the point of the check"
    end

    test "mix ash_strangler.check reports it by comparing row counts" do
      # Exactly what the task measures: rows through the view against rows in
      # the primary relation.
      insert_account!("a@example.com", city: "London")
      insert_account!("b@example.com", city: "Berlin")
      [legacy_id] = [insert_account!("c@example.com", city: "Rome")]

      TestRepo.query!(
        "INSERT INTO joined_legacy.addresses (account_id, city) VALUES ($1, 'Milan')",
        [legacy_id]
      )

      source = AshStrangler.Info.source(Customer)

      %Postgrex.Result{rows: [[base]]} =
        TestRepo.query!("SELECT count(*) FROM #{source.relation}", [])

      %Postgrex.Result{rows: [[joined]]} =
        TestRepo.query!("SELECT count(*) FROM #{AshStrangler.Sql.View.from_clause(source)}", [])

      assert base == 3
      assert joined == 4
      assert joined > base, "the check keys off exactly this comparison"
    end

    test "an inner join loses rows, which the same comparison catches in reverse" do
      resource = inner_join_resource()

      for statement <- AshStrangler.Migration.statements(resource) do
        TestRepo.query!(statement.up, [])
      end

      insert_account!("has@example.com", city: "London")
      insert_account!("hasnot@example.com")

      source = AshStrangler.Info.source(resource)

      %Postgrex.Result{rows: [[base]]} =
        TestRepo.query!("SELECT count(*) FROM #{source.relation}", [])

      %Postgrex.Result{rows: [[joined]]} =
        TestRepo.query!("SELECT count(*) FROM #{AshStrangler.Sql.View.from_clause(source)}", [])

      assert base == 2
      assert joined == 1, "the INNER JOIN drops the account with no address"
    end
  end

  describe ":read_from_new" do
    test "is refused while the source still gathers joined relations" do
      # Reversing a gather means scattering one table back across several, and
      # the mapping never said which column belongs where on the way back.
      resource =
        define("""
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :legacy_id, :integer, public?: true
          attribute :city, :string, public?: true
        end

        strangler do
          phase :read_from_new

          source "joined_legacy.accounts" do
            key :id, from: "id", strategy: {:uuid_v5, namespace: "#{Customer.namespace()}"}
            join "joined_legacy.addresses", as: "addr", on: "addr.account_id = accounts.id"

            unmapped [:legacy_id], as: :null, because: "Carried by the backfill."

            map :city, "addr.city" do
              writable? false
              because "Joined relation."
            end
          end
        end
        """)

      assert {:error, error} =
               AshStrangler.Verifiers.VerifyReverseMappable.verify(resource.spark_dsl_config())

      assert Exception.message(error) =~ "scattering one table back across several"
    end
  end

  defp inner_join_resource do
    define("""
    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
      attribute :city, :string, public?: true
    end

    strangler do
      phase :read_from_legacy

      source "joined_legacy.accounts" do
        key :id, from: "id", strategy: {:uuid_v5, namespace: "#{Customer.namespace()}"}

        join "joined_legacy.addresses",
          as: "addr",
          on: "addr.account_id = accounts.id",
          type: :inner

        map :city, "addr.city" do
          writable? false
          because "Joined relation."
        end
      end
    end
    """)
  end

  defp define(body) do
    name = "JoinProbe#{System.unique_integer([:positive])}"

    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string("""
        defmodule #{name} do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshStrangler.Resource]

          postgres do
            table "probe"
            schema "joined"
            repo AshStrangler.TestRepo
            migrate? false
          end

          actions do
            defaults [:read]
          end

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module
  end
end
