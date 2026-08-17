# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ObligationsTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.ObligationsTest.Legacy.Accounts
    resource AshStrangler.ObligationsTest.Legacy.Addresses
  end
end

defmodule AshStrangler.ObligationsTest.Legacy.Addresses do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.ObligationsTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "addresses"
    schema "obligations_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :account_id, :integer
    attribute :city, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.ObligationsTest.Legacy.Accounts do
  @moduledoc """
  A twin with a **to-many** relationship, which is the only thing it is for.

  A mapping reading through it would multiply view rows, and refusing that has to
  happen at compile time -- otherwise the view references a relation nothing joined.
  """
  use Ash.Resource,
    domain: AshStrangler.ObligationsTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "obligations_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :email, :string
  end

  relationships do
    has_many :addresses, AshStrangler.ObligationsTest.Legacy.Addresses do
      source_attribute :id
      destination_attribute :account_id
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.ObligationsTest do
  @moduledoc """
  The obligations, exercised against mappings that violate them.

  Every test here writes out a mapping that is **wrong**, and asserts it is
  refused. That is the only way to know a refusal is real: a verifier that has
  never rejected anything is indistinguishable from one that returns `:ok`.

  ## Spark verifiers do not raise where you expect them to

  They run *after* the module is compiled, in `Module.ParallelChecker`, which means
  neither of the two obvious spellings works:

      assert_raise Spark.Error.DslError, fn -> defmodule Broken do ... end end
      assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end

  The first catches nothing and passes vacuously. The second is worse, because it
  *looks* like it should work — the module really is checked — but the failure is
  emitted as a compiler **warning** to standard error rather than raised into the
  caller. Measured: a deliberately broken `decode` compiled cleanly through
  `Code.compile_string/1`, printed a `Spark.Error.DslError` warning, and the
  surrounding `assert_raise` failed with "expected ... to be refused, but it
  compiled".

  So every test here compiles the module and then runs the verifiers itself, over
  `spark_dsl_config/0`. Getting this wrong is how a suite acquires a hundred green
  tests that assert nothing.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Obligations

  # Compiles a resource whose `strangler` block is `body`, runs the verifiers over
  # it, and returns the message of the first refusal -- or fails the test if every
  # verifier passes.
  #
  # The compile itself is wrapped in `capture_io(:stderr, ...)` because the
  # post-compile check emits the same failure as a warning, and a suite whose
  # passing output is full of red stack traces trains people to ignore it.
  defp refuse!(name, body) do
    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

      postgres do
        table "#{Macro.underscore(name)}"
        schema "strangler"
        repo AshStrangler.TestRepo
        migrate? false
      end

      #{body}
    end
    """

    capture_io(:stderr, fn -> Code.compile_string(source) end)

    module = Module.concat([name])
    dsl = module.spark_dsl_config()

    AshStrangler.Resource.verifiers()
    |> Enum.find_value(fn verifier ->
      case verifier.verify(dsl) do
        {:error, %{__struct__: _} = error} -> Exception.message(error)
        _ -> nil
      end
    end)
    |> case do
      nil -> flunk("expected #{name} to be refused, but every verifier passed")
      message -> message
    end
  end

  describe "GetTotal — a legacy value the forward direction cannot produce a value for" do
    test "refuses the decode that shipped in 0.1, naming the three states it destroys" do
      # The mapping this whole design exists to refuse, translated into v2. In 0.1
      # it was `from "CASE state WHEN 'active' THEN 0 ELSE 1 END"` with a
      # hand-written inverse, and the `ELSE` is what made it look total: every
      # legacy value produced *a* code, and three of them produced the wrong one.
      #
      # A `decode` has no `ELSE`, so the same mistake is a missing table entry --
      # which the twin's declared value set makes decidable.
      message =
        refuse!("AshStrangler.ObligationsTest.PartialDecode", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :state_code, :integer, public?: true, constraints: [min: 0, max: 1]
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            decode :state_code, from: :state, values: %{active: 0, suspended: 1}
          end
        end
        """)

      assert message =~ "GetTotal"

      # The three lifecycle states 0.1 silently rewrote to `suspended`, named.
      assert message =~ ":passive"
      assert message =~ ":pending"
      assert message =~ ":deleted"

      # And the tempting fix refused by name, because it is the bug.
      assert message =~ "catch-all"
    end
  end

  describe "PutTotal — an attribute value with no legal legacy encoding" do
    test "refuses a decode onto an unbounded target, which is what let `state_code: 7` through" do
      message =
        refuse!("AshStrangler.ObligationsTest.UnboundedTarget", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :state_code, :integer, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            decode :state_code,
              from: :state,
              values: %{active: 0, passive: 1, pending: 2, suspended: 3, deleted: 4}
          end
        end
        """)

      assert message =~ "PutTotal"
      assert message =~ "unbounded value space"

      # In 0.1 `state_code` was a bare `:integer`, so `state_code: 7` was legal,
      # wrote `'suspended'`, and read back as `1`. The error says how to close it.
      assert message =~ "constraints one_of:" or message =~ "constraints"
    end
  end

  describe "PutGet — forward ∘ backward is not the identity" do
    test "refuses the shipped mapping's exact value table, showing deleted becoming suspended" do
      # The 0.1 mapping, translated **faithfully** rather than charitably. Its forward
      # direction was `CASE state WHEN 'active' THEN 0 ELSE 1 END`, which is the table
      # below: `active` to 0 and everything else to 1. Its backward direction sent 1
      # to `'suspended'`, which is what an inverted table does when four keys share a
      # value — it picks one.
      #
      # So the mapping is *total in both directions* and still not a bijection.
      # `GetTotal` passes: every legacy value decodes. `PutTotal` passes: every code
      # encodes. Only `PutGet` sees it, which is why a totality check alone would have
      # waved the corruption through exactly as the shipped verifier did.
      message =
        refuse!("AshStrangler.ObligationsTest.TheShippedMapping", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :state_code, :integer, public?: true, constraints: [min: 0, max: 1]
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            decode :state_code,
              from: :state,
              values: %{active: 0, passive: 1, pending: 1, suspended: 1, deleted: 1}
          end
        end
        """)

      assert message =~ "PutGet"

      # The counterexample table names every value that cannot survive a round trip,
      # which is the three states the shipped mapping silently rewrote.
      assert message =~ "PUTGET VIOLATION"
      assert message =~ ":deleted"
      assert message =~ ":passive"
      assert message =~ ":pending"

      # And it says what each becomes, which is the sentence somebody has to read
      # before they believe it: `deleted` projects to 1 and writes back as something
      # else.
      assert message =~ "legacy_value | projects_to | writes_back_as"
    end

    test "refuses a non-injective decode, with the counterexample table" do
      message =
        refuse!("AshStrangler.ObligationsTest.Collision", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :state_code, :integer, public?: true, constraints: [min: 0, max: 3]
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            # `passive` and `pending` share a code. Every legacy value decodes and
            # every code encodes, so `GetTotal` and `PutTotal` both pass -- the table
            # is total in both directions and still not a bijection, which is exactly
            # the case a totality check alone would wave through.
            decode :state_code,
              from: :state,
              values: %{active: 0, passive: 1, pending: 1, suspended: 2, deleted: 3}
          end
        end
        """)

      assert message =~ "PutGet"
      assert message =~ "not injective"

      # A counterexample, not a verdict. BIRDS generates concrete counterexamples
      # for exactly this reason: `unsat` is not a next step.
      assert message =~ "legacy_value | projects_to | writes_back_as"
      assert message =~ "PUTGET VIOLATION"
    end
  end

  describe "redundancy — a declared transform that is the identity" do
    test "refuses a decode whose table maps every value to itself" do
      message =
        refuse!("AshStrangler.ObligationsTest.IdentityDecode", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :state, :atom, public?: true,
            constraints: [one_of: [:passive, :pending, :active, :suspended, :deleted]]
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            decode :state,
              from: :state,
              values: %{
                active: :active, passive: :passive, pending: :pending,
                suspended: :suspended, deleted: :deleted
              }
          end
        end
        """)

      assert message =~ "identity function written out longhand"

      # The cost is the point: a `decode` is classified `:base_trigger`, so an
      # identity one buys a mechanism and changes nothing.
      assert message =~ "upserts"
    end
  end

  describe "linearity — one legacy column, one writer" do
    test "refuses two mappings writing the same legacy column" do
      message =
        refuse!("AshStrangler.ObligationsTest.TwoWriters", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :login, :string, public?: true
          attribute :username, :string, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            map :login, from: :login
            map :username, from: :login
          end
        end
        """)

      assert message =~ "linearity"
      assert message =~ ":login"

      # The failure mode named: one assignment silently wins, and which one depends
      # on the order the DSL happens to be written in.
      assert message =~ "silently wins"
    end
  end

  describe "a has_many mapping is refused before it can produce invalid SQL" do
    test "reading through a to-many relationship names the fan-out it would cause" do
      # `AshStrangler.Twin.joins_for/2` refuses this by name, but `Info.joins/1`
      # swallows the error and returns `[]` — which is right for a diagram and means
      # nothing else notices. Left unchecked, the view's `SELECT` referenced an
      # unjoined `payments.amount` and PostgreSQL rejected it at `mix ash.migrate`
      # time, in whichever environment ran first.
      message =
        refuse!("AshStrangler.ObligationsTest.FannedOut", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :city, :string, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.ObligationsTest.Legacy.Accounts do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            map :city,
              from: expr(addresses.city),
              read_only?: true,
              because: "Read through a relationship."
          end
        end
        """)

      assert message =~ "has_many"
      assert message =~ "multiply view rows"
      # The consequence named, not just the type: one legacy row becoming three means
      # the new application reports more records than the old one.
      assert message =~ "more records than the old one"
    end
  end

  describe "a derived cast that is not deterministic is refused" do
    test "a naive twin column feeding an instant demands `zone:` rather than deriving a cast" do
      # A regression that deriving the cast *introduced*. 0.1 refused
      # `cast: :timestamptz` without a `from_zone:`, and once the cast came from
      # comparing the twin's type to the attribute's, the hand-typed declaration the
      # verifier keyed on no longer existed — so `map :archived_at, from: :deleted_at`
      # silently derived `(deleted_at)::timestamptz`, which reads a naive value as
      # wall-clock time in the *session's* `TimeZone`.
      #
      # Measured on 17.10, one stored value: `12:00:00+00` under `UTC`,
      # `12:00:00-04` under `America/New_York`, `12:00:00+10:30` under
      # `Australia/Lord_Howe`. Fourteen and a half hours apart, no error.
      #
      # Deriving a decision from types is right; it does not inherit the *judgement*
      # the typed version carried. The type system can see that a cast is needed and
      # cannot see that one particular cast is non-deterministic.
      message =
        refuse!("AshStrangler.ObligationsTest.DriftingTimestamp", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :archived_at, :utc_datetime_usec, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            map :archived_at, from: :deleted_at
          end
        end
        """)

      assert message =~ "not deterministic"
      assert message =~ ~s|zone: "UTC"|
      # And the second reason, which is not about drift: the cast it refuses is
      # `STABLE`, so it could never have carried an expression index.
      assert message =~ "IMMUTABLE"
    end

    test "the same mapping with `zone:` is accepted, which is the fixtures' form" do
      # `AshStrangler.Test.LegacyUser` maps exactly this column and compiles, so the
      # verifier is refusing the missing `zone:` rather than the column pair.
      assert Enum.all?(
               AshStrangler.Resource.verifiers(),
               &(&1.verify(AshStrangler.Test.LegacyUser.spark_dsl_config()) == :ok)
             )
    end
  end

  describe "the fixtures discharge every obligation" do
    test "DualWriteUser's decode has no findings at all" do
      findings =
        AshStrangler.Test.DualWriteUser
        |> Obligations.check()
        |> Enum.filter(&(&1.attribute == :state_code))

      assert findings == [],
             "expected the ported `decode` to be clean, got:\n\n" <>
               Enum.map_join(findings, "\n", &"  #{&1.obligation}: #{&1.message}")
    end

    test "no fixture has an error-severity finding" do
      for resource <- [
            AshStrangler.Test.LegacyUser,
            AshStrangler.Test.DualWriteUser,
            AshStrangler.Test.MixedUser,
            AshStrangler.Demo.Customer,
            AshStrangler.Demo.Organization,
            AshStrangler.Demo.Address
          ] do
        assert Obligations.errors(resource) == [],
               "#{inspect(resource)} has obligation errors"
      end
    end
  end

  describe "what cannot be decided is measured instead" do
    test "a concat emits the separator-absence assertion rather than assuming it" do
      # `concat`'s reverse is `split_part`, correct only while the separator is
      # absent from every operand. That is a fact about the data, not the schema,
      # so it is a query rather than a claim -- the degraded form of Boomerang's
      # regex-ambiguity condition.
      [finding] =
        AshStrangler.Demo.Customer
        |> Obligations.assertions()
        |> Enum.filter(&(&1.attribute == :full_name))

      assert finding.severity == :warning
      assert finding.assertion =~ "position("
      assert finding.assertion =~ "demo_legacy.accounts"
      assert finding.assertion =~ "first_name"
      assert finding.assertion =~ "last_name"
    end

    test "an undecidable obligation is a warning, never a silent pass" do
      # The distinction that matters: a warning here means "could not be decided
      # and has been re-emitted as SQL", not "probably fine". Anything that returns
      # no finding at all is a claim that the obligation HOLDS.
      for finding <- Obligations.check(AshStrangler.Demo.Customer) do
        assert finding.severity in [:error, :warning]
        assert is_binary(finding.message) and finding.message != ""
      end
    end
  end

  describe "collapse — the decision table's own obligations" do
    test "refuses a table with no clause for some combination of guards" do
      message =
        refuse!("AshStrangler.ObligationsTest.IncompleteCollapse", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :status, :atom, public?: true, constraints: [one_of: [:archived, :active]]
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Demo.Legacy.Accounts do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            # No `:otherwise`. A row that is neither deleted nor approved matches
            # nothing, and `status` reads as NULL for it.
            collapse :status do
              state :archived, when: expr(is_deleted), set: [is_deleted: true, approved_at: nil]
              state :active, when: expr(not is_nil(approved_at)),
                set: [is_deleted: false, approved_at: nil]
            end
          end
        end
        """)

      assert message =~ "completeness"
      assert message =~ "missing rule"
      assert message =~ ":otherwise"
    end

    test "refuses a clause no input can reach" do
      message =
        refuse!("AshStrangler.ObligationsTest.MaskedClause", """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :status, :atom, public?: true,
            constraints: [one_of: [:archived, :also_archived, :pending]]
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Demo.Legacy.Accounts do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

            collapse :status do
              state :archived, when: expr(is_deleted), set: [is_deleted: true]
              # Identical guard, second. `:first` means it can never fire.
              state :also_archived, when: expr(is_deleted), set: [is_deleted: true]
              state :pending, when: :otherwise, set: [is_deleted: false]
            end
          end
        end
        """)

      assert message =~ "masked_rule"
      assert message =~ ":also_archived"
      assert message =~ "never be reached"
    end

    test "the demo's four-column lifecycle discharges completeness and reachability" do
      findings =
        AshStrangler.Demo.Customer
        |> Obligations.check()
        |> Enum.filter(&(&1.attribute == :status and &1.severity == :error))

      assert findings == []
    end
  end
end
