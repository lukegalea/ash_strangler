# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.JoinTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.JoinTest.Legacy.Accounts
    resource AshStrangler.JoinTest.Legacy.Addresses
    resource AshStrangler.JoinTest.Legacy.Plans
  end
end

defmodule AshStrangler.JoinTest.Legacy.Plans do
  @moduledoc "Twin for the relation reached through a `belongs_to`."
  use Ash.Resource,
    domain: AshStrangler.JoinTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "plans"
    schema "joined_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :name, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.JoinTest.Legacy.Addresses do
  @moduledoc "Twin for the relation reached through a `has_one`."
  use Ash.Resource,
    domain: AshStrangler.JoinTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "addresses"
    schema "joined_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :account_id, :integer, allow_nil?: false
    attribute :city, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.JoinTest.Legacy.Accounts do
  @moduledoc """
  Twin for the primary relation, carrying the relationships the joins are
  discovered from.

  These three relationships replace what used to be typed as SQL:

      join "joined_legacy.addresses", as: "addr", on: "addr.account_id = accounts.id"
      join "joined_legacy.plans",     as: "plan", on: "plan.id = accounts.plan_id"

  Every part of that was an opportunity for the declaration to disagree with the
  schema, and nothing compared them. A relationship states the same fact in the
  vocabulary Ash already has, so the relation, the alias and the `on` condition
  are all *derived* — see `AshStrangler.Twin.joins_for/2`.

  `addresses` is declared alongside `address` deliberately. The legacy table
  really does permit several addresses per account, which is why the `has_one`
  the mapping reads through is a claim the data can violate — see the fan-out
  tests — and why a `has_many` is refused by name rather than measured later.
  """
  use Ash.Resource,
    domain: AshStrangler.JoinTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "joined_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :email, :string, allow_nil?: false
    attribute :plan_id, :integer
  end

  relationships do
    has_one :address, AshStrangler.JoinTest.Legacy.Addresses do
      source_attribute :id
      destination_attribute :account_id
    end

    has_many :addresses, AshStrangler.JoinTest.Legacy.Addresses do
      source_attribute :id
      destination_attribute :account_id
    end

    belongs_to :plan, AshStrangler.JoinTest.Legacy.Plans do
      source_attribute :plan_id
      destination_attribute :id
      define_attribute? false
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.JoinTest.Customer do
  @moduledoc """
  A resource that gathers columns the legacy schema scattered across three
  tables — the other direction from decomposition, and the one a properly
  designed model usually also needs.

  Nothing here declares a join. Each mapping names the relationship it reads
  through, and the `FROM` clause is folded out of those names.
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

    source AshStrangler.JoinTest.Legacy.Accounts do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :email, from: :email

      # The relationship path in the expression *is* the join declaration. There
      # is no `as:` to get wrong and no `on:` to drift from the schema.
      map :city,
        from: expr(address.city),
        read_only?: true,
        because: "Read through a relationship; write it through its own resource."

      map :plan_name,
        from: expr(plan.name),
        read_only?: true,
        because: "Read through a relationship; write it through its own resource."
    end
  end

  def namespace, do: @namespace
end

defmodule AshStrangler.JoinTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.JoinTest.Customer
  end
end

defmodule AshStrangler.JoinTest do
  @moduledoc """
  Gathering: several legacy relations composed into one resource.

  The counterpart to `AshStrangler.RemodellingTest`, which splits one wide table
  apart. A model taken top-down usually needs both moves — some legacy tables
  are too wide, and others hold one concept spread across several.

  ## Joins are discovered, not declared

  A join used to be an entity in the `strangler` block, carrying a relation name,
  an alias and an `on:` predicate written as raw SQL. Three restatements of facts
  the schema already knows, none of them checked against it, and one of them
  (`on:`) an arbitrary predicate — so a cross join, which multiplies every row by
  every row and is never what anybody meant, was expressible by omission.

  Now a mapping reads `expr(address.city)` and the reference carries its
  relationship path as data. `AshStrangler.Info.joins/1` folds those paths into
  the `FROM` clause. Two properties follow *structurally* rather than by
  convention, and each has its own test below, because both were previously
  matters of a default that could be overridden:

    * a join is always `LEFT`;
    * a `has_many` is refused.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.JoinTest.Customer
  alias AshStrangler.JoinTest.Legacy
  alias AshStrangler.Twin

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
      # The reason LEFT is the only join this DSL can express. Under an INNER
      # JOIN this account would simply not exist for the new application, and
      # nothing would say so -- the row count would just be lower than the legacy
      # app's.
      legacy_id = insert_account!("noaddress@example.com")

      customer = Ash.get!(Customer, derived(legacy_id))

      assert to_string(customer.email) == "noaddress@example.com"
      assert customer.city == nil
      assert customer.plan_name == nil
    end

    test "the FROM clause aliases the primary relation and joins each discovered path" do
      %{view: view} = AshStrangler.Sql.View.build(Customer)

      assert view.up =~ "FROM joined_legacy.accounts AS accounts"

      # The alias is the relationship name, and the `on` condition is built from
      # the relationship's own source and destination attributes.
      assert view.up =~
               ~s(LEFT JOIN joined_legacy.addresses AS address ON address.account_id = accounts.id)

      assert view.up =~ ~s(LEFT JOIN joined_legacy.plans AS plan ON plan.id = accounts.plan_id)

      # The key must qualify once a join makes a bare `id` ambiguous.
      assert view.up =~ "'joined_legacy.accounts:' || accounts.id::text"
    end

    test "a join is always LEFT, so a legacy row with no match cannot vanish" do
      # Structural, not a default. The old DSL let a join declare `type: :inner`
      # and argued that `:left` had to be the default; deriving the join from a
      # relationship removes the option, because a relationship describes which
      # rows *relate* and not which rows *survive*.
      #
      # This is worth its own test rather than a comment because the failure is
      # invisible: an INNER JOIN silently drops the unmatched rows, so the new
      # application reports fewer records than the old one and nothing raises.
      from_clause = AshStrangler.Sql.View.from_clause(Customer)

      assert from_clause =~ "LEFT JOIN"
      refute from_clause =~ "INNER JOIN"

      insert_account!("has@example.com", city: "London")
      insert_account!("hasnot@example.com")

      assert count("SELECT count(*) FROM #{AshStrangler.Info.relation(Customer)}") == 2

      assert count("SELECT count(*) FROM #{from_clause}") == 2,
             "an INNER JOIN here would return 1, and the account with no address would be gone"
    end
  end

  describe "the joins are read off the relationships" do
    test "each join carries the relation, the alias and the condition it derived" do
      joins = AshStrangler.Info.joins(Customer)

      assert Enum.find(joins, &(&1.alias == "address")) == %{
               relation: "joined_legacy.addresses",
               alias: "address",
               on: "address.account_id = accounts.id",
               relationship: Ash.Resource.Info.relationship(Legacy.Accounts, :address)
             }

      # Aliased by the relationship name. There is no `as:` option to collide with
      # a column called `addr_line1`, which is the false positive the deleted
      # substring-matching verifier was waiting for.
      assert Enum.sort(AshStrangler.Info.join_aliases(Customer)) == ["address", "plan"]
    end

    test "a has_many is refused by name, because joining it would multiply view rows" do
      # Refused from the declaration rather than measured from the data. One
      # legacy account with three addresses becomes three view rows, and therefore
      # three `Customer` records where the old application had one -- the fan-out
      # failure this whole package exists to refuse.
      assert {:error, message} = Twin.joins_for(Legacy.Accounts, [:addresses])

      assert message =~ "has_many"
      assert message =~ "multiply view rows"
      assert message =~ "through its own resource"
    end

    test "an unknown relationship names the two shapes that are resolvable" do
      assert {:error, message} = Twin.joins_for(Legacy.Accounts, [:nonexistent])

      assert message =~ "has no relationship :nonexistent"
      assert message =~ "belongs_to"
      assert message =~ "has_one"
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
    test "the joined view is not auto-updatable, so no column of it is free to write" do
      # Auto-updatability requires exactly one base relation, so PostgreSQL refuses
      # a joined view outright -- every column, including the plain references.
      # Measured rather than asserted: `0` is the whole bitmask, where `4` is
      # UPDATE and a plain base table reports `28`.
      #
      # Introspected with `pg_relation_is_updatable/2` rather than with
      # `information_schema.views.is_updatable`, which is *defined* to pass
      # `include_triggers = false` and therefore cannot tell "not updatable" from
      # "updatable only through an INSTEAD OF trigger". Both readings are 0 here
      # because this phase generates no triggers, which is the point: nothing has
      # made the view writable.
      assert updatable_bitmask(include_triggers: false) == 0
      assert updatable_bitmask(include_triggers: true) == 0
    end

    test "this resource's write path is the trigger path" do
      assert AshStrangler.Info.writes(Customer) == :triggers

      # Which mapping is paying, because the answer is not the one a reader
      # expects. `AshStrangler.Mechanism` classifies per *column*, and the column
      # that reaches `:instead_of` is `email` -- a derived `citext` cast is not a
      # simple reference, so it cannot ride the view's own updatability. The joined
      # columns cost nothing at all: they are read-only, so they are `:none`.
      #
      # `mix ash_strangler.check` prints exactly this table, and it is the answer
      # to the question a migration turns on: which mapping is costing me upserts,
      # and would anything cheaper do.
      assert AshStrangler.Mechanism.report(Customer) == [
               {:email, :base_trigger, :instead_of},
               {:city, :none, :none},
               {:plan_name, :none, :none}
             ]
    end

    test "every mapping that reads through a relationship is read-only" do
      # The invariant `VerifyJoinedWritesRefused` enforces, asserted on the
      # fixture so the two cannot drift apart: a write reaches the primary
      # relation through `__legacy_id`, and nothing identifies the corresponding
      # row in a joined one.
      joined =
        Customer
        |> AshStrangler.Lens.for_resource()
        |> Enum.filter(fn lens ->
          Enum.any?(lens.sources, fn {path, _attribute} -> path != [] end)
        end)

      assert length(joined) == 2

      for lens <- joined do
        assert lens.writes == []
        assert lens.read_only?
        assert lens.because =~ "its own resource"
      end
    end

    test "a mapping that reads a joined column and still writes is refused" do
      # A `collapse` is the shape that reaches this: its guards are expressions,
      # so one can read a joined column, while its `set:` writes columns of the
      # primary relation. The forward direction then depends on a row the backward
      # direction cannot restore.
      #
      # This test fails if `VerifyJoinedWritesRefused` is deleted: no other
      # verifier objects, because the mapping really does have a constructible
      # reverse -- it is just a reverse of the wrong table.
      resource =
        define("""
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :status, :atom, public?: true, constraints: [one_of: [:local, :remote]]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.JoinTest.Legacy.Accounts do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "#{Customer.namespace()}"}

            collapse :status do
              state :local, when: expr(address.city == "London"), set: [email: "london@example.com"]
              state :remote, when: :otherwise, set: [email: "elsewhere@example.com"]
            end
          end
        end
        """)

      assert {:error, error} =
               AshStrangler.Verifiers.VerifyJoinedWritesRefused.verify(
                 resource.spark_dsl_config()
               )

      message = Exception.message(error)
      assert message =~ ":status"
      assert message =~ "address.city"
      assert message =~ "__legacy_id"
      assert message =~ "its own resource"
    end
  end

  describe "fan-out detection" do
    test "a second row on the joined side fans out, though the twin declares has_one" do
      # The hazard no compile-time check can see, because it depends entirely on
      # the data. `has_one` is a claim about the legacy schema, and unless a unique
      # constraint backs it the legacy application can put two addresses on one
      # account -- at which point the view has two rows with the same primary key.
      # Perfectly valid SQL, and wrong.
      legacy_id = insert_account!("two@example.com", city: "London")

      TestRepo.query!(
        "INSERT INTO joined_legacy.addresses (account_id, city) VALUES ($1, 'Paris')",
        [legacy_id]
      )

      assert count("SELECT count(*) FROM joined.customers WHERE id = '#{derived(legacy_id)}'") ==
               2,
             "expected the join to fan out, which is the point of the check"
    end

    test "mix ash_strangler.check reports it by comparing row counts" do
      # Exactly what the task measures: rows through the view against rows in
      # the primary relation.
      insert_account!("a@example.com", city: "London")
      insert_account!("b@example.com", city: "Berlin")
      legacy_id = insert_account!("c@example.com", city: "Rome")

      TestRepo.query!(
        "INSERT INTO joined_legacy.addresses (account_id, city) VALUES ($1, 'Milan')",
        [legacy_id]
      )

      base = count("SELECT count(*) FROM #{AshStrangler.Info.relation(Customer)}")
      joined = count("SELECT count(*) FROM #{AshStrangler.Sql.View.from_clause(Customer)}")

      assert base == 3
      assert joined == 4
      assert joined > base, "the check keys off exactly this comparison"
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

          source AshStrangler.JoinTest.Legacy.Accounts do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "#{Customer.namespace()}"}

            unmapped [:legacy_id], as: :null, because: "Carried by the backfill."

            map :city,
              from: expr(address.city),
              read_only?: true,
              because: "Read through a relationship."
          end
        end
        """)

      assert {:error, error} =
               AshStrangler.Verifiers.VerifyReverseMappable.verify(resource.spark_dsl_config())

      assert Exception.message(error) =~ "scattering one table back across several"
    end
  end

  defp count(sql) do
    %Postgrex.Result{rows: [[count]]} = TestRepo.query!(sql, [])
    count
  end

  defp updatable_bitmask(include_triggers: include_triggers) do
    count("SELECT pg_relation_is_updatable('joined.customers'::regclass, #{include_triggers})")
  end

  defp define(body) do
    name = "JoinProbe#{System.unique_integer([:positive])}"

    # The definition itself succeeds even for a mapping a verifier will refuse:
    # Spark verifiers run after compilation, in `Module.ParallelChecker`, and
    # report through a compiler warning rather than by raising. Capturing keeps
    # that noise out of the test output; the assertion is made by calling the
    # verifier directly.
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
