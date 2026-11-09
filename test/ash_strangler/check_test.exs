# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.CheckTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckTest.Measured
  end
end

defmodule AshStrangler.CheckTest.Measured do
  @moduledoc """
  A resource built entirely out of the mappings whose correctness is a fact about
  the **data** rather than about the schema.

  Every fixture in `test/support` is deliberately clean, which is right for the
  round-trip properties and useless here: `mix ash_strangler.check` exists to
  report what the compiler could not decide, and a mapping the compiler decided
  gives it nothing to report. So each mapping below is one the obligations
  explicitly cannot close:

    * `login` is a `:ci_string` over a `text` column, so the derived cast makes the
      forward expression `(login)::citext` — and the uniqueness Ash believes in is
      therefore case-insensitive while `legacy.users`'s unique index is not.
      `'Duplicate'` and `'duplicate'` both satisfy Postgres and violate the
      identity, which is the case a check grouping by the raw column would miss.
    * `email` is a `coalesce`, whose reverse is `NULLIF` — an isomorphism only
      while the default is not otherwise a legal stored value. That is the
      relational-lens side condition `{A = a} ∈ P[A]`, and nothing in the schema
      answers it.
    * `full_name` is a `concat`, whose reverse is `split_part` — correct only while
      the separator is absent from every operand. `'de la'` is a first name that
      breaks it and no separator fixes it.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.CheckTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "measured_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :ci_string, allow_nil?: false, public?: true
    attribute :email, :string, public?: true
    attribute :full_name, :string, public?: true
  end

  identities do
    identity :unique_login, [:login]
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      coalesce :email, from: :email, default: "none@example.com"
      concat :full_name, from: [:first_name, :last_name], separator: " "
    end
  end
end

defmodule AshStrangler.CheckTest.DownRepo do
  @moduledoc """
  A repo pointed at a port nothing listens on, so a check against it meets a
  `DBConnection.ConnectionError` the way a run with the database down does. The
  pool settings are short so the test does not wait out a default queue.
  """

  use AshPostgres.Repo,
    otp_app: :ash_strangler,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["citext"]
end

defmodule AshStrangler.CheckTest.DownTwin do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.CheckTest.DownDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "down_items"
    schema "legacy"
    repo AshStrangler.CheckTest.DownRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :note, :string, public?: true
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CheckTest.DownDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckTest.DownTwin
    resource AshStrangler.CheckTest.Down
  end
end

defmodule AshStrangler.CheckTest.Down do
  @moduledoc """
  Three mapped attributes over a twin whose database cannot be reached, so a
  per-attribute report would show up as three lines.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a72"

  use Ash.Resource,
    domain: AshStrangler.CheckTest.DownDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "down_items"
    schema "strangler"
    repo AshStrangler.CheckTest.DownRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
    attribute :note, :string, public?: true
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.CheckTest.DownTwin do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :name, from: :name
      map :note, from: :note
      map :label, from: :label
    end
  end
end

defmodule AshStrangler.CheckTest.Unmapped do
  @moduledoc """
  A required attribute held by an extension store rather than by a mapping over
  the legacy columns: the check has no legacy expression to count NULLs over, and
  says so with a warning rather than a verdict.

  Shares `ExtendedUser`'s table name so the extension table the suite already
  installed is the one it joins.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a73"

  use Ash.Resource,
    domain: AshStrangler.CheckTest.UnmappedDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "extended_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :notes, :string, public?: true, default: ""
    attribute :risk_score, :integer, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      extension([:notes, :risk_score])
    end
  end
end

defmodule AshStrangler.CheckTest.UnmappedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckTest.Unmapped
  end
end

defmodule AshStrangler.CheckTest.UnmappedIdentity do
  @moduledoc """
  An identity whose only key is held by an extension store, so the duplicate check
  has nothing to group by. The extension attribute is nullable, which keeps the
  other warning about a required attribute out of it.

  `VerifyIdentitiesBacked` reports this as a compile-time error, which this suite
  sees as a warning when the file loads. No identity it accepts can reach the
  branch this is here for, so the warning is the cost of testing that branch.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a74"

  use Ash.Resource,
    domain: AshStrangler.CheckTest.UnmappedIdentityDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "extended_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :notes, :string, public?: true, default: ""
  end

  identities do
    identity :unique_notes, [:notes]
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      extension([:notes])
    end
  end
end

