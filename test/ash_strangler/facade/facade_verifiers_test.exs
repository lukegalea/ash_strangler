# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.VerifiersTest do
  @moduledoc """
  Each case is phrased as the mistake being caught: a facade that compiles
  when it should not is a vocabulary that lies about a source it does not
  own. Probes compile against the real Task fixture, then each verifier runs
  over `spark_dsl_config/0` and is named in the assertion — the same harness
  `AshStrangler.VerifiersTest` uses.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # The probe's baseline: a correct facade over the Task fixture. `secret` is
  # declared only by the sensitive probes.
  @baseline """
  facade do
    source AshStrangler.Test.Facades.Task

    map :id, from: :id
    map :title, from: :name

    decode :state, from: :status,
      values: %{open: :new, done: :finished, cancelled: :cancelled}

    hide :org_id, because: "The probe has no tenants."
    hide :estimate_minutes, because: "The probe does not show effort."
    hide :internal_notes, because: "Not part of this vocabulary."
    defer :legacy_ref
  end
  """

  describe "the source" do
    test "a source with no such read action is refused, naming both" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task
        read_action :no_such_read

        map :id, from: :id
        map :title, from: :name

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :status, because: "The probe does not show state."
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifySource, body)
      assert message =~ "no_such_read"
      assert message =~ "Task"
    end

    test "a `from:` the source does not have is refused, naming it" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :typo_column

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :status, because: "The probe does not show state."
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifySource, body)
      assert message =~ "typo_column"
    end

    test "an entry naming an attribute the facade does not declare is refused" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name
        map :typo, from: :name

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :status, because: "The probe does not show state."
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifySource, body)
      assert message =~ "typo"
    end
  end

  describe "the facade owns nothing" do
    test "a field policy is refused" do
      body =
        @baseline <>
          """
          field_policies do
            field_policy :title do
              authorize_if always()
            end

            field_policy :* do
              authorize_if always()
            end
          end
          """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyOwnShape, body)
      assert message =~ "field_policy"
    end

    test "a policy block is refused" do
      body =
        @baseline <>
          """
          policies do
            policy always() do
              authorize_if always()
            end
          end
          """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyOwnShape, body)
      assert message =~ "policy"
    end

    test "a create action of its own is refused" do
      body =
        @baseline <>
          """
          actions do
            create :create do
              accept [:title]
            end
          end
          """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyOwnShape, body)
      assert message =~ "create"
    end

    test "an update action of its own is refused" do
      body =
        @baseline <>
          """
          actions do
            update :update do
              accept [:title]
            end
          end
          """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyOwnShape, body)
      assert message =~ "update"
    end

    test "a destroy action of its own is refused" do
      body =
        @baseline <>
          """
          actions do
            destroy :destroy do
            end
          end
          """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyOwnShape, body)
      assert message =~ "destroy"
    end

    test "a read action that is not the facade manual read is refused" do
      body =
        """
        actions do
          read :read do
            primary? true
          end
        end

        """ <> @baseline

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyOwnShape, body)
      assert message =~ "manual"
    end

    test "the facade's own manual read is accepted" do
      body =
        """
        actions do
          read :read do
            primary? true
            manual AshStrangler.Facade.Read
          end
        end

        """ <> @baseline

      assert :ok = verify_compiles(body)
    end
  end

  describe "sensitive? is inherited, never set" do
    test "a sensitive attribute over an insensitive source is refused" do
      body = """
      attributes do
        attribute :secret, :string, public?: true, sensitive?: true
      end

      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name
        map :secret, from: :internal_notes

        decode :state, from: :status,
          values: %{open: :new, done: :finished, cancelled: :cancelled}

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifySensitive, body)
      assert message =~ "secret"
      assert message =~ "Drop the flag"
    end

    test "an insensitive attribute over a sensitive source is refused" do
      # The Credential's `number` is sensitive; the probe's `number` is not.
      body = """
      facade do
        source AshStrangler.Test.Facades.Credential

        map :id, from: :id
        map :title, from: :holder
        map :number, from: :number
        concat :notes, from: [:holder, :number],
          read_only?: true,
          because: "A display string cannot be split back."
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifySensitive, body)
      assert message =~ ":number"
      assert message =~ "sensitive? true"
    end

    test "an attribute sensitive in both directions compiles" do
      body = """
      attributes do
        attribute :secret, :string, public?: true, sensitive?: true
      end

      facade do
        source AshStrangler.Test.Facades.Credential

        map :id, from: :id
        map :title, from: :holder
        map :secret, from: :number
      end
      """

      assert :ok = verify_compiles(body)
    end
  end

  describe "writes" do
    test "`via:` naming a missing source action does not compile, naming source and action" do
      body =
        write_body("write :finish, via: :no_such_action, sets: [state: :finished]")

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyWrites, body)
      assert message =~ "no_such_action"
      assert message =~ "Task"
    end

    test "`via:` naming a non-update action does not compile" do
      body = write_body("write :finish, via: :create, sets: [state: :finished]")

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyWrites, body)
      assert message =~ "create action"
    end

    test "a read-only lens write does not compile and names the `because:`" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name

        map :state, from: expr(status),
          read_only?: true,
          because: "This probe reads state, it does not decide it."

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref

        write :finish, via: :complete, sets: [state: :finished]
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyWrites, body)
      assert message =~ "This probe reads state, it does not decide it."
    end

    test "a `sets:` value the source action does not set does not compile" do
      body = write_body("write :finish, via: :complete, sets: [state: :cancelled]")

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyWrites, body)
      assert message =~ "does not set :status to :cancelled"
      assert message =~ "status: :done"
    end

    test "an `accepts:` column the action does not accept does not compile" do
      body = write_body("write :rename, via: :set_estimate, accepts: [:title]")

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyWrites, body)
      assert message =~ ":name"
      assert message =~ "does not accept"
    end

    test "a write naming no `sets:` and no `accepts:` does not compile" do
      body = write_body("write :finish, via: :complete")

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyWrites, body)
      assert message =~ "no `sets:` and no `accepts:`"
    end

    test "a correct write compiles" do
      body = write_body("write :finish, via: :complete, sets: [state: :finished]")
      assert :ok = verify_compiles(body)
    end
  end

  defp write_body(write) do
    """
    facade do
      source AshStrangler.Test.Facades.Task

      map :id, from: :id
      map :title, from: :name

      decode :state, from: :status,
        values: %{open: :new, done: :finished, cancelled: :cancelled}

      hide :org_id, because: "The probe has no tenants."
      hide :estimate_minutes, because: "The probe does not show effort."
      hide :internal_notes, because: "Not part of this vocabulary."
      defer :legacy_ref

      #{write}
    end
    """
  end

  describe "the estate" do
    test "a source attribute neither exposed, hidden nor deferred fails with its name" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name

        decode :state, from: :status,
          values: %{open: :new, done: :finished, cancelled: :cancelled}

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyEstate, body)
      assert message =~ "internal_notes"
    end

    test "`hide` of a read attribute fails" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name
        map :notes, from: :internal_notes

        decode :state, from: :status,
          values: %{open: :new, done: :finished, cancelled: :cancelled}

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyEstate, body)
      assert message =~ "internal_notes is hidden but some lens reads it"
    end

    test "`hide` and `defer` naming a non-existent source attribute fail" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name

        decode :state, from: :status,
          values: %{open: :new, done: :finished, cancelled: :cancelled}

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :internal_notes, because: "Not part of this vocabulary."
        hide :no_such_attribute, because: "A typo is a hole, not a note."
        defer :also_missing
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyEstate, body)
      assert message =~ "no_such_attribute"
      assert message =~ "also_missing"
    end
  end

  describe "obligations" do
    test "a decode that does not cover the source's values fails compilation" do
      body = """
      facade do
        source AshStrangler.Test.Facades.Task

        map :id, from: :id
        map :title, from: :name

        decode :state, from: :status, values: %{open: :new, done: :finished}

        hide :org_id, because: "The probe has no tenants."
        hide :estimate_minutes, because: "The probe does not show effort."
        hide :internal_notes, because: "Not part of this vocabulary."
        defer :legacy_ref
      end
      """

      message = assert_rejected_by(AshStrangler.Facade.Verifiers.VerifyObligations, body)
      assert message =~ "cancelled"
    end
  end

  # --- harness -----------------------------------------------------------------

  defp define(body) do
    name = "AshStrangler.Facade.VerifiersTest.Probe#{System.unique_integer([:positive])}"

    # The definition succeeds even for an invalid facade; the verifier
    # complaint is emitted by the parallel checker afterwards. Capturing keeps
    # that noise out of the test output.
    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string("""
        defmodule #{name} do
          use Ash.Resource,
            domain: AshStrangler.Test.Facades,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshStrangler.Facade],
            authorizers: [Ash.Policy.Authorizer]

          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
            attribute :title, :string, public?: true
            attribute :state, :atom, public?: true, constraints: [one_of: [:new, :finished, :cancelled]]
            attribute :number, :string, public?: true
            attribute :notes, :string, public?: true
          end

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end

  defp rejections(dsl) do
    for verifier <- AshStrangler.Facade.verifiers(),
        {:error, error} <- [verifier.verify(dsl)],
        do: {verifier, Exception.message(error)}
  end

  defp assert_rejected_by(verifier, body) do
    dsl = define(body)

    case verifier.verify(dsl) do
      {:error, error} ->
        Exception.message(error)

      other ->
        others = for {v, message} <- rejections(dsl), v != verifier, do: {v, message}

        flunk(
          "expected #{inspect(verifier)} to reject this facade, got #{inspect(other)}; " <>
            "others rejected with: #{inspect(others)}"
        )
    end
  end

  defp verify_compiles(body) do
    dsl = define(body)

    case rejections(dsl) do
      [] ->
        :ok

      rejections ->
        flunk("expected this facade to compile, but it was rejected: #{inspect(rejections)}")
    end
  end
end
