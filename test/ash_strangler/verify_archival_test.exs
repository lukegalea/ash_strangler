# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyArchivalTest do
  @moduledoc "The archival verifier: mapped-or-refused, over the real extension."

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defp verifier, do: AshStrangler.Verifiers.VerifyArchival

  defp define(body) do
    name = "AshStrangler.VerifyArchivalTest.Probe#{System.unique_integer([:positive])}"

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
                extensions: [AshStrangler.Resource, AshArchival.Resource]

              postgres do
                table "archival_probe_v"
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

              #{body}
            end
            """,
            [],
            file: "probe_archival.ex"
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

  @positive ~S|
    attributes do
      attribute :archived_at, :utc_datetime_usec, public?: true
    end

    strangler do
      phase :read_from_legacy

      source AshStrangler.Test.Legacy.Users do
        key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
        map :login, from: :login
        map :archived_at, from: :deleted_at, zone: "UTC"
      end
    end
  |

  test "accepts the archive attribute mapped onto the legacy encoding" do
    assert :ok = verifier().verify(define(@positive))
  end

  test "refuses an archive attribute nothing accounts for" do
    probe = define(~S|
      attributes do
        attribute :archived_at, :utc_datetime_usec, public?: true
      end

      strangler do
        phase :read_from_legacy

        source AshStrangler.Test.Legacy.Users do
          key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
          map :login, from: :login
          unmapped [:archived_at], as: :null, because: "No archival for pre-migration rows."
        end
      end
    |)

    # `unmapped` is accounted-for at the completeness level, but it has no
    # write direction: AshArchival's set would write NULL where the resource
    # promises a timestamp. The extension store is refused by the same rule
    # (no legacy lifecycle answer); the honest shape is a writable mapping.
    assert {:error, error} = verifier().verify(probe)
    assert Exception.message(error) =~ "archival has no legacy representation"
    assert Exception.message(error) =~ "or refuse archival on this resource"
  end

  test "leaves resources without archival alone" do
    # The helper's template hard-codes AshArchival; this probe omits it.
    name = "AshStrangler.VerifyArchivalTest.NoArchival#{System.unique_integer([:positive])}"

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
              table "no_archival_v"
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
              phase :read_from_legacy

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                map :login, from: :login
              end
            end
          end
          """,
          [],
          file: "probe_no_archival.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = eval_result

    assert :ok = verifier().verify(module.spark_dsl_config())
  end
end