defmodule AshStrangler.CheckTest.UnmappedIdentityDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckTest.UnmappedIdentity
  end
end

defmodule AshStrangler.CheckTest.ScriptedRepo do
  @moduledoc """
  The stand-in for the answers a live server cannot be made to give on demand: a
  repo that will not start, and a connection lost between two queries. `query/2`
  answers with the function a test put in the application environment.
  """

  def config, do: []
  def __adapter__, do: Ecto.Adapters.Postgres
  def start_link(_opts), do: {:error, :refused}

  def query(sql, _params), do: Application.fetch_env!(:ash_strangler, :check_test_answer).(sql)
end

defmodule AshStrangler.CheckTest.RoutedTwin do
  @moduledoc "A twin whose repo each test chooses, including none at all."
  use Ash.Resource,
    domain: AshStrangler.CheckTest.RoutedDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "routed_items"
    schema "legacy"

    repo fn _resource, _type ->
      Application.get_env(:ash_strangler, :check_test_repo, AshStrangler.TestRepo)
    end

    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CheckTest.Routed do
  @moduledoc false

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a75"

  use Ash.Resource,
    domain: AshStrangler.CheckTest.RoutedDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "routed_items"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.CheckTest.RoutedTwin do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :name, from: :name
      map :note, from: :note
    end
  end
end

defmodule AshStrangler.CheckTest.RoutedDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckTest.RoutedTwin
    resource AshStrangler.CheckTest.Routed
  end
end

