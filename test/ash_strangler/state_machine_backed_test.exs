# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.StateMachineBackedTest do
  @moduledoc """
  The machine over a shared row is only as sound as the collapse beneath it:
  one answer to "what state is this?", every machine state covered, and no
  transition targeting a state no write can store.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp verifier, do: AshStrangler.Verifiers.VerifyStateMachineBacked

  @key ~S|key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}|

  # `machine` is resource-level DSL; `source_body` is the mapping inside the
  # source block — the collapse macro imports there and nowhere else.
  # `status_one_of` must be EXACTLY the machine's state set:
  # ash_state_machine's AddState transformer enforces the attribute's one_of
  # against the machine rather than deriving it.
  defp define(machine, source_body, status_one_of, opts \\ []) do
    name = "AshStrangler.StateMachineBackedTest.Probe#{System.unique_integer([:positive])}"

    {eval_result, io} =
      with_io(:stderr, fn ->
        try do
          Code.eval_string(
            """
            defmodule #{name} do
              use Ash.Resource,
                domain: nil,
                validate_domain_inclusion?: false,
                data_layer: AshPostgres.DataLayer,
                extensions: [AshStrangler.Resource, AshStateMachine]

              postgres do
                table "machine_probe_v"
                schema "verified"
                repo AshStrangler.TestRepo
                migrate? false
              end

              attributes do
                attribute :id, :uuid, primary_key?: true, allow_nil?: false
                attribute :login, :string, public?: true
                attribute :status, :atom do
                  public? true
                  allow_nil? false
                  default #{inspect(Keyword.get(opts, :default, :draft))}
                  constraints one_of: #{inspect(status_one_of)}
                end

                attribute :other_state, :atom do
                  public? true
                  allow_nil? false
                  default :draft
                  constraints one_of: [:draft, :archived]
                end
              end

              actions do
                defaults [:read]
              end

              #{machine}

              strangler do
                phase :dual_write

                source AshStrangler.Test.Legacy.Users do
                  #{@key}
                  map :login, from: :login

                  #{source_body}
                end
              end
            end
            """,
            [],
            file: "probe_machine.ex"
          )
        rescue
          e -> {:raised, Exception.format(:error, e)}
        end
      end)

    case eval_result do
      {{:module, module, _, _}, _binding} ->
        module.spark_dsl_config()

      {:raised, formatted} ->
        flunk("probe failed to compile:\n#{formatted}\ncompiler output:\n#{io}")
    end
  end

  @machine ~S"""
  state_machine do
    initial_states [:draft]
    default_initial_state :draft
    state_attribute :status

    transitions do
      transition :archive, from: :draft, to: :archived
    end
  end
  """

  @covered_collapse ~S"""
  collapse :status do
    hit_policy :first

    state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]
    state :draft, when: :otherwise, set: [deleted_at: nil]
  end
  """

  test "accepts a machine whose collapse covers every state" do
    assert :ok = verifier().verify(define(@machine, @covered_collapse, [:draft, :archived]))
  end

  test "refuses a non-collapse mapping of the state attribute" do
    probe =
      define(
        ~S"""
        state_machine do
          initial_states [:draft]
          default_initial_state :draft
          state_attribute :status

          transitions do
            transition :archive, from: :draft, to: :archived
          end
        end
        """,
        ~S"""
        map :status, from: :state
        """,
        [:draft, :archived]
      )

    assert {:error, error} = verifier().verify(probe)
    message = Exception.message(error)

    assert message =~ "the state attribute is mapped as AshStrangler.Map"
    assert message =~ ~s|two answers to "what state is this?" is a bug|
  end

  test "refuses a machine state with no collapse clause" do
    probe =
      define(
        ~S"""
        state_machine do
          initial_states [:draft]
          default_initial_state :draft
          state_attribute :status
          extra_states [:cancelled]

          transitions do
            transition :archive, from: :draft, to: :archived
          end
        end
        """,
        @covered_collapse,
        [:archived, :cancelled, :draft]
      )

    assert {:error, error} = verifier().verify(probe)
    assert Exception.message(error) =~ ":cancelled"
  end

  test "allows a transition targeting a refused state -- the abort IS the answer" do
    probe =
      define(
        ~S"""
        state_machine do
          initial_states [:draft]
          default_initial_state :draft
          state_attribute :status

          transitions do
            transition :cancel, from: :draft, to: :cancelled
          end
        end
        """,
        ~S"""
        collapse :status do
          hit_policy :first

          state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]

          state :cancelled,
            representation: {:refuse, reason: "no cancelled encoding in legacy.users"}

          state :draft, when: :otherwise, set: [deleted_at: nil]
        end
        """,
        [:cancelled, :draft]
      )

    # The command COMPILES: the refusal is delivered at runtime by the
    # trigger's P0001 with the declared reason -- that is what a refused
    # state means. (The Contract fixture's cancel test proves the runtime
    # half against the real database.)
    assert :ok = verifier().verify(probe)
  end

  test "refuses a transition targeting a derived state" do
    probe =
      define(
        ~S"""
        state_machine do
          initial_states [:draft]
          default_initial_state :draft
          state_attribute :status

          transitions do
            transition :archive, from: :draft, to: :archived
            transition :expire, from: :draft, to: :expired
          end
        end
        """,
        ~S"""
        collapse :status do
          hit_policy :first

          state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]
          state :expired, when: expr(is_nil(salt)), derived: true
          state :draft, when: :otherwise, set: [deleted_at: nil]
        end
        """,
        [:draft, :archived, :expired]
      )

    assert {:error, error} = verifier().verify(probe)
    message = Exception.message(error)

    assert message =~ "transition :expire [:draft] -> :expired"
    assert message =~ "a derived target could never stick"
  end

  test "refuses a refused initial state" do
    probe =
      define(
        ~S"""
        state_machine do
          initial_states [:cancelled]
          default_initial_state :cancelled
          state_attribute :status

          transitions do
            transition :archive, from: :cancelled, to: :archived
          end
        end
        """,
        ~S"""
        collapse :status do
          hit_policy :first

          state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]

          state :cancelled,
            representation: {:refuse, reason: "no cancelled encoding in legacy.users"}

          state :draft, when: :otherwise, set: [deleted_at: nil]
        end
        """,
        [:archived, :cancelled],
        default: :cancelled
      )

    assert {:error, error} = verifier().verify(probe)
    message = Exception.message(error)

    assert message =~ ":cancelled is an initial state and a refused one"
  end

  test "leaves machines whose state attribute is not strangler-mapped alone" do
    probe =
      define(
        ~S"""
        state_machine do
          initial_states [:draft]
          default_initial_state :draft
          state_attribute :other_state

          transitions do
            transition :archive, from: :draft, to: :archived
          end
        end
        """,
        ~S"""
        unmapped [:other_state], as: :null, because: "Not the strangler's business."
        """,
        [:draft, :archived]
      )

    # `:other_state` carries the machine but no strangler mapping: the
    # machine is not backed by shared rows at all, and the strangler's word
    # ends where its mapping does.
    assert :ok = verifier().verify(probe)
  end
end
