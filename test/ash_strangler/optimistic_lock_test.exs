# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.OptimisticLockTest do
  @moduledoc """
  An optimistic lock on an attribute the resource projects as a `constant` is refused
  at compile time while a view stands in for the table.

  The view answers a constant for every row, so the lock's filter always passes and
  its increment writes to a column the view cannot carry. The cases pin where the lock
  can come from (the action, or the top-level `changes` block), which writes count
  (updates and soft destroys), and where it stays legitimate.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Verifiers.VerifyOptimisticLock

  @namespace "0f7d9d0a-3f0e-4a59-8b8f-2a1c6e9d4b12"

  defp define(opts) do
    {module, _io} = compile(opts)
    module.spark_dsl_config()
  end

  defp compile(opts) do
    name = "AshStrangler.OptimisticLockTest.Probe#{System.unique_integer([:positive])}"
    phase = Keyword.get(opts, :phase, ":read_from_legacy")
    mapping = Keyword.get(opts, :mapping, "constant :version_number, expr(type(1, :integer))")

    {result, io} =
      with_io(:stderr, fn ->
        Code.eval_string(
          """
          defmodule #{name} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "optimistic_lock_probe_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              uuid_primary_key :id
              attribute :login, :string, public?: true
              attribute :version_number, :integer, public?: true, default: 1
            end

            actions do
              defaults [:read]
              #{Keyword.get(opts, :actions, "")}
            end

            changes do
              #{Keyword.get(opts, :changes, "")}
            end

            strangler do
              phase #{phase}

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "#{@namespace}"}
                map :login, from: :login
                #{mapping}
              end
            end
          end
          """,
          [],
          file: "probe_optimistic_lock.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = result
    {module, io}
  end

  @locked_update """
  update :rename do
    accept [:login]
    change optimistic_lock(:version_number)
  end
  """

  defp refused(opts) do
    assert {:error, error} = VerifyOptimisticLock.verify(define(opts))
    Exception.message(error)
  end

  describe "refused" do
    test "a lock in an update action, on a constant" do
      message = refused(actions: @locked_update)

      assert message =~ "action :rename locks on :version_number"
      assert message =~ "projects as a `constant`"
      assert message =~ "take the lock off these actions"
    end

    test "a lock from the top-level changes block, on every update" do
      message =
        refused(
          actions: "update :rename, accept: [:login]\nupdate :touch, accept: []",
          changes: "change optimistic_lock(:version_number), on: [:update]"
        )

      assert message =~ "action :rename locks on :version_number"
      assert message =~ "action :touch locks on :version_number"
    end

    test "a lock on a soft destroy, which is an update underneath" do
      message =
        refused(
          actions: """
          destroy :retire do
            soft? true
            change optimistic_lock(:version_number)
          end
          """
        )

      assert message =~ "action :retire locks on :version_number"
    end

    test "dual_write refuses it as well" do
      message = refused(actions: @locked_update, phase: ":dual_write")

      assert message =~ ":dual_write"
    end
  end

  describe "wired into the extension" do
    # The cases above call the verifier directly. This one compiles a resource and
    # reads what the compiler said, so it fails if the verifier is not registered
    # on `AshStrangler.Resource`.
    test "compiling a resource that locks on a constant reports it" do
      {_module, io} = compile(actions: @locked_update)

      assert io =~ "puts an optimistic lock on an attribute it projects as a `constant`"
    end
  end

  describe "accepted" do
    test "a lock on a mapped attribute" do
      probe =
        define(
          actions: @locked_update,
          mapping: "map :version_number, from: :id, read_only?: true"
        )

      assert :ok = VerifyOptimisticLock.verify(probe)
    end

    test "a constant nobody locks on" do
      assert :ok =
               VerifyOptimisticLock.verify(define(actions: "update :rename, accept: [:login]"))
    end

    test "a global lock that applies to no write the resource has" do
      probe = define(changes: "change optimistic_lock(:version_number), on: [:update]")

      assert :ok = VerifyOptimisticLock.verify(probe)
    end

    test "a hard destroy, which only filters on the attribute" do
      probe =
        define(
          actions: """
          destroy :remove do
            change optimistic_lock(:version_number)
          end
          """
        )

      assert :ok = VerifyOptimisticLock.verify(probe)
    end

    test "from :read_from_new the resource owns its table, and the attribute is stored" do
      probe = define(actions: @locked_update, phase: ":read_from_new")

      assert :ok = VerifyOptimisticLock.verify(probe)
    end

    test "a resource without a strangler block is left alone" do
      assert :ok = VerifyOptimisticLock.verify(AshStrangler.Test.Legacy.Users.spark_dsl_config())
    end
  end
end