defmodule AshStrangler.CheckTest do
  @moduledoc """
  `mix ash_strangler.check` is asserted against a real PostgreSQL server rather
  than a stubbed repo, for the same reason the rest of this suite is: the task's
  whole claim is that it answers questions about legacy rows, and a mocked answer
  would only assert that the task agrees with itself.
  """

  use AshStrangler.DataCase, async: false

  @domain "AshStrangler.CheckTest.Domain"

  setup do
    # `strangled_resources/1` reads the domain list out of the application
    # environment, so a resource declared in a test file is invisible until it is
    # there. Restored afterwards, since every other test in the suite reads the
    # same key.
    previous = Application.get_env(:ash_strangler, :ash_domains)
    Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.CheckTest.Domain])

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.put_env(:ash_strangler, :ash_domains, previous)
      Mix.shell(shell)
    end)

    :ok
  end

  describe "the declaration" do
    test "reports the mechanism each mapping needs and the one that is emitted" do
      {_result, output} = check()

      assert output =~ "AshStrangler.CheckTest.Measured"
      assert output =~ "twin       AshStrangler.Test.Legacy.Users — legacy.users"
      assert output =~ ~r/login\s+ideal :base_trigger\s+emitted :instead_of/
      assert output =~ "cheaper than what is emitted"
    end

    test "measures nothing, and says so, with --no-data" do
      {_result, output} = check(["--no-data"])

      assert output =~ "Nothing was measured"
      refute output =~ "twin freshness"
    end
  end

  describe "assertions against the legacy rows" do
    test "an empty legacy table satisfies every assertion" do
      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/allow_nil\? false  login/
      assert output =~ ~r/identity unique_login \(login\)/
      assert output =~ "no duplicate groups"
      assert output =~ "every mapping projects over all 4 column(s)"
      assert output =~ "twin freshness"
      assert output =~ "10 column(s), all present"
      assert output =~ "each backed by a unique index"
    end

    test "an identity Ash reads case-insensitively finds duplicates the legacy index allows" do
      insert_legacy_user!(login: "Duplicate")
      insert_legacy_user!(login: "duplicate")

      {result, output} = check()

      # `legacy.users` has a unique index on `login`, so both rows were accepted.
      # The identity is over a `:ci_string` attribute, so Ash believes they collide.
      assert output =~ "1 duplicate group(s) over (login)::citext"
      assert output =~ "has already been taken"
      assert {:exit, {:shutdown, 1}} = result
    end

    test "runs the coalesce side condition against real rows" do
      insert_legacy_user!(email: "none@example.com")

      {_result, output} = check()

      assert output =~ "GetPut  email"
      assert output =~ "rows_where_the_default_is_a_real_value"
      assert output =~ "1"
    end

    test "runs the concat side condition against real rows" do
      insert_legacy_user!(first_name: "de la", last_name: "Cruz")

      {_result, output} = check()

      assert output =~ "GetPut  full_name"
      assert output =~ "rows_whose_operands_contain_the_separator"
    end

    # A warning is a warning on purpose: the coalesce and concat side conditions
    # hold or fail per row, and a project mid-migration has to be able to see them
    # without the build going red. Only a violated assertion fails.
    test "a side condition that fails does not fail the task" do
      insert_legacy_user!(email: "none@example.com", first_name: "de la")

      {result, _output} = check()

      assert result == :ok
    end
  end

  describe "the twin against the database" do
    test "reports a column the legacy relation has and the twin does not" do
      TestRepo.query!("ALTER TABLE legacy.users ADD COLUMN nickname text", [])

      {result, output} = check()

      assert output =~ "the relation has column(s) the twin does not declare: \"nickname\""
      assert output =~ "invisible to every mapping"
      # A warning, not a failure: a column this application deliberately does not
      # read is a legitimate state, and the only way to distinguish it from drift
      # is to ask a person.
      assert result == :ok
    end

    test "reports a twin identity Postgres does not enforce" do
      TestRepo.query!("DROP INDEX legacy.index_users_on_login", [])

      {result, output} = check()

      assert output =~ "declares unique set(s) Postgres does not enforce"
      assert output =~ ~s("login")
      assert {:exit, {:shutdown, 1}} = result
    end

    test "a partial unique index does not count as enforcing an identity" do
      TestRepo.query!("DROP INDEX legacy.index_users_on_login", [])

      TestRepo.query!(
        "CREATE UNIQUE INDEX index_users_on_login ON legacy.users (login) WHERE state = 'active'",
        []
      )

      {_result, output} = check()

      assert output =~ "declares unique set(s) Postgres does not enforce"
    end

    # `UNIQUE (login, lower(email))` allows two rows with the same login and
    # different emails, so it does not make `login` unique. The expression key
    # has attnum 0, which an inner join to `pg_attribute` silently drops.
    test "a unique index mixing a plain column and an expression does not enforce the plain column" do
      TestRepo.query!("DROP INDEX legacy.index_users_on_login", [])

      TestRepo.query!(
        "CREATE UNIQUE INDEX index_users_on_login ON legacy.users (login, lower(email))",
        []
      )

      {result, output} = check()

      assert output =~ "declares unique set(s) Postgres does not enforce"
      assert output =~ ~s("login")
      assert {:exit, {:shutdown, 1}} = result
    end

    test "a unique index over an expression alone does not enforce the column" do
      TestRepo.query!("DROP INDEX legacy.index_users_on_login", [])

      TestRepo.query!(
        "CREATE UNIQUE INDEX index_users_on_login ON legacy.users (lower(login))",
        []
      )

      {_result, output} = check()

      assert output =~ "declares unique set(s) Postgres does not enforce"
    end

    # `INCLUDE` columns are payload for index-only scans, not part of the key.
    # `UNIQUE (login) INCLUDE (email)` enforces `login` alone.
    test "a unique index's INCLUDE columns are not part of the set it enforces" do
      TestRepo.query!("DROP INDEX legacy.index_users_on_login", [])

      TestRepo.query!(
        "CREATE UNIQUE INDEX index_users_on_login ON legacy.users (login) INCLUDE (email)",
        []
      )

      {result, output} = check()

      refute output =~ "declares unique set(s) Postgres does not enforce"
      assert output =~ "each backed by a unique index"
      assert result == :ok
    end

    # The same payload column must not let an index claim a set it does not
    # enforce: `UNIQUE (email) INCLUDE (login)` is unique over `email`, not over
    # `login`.
    test "an INCLUDE column does not make the index enforce that column" do
      TestRepo.query!("DROP INDEX legacy.index_users_on_login", [])

      TestRepo.query!(
        "CREATE UNIQUE INDEX index_users_on_login ON legacy.users (email) INCLUDE (login)",
        []
      )

      {_result, output} = check()

      assert output =~ "declares unique set(s) Postgres does not enforce"
    end
  end

  # --- the ledger ---------------------------------------------------------

  describe "the ledger" do
    test "reports the unprocessed backlog per relation for a ledger-backed source" do
      # The ledger fixture lives in the round-trip domain, whose repo this
      # sandbox transaction already owns, and whose DDL the harness installed
      # at boot. The backlog line is informational by design -- a number
      # growing between sweeps is the drain's pulse, not a failed assertion --
      # so this asserts the shape of the report rather than a zero.
      # The setup's `on_exit` restores the domain env this swaps out.
      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.Test.Domain])

      {_result, output} = check(["--domain", "AshStrangler.Test.Domain"])

      assert output =~ "ledger backlog"
      assert output =~ ~r/legacy\.users — \d+ unprocessed event\(s\)/
    end

    test "says so rather than guessing when the events table does not exist" do
      # "Could not be measured" and "measured clean" are different answers.
      TestRepo.query!("DROP TABLE legacy_change_events")

      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.Test.Domain])

      {_result, output} = check(["--domain", "AshStrangler.Test.Domain"])

      assert output =~ "does not exist yet"
    end
  end

  # --- --strict and the database that is not there -------------------------

  describe "--strict" do
    test "fails a run that measured nothing for a check it could not run" do
      TestRepo.query!("DROP TABLE legacy_change_events")
      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.Test.Domain])

      {default, _output} = check(["--domain", "AshStrangler.Test.Domain"])
      {strict, output} = check(["--domain", "AshStrangler.Test.Domain", "--strict"])

      assert default == :ok
      assert output =~ "does not exist yet"
      assert {:exit, {:shutdown, 1}} = strict

      # The count it reports is the number of `????` lines it printed.
      unrun = length(Regex.scan(~r/\?\?\?\?/, output))
      assert unrun > 0
      assert output =~ "#{unrun} check(s) could not be measured"
    end

    test "fails a warning that says nothing was measured" do
      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.CheckTest.UnmappedDomain])
      args = ["--domain", "AshStrangler.CheckTest.UnmappedDomain"]

      {default, output} = check(args)
      {strict, _output} = check(args ++ ["--strict"])

      assert output =~ "no mapping accounts for it, so nothing was measured"
      assert default == :ok
      assert {:exit, {:shutdown, 1}} = strict
    end

    test "fails when no resource was found" do
      Application.put_env(:ash_strangler, :ash_domains, [])

      {default, output} = check()
      {strict, strict_output} = check(["--strict"])

      assert default == :ok
      assert output =~ "No resources use AshStrangler.Resource."
      assert {:exit, {:shutdown, 1}} = strict
      assert strict_output =~ "No resources use AshStrangler.Resource."
    end

    test "fails a --domain that names no domain" do
      {default, _output} = check(["--domain", "AshStrangler.CheckTest.Typo"])
      {strict, _output} = check(["--domain", "AshStrangler.CheckTest.Typo", "--strict"])

      assert default == :ok
      assert {:exit, {:shutdown, 1}} = strict
    end

    test "is refused together with --no-data, before any check runs" do
      error =
        assert_raise Mix.Error, fn ->
          Mix.Task.rerun("ash_strangler.check", ["--domain", @domain, "--strict", "--no-data"])
        end

      assert error.message =~ "--strict"
      assert error.message =~ "--no-data"
      assert drain() == ""
    end

    test "is refused together with --no-data for an estate report too" do
      assert_raise Mix.Error, ~r/--strict.*--no-data|--no-data.*--strict/s, fn ->
        Mix.Task.rerun("ash_strangler.check", ["--estate", "--strict", "--no-data"])
      end

      assert drain() == ""
    end

    test "exits 0 when everything was measured clean" do
      {result, output} = check(["--strict"])

      assert result == :ok
      refute output =~ "could not be measured"
    end
  end

  describe "a database that cannot be reached" do
    setup do
      Application.put_env(:ash_strangler, AshStrangler.CheckTest.DownRepo,
        username: "postgres",
        password: "postgres",
        hostname: "127.0.0.1",
        port: 1,
        database: "nowhere",
        pool_size: 1,
        queue_target: 20,
        queue_interval: 20,
        connect_timeout: 200
      )

      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.CheckTest.DownDomain])
      on_exit(fn -> Application.delete_env(:ash_strangler, AshStrangler.CheckTest.DownRepo) end)
    end

    @down ["--domain", "AshStrangler.CheckTest.DownDomain"]

    @tag capture_log: true
    test "still fails the task by default, once, without naming an attribute" do
      {result, output} = check(@down)

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ "database could not be reached"
      refute output =~ ~r/cast  (name|note|label)/
      assert length(Regex.scan(~r/database could not be reached/, output)) == 1
      assert output =~ ~r/1 assertion\(s\) failed/
    end
  end

  describe "--strict at the sites a live server cannot be made to reach" do
    setup do
      Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.CheckTest.RoutedDomain])

      on_exit(fn ->
        Application.delete_env(:ash_strangler, :check_test_repo)
        Application.delete_env(:ash_strangler, :check_test_answer)
      end)
    end

    @routed ["--domain", "AshStrangler.CheckTest.RoutedDomain"]

    test "fails an identity with no mapping to group by" do
      Application.put_env(:ash_strangler, :ash_domains, [
        AshStrangler.CheckTest.UnmappedIdentityDomain
      ])

      args = ["--domain", "AshStrangler.CheckTest.UnmappedIdentityDomain"]

      {default, output} = check(args)
      {strict, _output} = check(args ++ ["--strict"])

      assert output =~ "a key has no mapping to group by, so nothing was measured"
      assert default == :ok
      assert {:exit, {:shutdown, 1}} = strict
    end

    test "fails when no repo could be resolved" do
      Application.put_env(:ash_strangler, :check_test_repo, nil)

      {default, output} = check(@routed)
      {strict, _output} = check(@routed ++ ["--strict"])

      assert output =~ "No repo could be resolved"
      assert default == :ok
      assert {:exit, {:shutdown, 1}} = strict
    end

    test "fails when the repo could not be started" do
      Application.put_env(:ash_strangler, :check_test_repo, AshStrangler.CheckTest.ScriptedRepo)

      {default, output} = check(@routed)
      {strict, _output} = check(@routed ++ ["--strict"])

      assert output =~ "could not be started"
      assert default == :ok
      assert {:exit, {:shutdown, 1}} = strict
    end

    test "a legacy relation this environment does not have fails through the cast check" do
      {result, output} = check(@routed)

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*  cast  name/
      assert output =~ ~r/FAIL.*  twin freshness/
      assert output =~ ~r/\?\?\?\?.*  allow_nil\? false  id/
    end

    test "a connection error on the whole projection is not retried per attribute" do
      answer_as_a_running_repo(fn sql ->
        if whole_projection?(sql), do: connection_lost(), else: rejected()
      end)

      {result, output} = check(@routed)

      assert {:exit, {:shutdown, 1}} = result
      assert length(Regex.scan(~r/database could not be reached/, output)) == 1
      refute output =~ ~r/cast  (id|name|note)/
    end

    test "a connection lost during the per-attribute retry is the database, not the attribute" do
      answer_as_a_running_repo(fn sql ->
        if whole_projection?(sql), do: rejected(), else: connection_lost()
      end)

      {result, output} = check(@routed)

      assert {:exit, {:shutdown, 1}} = result
      assert length(Regex.scan(~r/database could not be reached/, output)) == 1
      refute output =~ ~r/cast  (id|name|note)/
    end

    test "a projection that fails whole while every attribute passes alone was not measured" do
      answer_as_a_running_repo(fn sql ->
        cond do
          whole_projection?(sql) -> rejected()
          sql =~ "projection" -> {:ok, %{rows: [[0]], columns: ["count"]}}
          true -> rejected()
        end
      end)

      {default, output} = check(@routed)
      {strict, strict_output} = check(@routed ++ ["--strict"])

      assert default == :ok
      assert output =~ ~r/\?\?\?\?.*  casts/
      assert {:exit, {:shutdown, 1}} = strict

      unrun = length(Regex.scan(~r/\?\?\?\?/, strict_output))
      assert strict_output =~ "#{unrun} check(s) could not be measured"
    end
  end

  # `Process.whereis/1` is how the task knows a repo is already running, so this
  # process stands in for it and the task goes straight to the queries.
  defp answer_as_a_running_repo(answer) do
    Application.put_env(:ash_strangler, :check_test_repo, AshStrangler.CheckTest.ScriptedRepo)
    Application.put_env(:ash_strangler, :check_test_answer, answer)
    Process.register(self(), AshStrangler.CheckTest.ScriptedRepo)
  end

  defp whole_projection?(sql), do: sql =~ "AS name" and sql =~ "AS note"

  defp rejected do
    {:error, %Postgrex.Error{message: "rejected by the database"}}
  end

  defp connection_lost do
    {:error, %DBConnection.ConnectionError{message: "connection closed"}}
  end

  # --- running the task --------------------------------------------------

  defp check(args \\ []) do
    result =
      try do
        Mix.Task.rerun("ash_strangler.check", ["--domain", @domain] ++ args)
        :ok
      catch
        :exit, reason -> {:exit, reason}
      end

    {result, drain()}
  end

  defp drain(collected \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> drain([message | collected])
    after
      0 -> collected |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
