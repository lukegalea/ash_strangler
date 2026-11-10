# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.OwnSourceNamesRuntimeTest do
  @moduledoc """
  The failure `VerifyOwnSourceNames` moves to compile time, reproduced at runtime.

  A resource whose `heading` carries `source: :heading_col` still compiles (the
  verifier only reports, here), its view is generated with a column named `heading`,
  and the first read asks Postgres for `heading_col`. Without this the refusal
  would rest on a reading of the code; with it the premise is measured.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Migration

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  test "the view carries the attribute's name and Ash reads the source: name" do
    name = "AshStrangler.OwnSourceNamesRuntimeTest.Probe#{System.unique_integer([:positive])}"

    {result, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Code.eval_string(
          """
          defmodule #{name}Domain do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource #{name}
            end
          end

          defmodule #{name} do
            use Ash.Resource,
              domain: #{name}Domain,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "own_source_runtime_v"
              schema "legacy"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              uuid_primary_key :id
              attribute :login, :string, public?: true, source: :login_col
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :read_from_legacy

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "#{@namespace}"}
                map :login, from: :login
              end
            end
          end
          """,
          [],
          file: "probe_own_source_runtime.ex"
        )
      end)

    {{:module, probe, _, _}, _binding} = result

    for statement <- Migration.statements(probe), do: TestRepo.query!(statement.up, [])

    insert_legacy_user!(%{login: "ada"})

    assert %{rows: [["ada"]]} =
             TestRepo.query!(~s|SELECT login FROM legacy.own_source_runtime_v|, [])

    assert {:error, error} = Ash.read(probe)
    assert Exception.message(error) =~ "login_col"
    assert Exception.message(error) =~ "does not exist"
  end
end
