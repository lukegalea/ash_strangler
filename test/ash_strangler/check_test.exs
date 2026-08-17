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
