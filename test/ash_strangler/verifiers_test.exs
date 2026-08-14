defmodule AshStrangler.VerifiersTest do
  @moduledoc """
  The verifiers are the whole of version 0.1, so these tests are the product
  rather than a safety net for it.

  Each case is phrased as the mistake being caught. A verifier that fails to
  reject is not a failing test in the ordinary sense — it is a strangler
  migration that compiles and loses data, which is the failure mode this package
  exists to prevent.

  ## How these are run, and why not with `assert_raise`

  Spark verifiers do **not** raise when the module is defined. They run inside
  `__verify_spark_dsl__/1`, which `Module.ParallelChecker` invokes *after*
  compilation, in another process — which is why a bad DSL surfaces as
  `warning: ** (Spark.Error.DslError)` and only fails a build through
  `--warnings-as-errors`.

  So `assert_raise` around a `defmodule` catches nothing, and a test written that
  way passes whether or not the verifier works. These call `verify/1` directly
  against the compiled DSL state instead, which tests the thing that actually
  decides.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @verifiers [
    AshStrangler.Verifiers.VerifyCompleteMapping,
    AshStrangler.Verifiers.VerifyWritableMappingsReversible,
    AshStrangler.Verifiers.VerifyNoUpserts,
    AshStrangler.Verifiers.VerifyIdentitiesBacked,
    AshStrangler.Verifiers.VerifyPhaseTransition
  ]

  defp define(body) do
    name = "T#{System.unique_integer([:positive])}"

    # The definition itself succeeds even for an invalid mapping; the verifier
    # complaint is emitted by the parallel checker afterwards. Capturing keeps
    # that noise out of the test output.
    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string("""
        defmodule #{name} do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshStrangler.Resource]

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module
  end

  # Runs every verifier and returns the first error, mirroring what Spark does.
  defp verify(module) do
    dsl = module.spark_dsl_config()

    Enum.find_value(@verifiers, :ok, fn verifier ->
      case verifier.verify(dsl) do
        {:error, error} -> {:error, error}
        _ -> nil
      end
    end)
  end

  # Asserts against ONE verifier rather than "whichever fires first". Several
  # verifiers legitimately reject the same bad mapping — a source with no `key`
  # also leaves the primary key unaccounted for — and asserting on the first
  # error would make these tests sensitive to verifier ordering rather than to
  # the behaviour under test.
  defp assert_rejected_by(verifier, body, expected) do
    case body |> define() |> then(& &1.spark_dsl_config()) |> verifier.verify() do
      {:error, error} ->
        message = Exception.message(error)

        assert message =~ expected,
               "expected #{inspect(verifier)} to mention #{inspect(expected)}, got:\n\n#{message}"

        message

      other ->
        flunk("expected #{inspect(verifier)} to reject this mapping, got #{inspect(other)}")
    end
  end

  defp assert_rejected(body, expected) do
    case body |> define() |> verify() do
      {:error, error} ->
        message = Exception.message(error)

        assert message =~ expected,
               "expected the error to mention #{inspect(expected)}, got:\n\n#{message}"

        message

      :ok ->
        flunk("expected a verifier to reject this mapping, but all of them passed")
    end
  end

  defp assert_accepted(body) do
    assert :ok == body |> define() |> verify()
  end

  @key ~S|key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e"}|

  describe "VerifyCompleteMapping" do
    test "rejects an attribute that is neither mapped nor declared unmapped" do
      message =
        assert_rejected(
          """
          attributes do
            uuid_primary_key :id
            attribute :email, :string, public?: true
            attribute :nickname, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source "legacy.users" do
              #{@key}
              map :email, "email"
            end
          end
          """,
          ":nickname"
        )

      # The message has to say WHY silence is not acceptable, or the reader will
      # assume the default is harmless and add the attribute to `unmapped`
      # without thinking.
      assert message =~ "NULL"
      assert message =~ "unmapped"
    end

    test "accepts an attribute declared unmapped with a reason" do
      assert_accepted("""
      attributes do
        uuid_primary_key :id
        attribute :email, :string, public?: true
        attribute :nickname, :string, public?: true
      end

      strangler do
        phase :read_from_legacy
        source "legacy.users" do
          #{@key}
          map :email, "email"
          unmapped [:nickname], as: :null, because: "Never existed in legacy."
        end
      end
      """)
    end
  end

  describe "VerifyWritableMappingsReversible" do
    test "rejects a computed mapping that is writable but has no inverse" do
      assert_rejected(
        """
        attributes do
          uuid_primary_key :id
          attribute :full_name, :string, public?: true
        end

        strangler do
          phase :read_from_legacy
          source "legacy.users" do
            #{@key}
            map :full_name do
              from "first_name || ' ' || last_name"
            end
          end
        end
        """,
        "supplies no `to:`"
      )
    end

    test "rejects `to:` without `into:`, because there is no column to write" do
      assert_rejected(
        """
        attributes do
          uuid_primary_key :id
          attribute :state_code, :integer, public?: true
        end

        strangler do
          phase :read_from_legacy
          source "legacy.users" do
            #{@key}
            map :state_code do
              from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
              to "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'x' END"
            end
          end
        end
        """,
        "no `into:`"
      )
    end

    test "rejects `writable? false` with no reason" do
      assert_rejected(
        """
        attributes do
          uuid_primary_key :id
          attribute :full_name, :string, public?: true
        end

        strangler do
          phase :read_from_legacy
          source "legacy.users" do
            #{@key}
            map :full_name do
              from "first_name || ' ' || last_name"
              writable? false
            end
          end
        end
        """,
        "no `because:`"
      )
    end

    test "accepts a read-only computed mapping with a reason" do
      assert_accepted("""
      attributes do
        uuid_primary_key :id
        attribute :full_name, :string, public?: true
      end

      strangler do
        phase :read_from_legacy
        source "legacy.users" do
          #{@key}
          map :full_name do
            from "first_name || ' ' || last_name"
            writable? false
            because "Not decomposable: 'de la Cruz' splits wrong."
          end
        end
      end
      """)
    end
  end

  describe "VerifyNoUpserts" do
    test "rejects an upsert action when writes go through INSTEAD OF triggers" do
      message =
        assert_rejected(
          """
          attributes do
            uuid_primary_key :id
            attribute :email, :string, public?: true
          end

          identities do
            identity :unique_email, [:email]
          end

          actions do
            defaults [:read]
            create :create do
              upsert? true
              upsert_identity :unique_email
            end
          end

          strangler do
            phase :read_from_legacy
            source "legacy.users" do
              writes :triggers
              #{@key}
              map :email, "email"
              index "index_users_on_email", unique: true, columns: ["email"]
            end
          end
          """,
          ":create"
        )

      # The message must explain the silent half of the failure. `DO UPDATE`
      # errors loudly; `DO NOTHING` is accepted and does nothing, and that is the
      # one that reaches production.
      assert message =~ "DO NOTHING"
      assert message =~ "writes: :auto"
    end

    test "accepts the same upsert when writes rely on view auto-updatability" do
      assert_accepted("""
      attributes do
        uuid_primary_key :id
        attribute :email, :string, public?: true
      end

      identities do
        identity :unique_email, [:email]
      end

      actions do
        defaults [:read]
        create :create do
          upsert? true
          upsert_identity :unique_email
        end
      end

      strangler do
        phase :read_from_legacy
        source "legacy.users" do
          writes :auto
          #{@key}
          map :email, "email"
          index "index_users_on_email", unique: true, columns: ["email"]
        end
      end
      """)
    end
  end

  describe "VerifyIdentitiesBacked" do
    test "rejects an identity with no declared unique index" do
      message =
        assert_rejected(
          """
          attributes do
            uuid_primary_key :id
            attribute :email, :string, public?: true
          end

          identities do
            identity :unique_email, [:email]
          end

          strangler do
            phase :read_from_legacy
            source "legacy.users" do
              #{@key}
              map :email, "email"
            end
          end
          """,
          "not backed by a declared unique index"
        )

      # The reason this matters is the point of the check: Ash reports "already
      # been taken" for a constraint the database does not have.
      assert message =~ "duplicates are accepted"
    end

    test "rejects an identity over a computed mapping" do
      assert_rejected(
        """
        attributes do
          uuid_primary_key :id
          attribute :full_name, :string, public?: true
        end

        identities do
          identity :unique_name, [:full_name]
        end

        strangler do
          phase :read_from_legacy
          source "legacy.users" do
            #{@key}
            map :full_name do
              from "first_name || ' ' || last_name"
              writable? false
              because "Not decomposable."
            end
          end
        end
        """,
        "not mapped to a plain legacy column"
      )
    end

    test "accepts an identity backed by a declared unique index" do
      assert_accepted("""
      attributes do
        uuid_primary_key :id
        attribute :email, :string, public?: true
      end

      identities do
        identity :unique_email, [:email]
      end

      strangler do
        phase :read_from_legacy
        source "legacy.users" do
          #{@key}
          map :email, "email"
          index "index_users_on_email", unique: true, columns: ["email"]
        end
      end
      """)
    end
  end

  describe "VerifyPhaseTransition" do
    test "rejects a source with no key derivation" do
      assert_rejected_by(
        AshStrangler.Verifiers.VerifyPhaseTransition,
        """
        attributes do
          uuid_primary_key :id
          attribute :email, :string, public?: true
        end

        strangler do
          phase :read_from_legacy
          source "legacy.users" do
            map :email, "email"
          end
        end
        """,
        "declares no `key`"
      )
    end

    test "rejects a write phase with an unexplained read-only mapping" do
      # Reaching this requires bypassing the reversibility verifier, which is why
      # `because` is present but blank rather than absent.
      assert_rejected_by(
        AshStrangler.Verifiers.VerifyPhaseTransition,
        """
        attributes do
          uuid_primary_key :id
          attribute :full_name, :string, public?: true
        end

        strangler do
          phase :dual_write
          source "legacy.users" do
            #{@key}
            map :full_name do
              from "first_name || ' ' || last_name"
              writable? false
              because "   "
            end
          end
        end
        """,
        "read-only without a stated reason"
      )
    end
  end
end
