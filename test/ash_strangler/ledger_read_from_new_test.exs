# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.LedgerReadFromNewTest do
  @moduledoc """
  The v0.4.0 correction: `ledger?` is VALID in :read_from_new, and the ledger
  trigger follows the authoritative base storage -- the OWNED table -- for as
  long as any compatibility writer exists. Legacy writers through the reverse
  view fire no Ash notifier; the claim that Ash's own events cover writes past
  cutover is true only if every writer goes through Ash.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  defmodule Owned do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Resource]

    postgres do
      table "owned_ledger_v"
      schema "strangler"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
      attribute :login, :string, public?: true
      attribute :legacy_id, :integer, public?: true
    end

    actions do
      defaults [:read]
    end

    strangler do
      phase :read_from_new

      source AshStrangler.Test.Legacy.Users do
        notify? true
        ledger? true
        notify_channel "ash_strangler_owned_ledger_test"

        key :id,
          from: :id,
          strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

        map :login, from: :login
        map :legacy_id, from: :id
      end
    end
  end

  test "the ledger statements target the OWNED table in :read_from_new" do
    statements = AshStrangler.Sql.Ledger.build(Owned)

    trigger =
      Enum.find(statements, &(&1.name == :strangler_ledger_strangler_owned_ledger_v_trigger))

    assert trigger.up =~ ~s|AFTER INSERT OR UPDATE OR DELETE ON "strangler"."owned_ledger_v"|
    refute trigger.up =~ "ON \"legacy\".\"users\""
  end

  test "the migration composes ledger + reverse view in :read_from_new" do
    names =
      Owned
      |> AshStrangler.Migration.statements()
      |> Enum.map(& &1.name)

    assert :strangler_owned_ledger_v_reverse_view in names

    # and the ledger trigger rides along in this phase (v0.4.0 correction).
    assert :strangler_ledger_strangler_owned_ledger_v_trigger in names
  end

  test "VerifyLedger still refuses :decommissioned" do
    verifier = AshStrangler.Verifiers.VerifyLedger

    name =
      "AshStrangler.LedgerReadFromNewTest.Decommissioned#{System.unique_integer([:positive])}"

    {eval_result, _io} =
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
              table "decommissioned_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              uuid_primary_key :id
              attribute :login, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :decommissioned

              source AshStrangler.Test.Legacy.Users do
                notify? true
                ledger? true

                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                map :login, from: :login
              end
            end
          end
          """,
          [],
          file: "probe_decommissioned.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = eval_result

    assert {:error, error} = verifier.verify(module.spark_dsl_config())
    assert Exception.message(error) =~ "meaningless in phase :decommissioned"
  end
end
