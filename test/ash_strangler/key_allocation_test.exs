# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.KeyAllocationTest do
  @moduledoc """
  Who allocates the key when the *host* creates a row — both directions,
  proven against the real database where a row is actually created.

  `{:uuid_v5, ...}`: the legacy sequence allocates, and the canonical id is
  derived from what it picked — asserted here by comparing `Ash.create!`'s
  returned id against `AshStrangler.KeyDerivation` computing the same uuid in
  Elixir, over the legacy id the row actually carries.

  `:identity`: the host mints, and the INSERT trigger passes `NEW.<pk>` into
  the legacy key column — asserted at the generated-SQL level, because the
  end-to-end identity case is the Contract fixture's (a legacy relation whose
  key is already a uuid), which lands with the shared-rows fixtures.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Sql.Triggers
  alias AshStrangler.Test.{ExtendedUser, LegacyUser}

  describe "uuid_v5: the legacy side allocates" do
    test "a host create is valid in both key spaces" do
      record = Ash.create!(ExtendedUser, %{login: "key-allocated", email: "k@example.com"})

      %Postgrex.Result{rows: [[legacy_id]]} =
        TestRepo.query!(
          "SELECT __legacy_id FROM strangler.extended_users WHERE id = $1",
          [Ecto.UUID.dump!(record.id)]
        )

      # The Elixir side derives the same uuid the view does -- this is the
      # SQL/Elixir agreement property, exercised on a row the host created
      # rather than one the legacy application wrote.
      assert record.id ==
               AshStrangler.KeyDerivation.uuid_v5(
                 ExtendedUser.namespace(),
                 AshStrangler.KeyDerivation.name("legacy.users", legacy_id)
               )
    end

    test "the insert trigger re-reads through the view, so the returned record carries the derived id" do
      record = Ash.create!(ExtendedUser, %{login: "key-returned"})

      # An Ash.get by the derived id finding the row IS the re-select proof:
      # the trigger returned NEW projected from the view, and the id it named
      # is the one the view computes for the stored legacy row.
      assert %{} = Ash.get!(ExtendedUser, record.id) |> Map.from_struct()
      assert Ash.get!(LegacyUser, record.id).login == "key-returned"
    end
  end

  describe "identity: the host mints" do
    test "the INSERT trigger passes the minted key into the legacy key column" do
      [insert_function | _] =
        Triggers.build(AshStrangler.KeyAllocationTest.IdentityKeyProbe)
        |> Enum.filter(&(&1.name == :strangler_identity_probe_insert_function))

      assert insert_function.up =~ "(id, login)"
      assert insert_function.up =~ "VALUES (NEW.id, NEW.login)"
    end

    test "update and delete still key off __legacy_id" do
      statements = Triggers.build(AshStrangler.KeyAllocationTest.IdentityKeyProbe)
      update = Enum.find(statements, &(&1.name == :strangler_identity_probe_update_function))
      delete = Enum.find(statements, &(&1.name == :strangler_identity_probe_delete_function))

      assert update.up =~ "WHERE id = OLD.__legacy_id"
      assert delete.up =~ "WHERE id = OLD.__legacy_id"
      refute update.up =~ "NEW.id"
    end
  end

  describe "VerifyKeyAllocation" do
    defp verifier, do: AshStrangler.Verifiers.VerifyKeyAllocation

    test "accepts creates with writes :auto and a derived key when the id is not sent" do
      # Measured against PostgreSQL: an INSERT that omits the expression column
      # is accepted, the legacy sequence allocates, and RETURNING projects the
      # derived id. The refusal is only for creates that SEND an id.
      probe = define(~s|
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :login, :string, public?: true
        end

        actions do
          defaults [:read]
          create :create
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
            map :login, from: :login
          end
        end
      |)

      assert :ok = verifier().verify(probe)
    end

    test "refuses creates with writes :auto and a derived key when the id is sent" do
      probe = define(~s|
        attributes do
          uuid_primary_key :id
          attribute :login, :string, public?: true
        end

        actions do
          defaults [:read]
          create :create
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Test.Legacy.Users do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
            map :login, from: :login
          end
        end
      |)

      assert {:error, error} = verifier().verify(probe)
      message = Exception.message(error)

      assert message =~
               "create needs writes: :triggers so the legacy sequence allocates the key"

      assert message =~ "an auto-updatable view cannot insert through a derived id"
    end

    test "accepts creates with writes :auto and a derived key when nothing creates" do
      probe = define(~s|
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
      |)

      assert :ok = verifier().verify(probe)
    end

    test "accepts creates with a derived key once writes are triggers" do
      probe = define(~s|
        attributes do
          uuid_primary_key :id
          attribute :login, :string, public?: true
        end

        actions do
          defaults [:read]
          create :create
        end

        strangler do
          phase :dual_write

          source AshStrangler.Test.Legacy.Users do
            writes :triggers

            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
            map :login, from: :login
          end
        end
      |)

      assert :ok = verifier().verify(probe)
    end

    test "refuses an :identity key the host cannot mint" do
      probe = define(~s|
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :login, :string, public?: true
        end

        actions do
          defaults [:read]
          create :create
        end

        strangler do
          phase :dual_write

          source AshStrangler.Test.Legacy.Users do
            writes :triggers

            key :id, from: :id, strategy: :identity
            map :login, from: :login
          end
        end
      |)

      assert {:error, error} = verifier().verify(probe)
      message = Exception.message(error)

      assert message =~ ":identity` needs a key the host can mint on create"
      assert message =~ "neither a default nor `writable?`"
      assert message =~ "attribute :id, :uuid, default: &Ash.UUID.generate/0"
    end

    test "accepts an :identity key with a default" do
      probe = define(~s|
        attributes do
          attribute :id, :uuid,
            primary_key?: true,
            allow_nil?: false,
            default: &Ash.UUID.generate/0

          attribute :login, :string, public?: true
        end

        actions do
          defaults [:read]
          create :create
        end

        strangler do
          phase :dual_write

          source AshStrangler.Test.Legacy.Users do
            writes :triggers

            key :id, from: :id, strategy: :identity
            map :login, from: :login
          end
        end
      |)

      assert :ok = verifier().verify(probe)
    end
  end

  # --- harness -----------------------------------------------------------------

  defmodule IdentityKeyProbe do
    @moduledoc """
    `:identity` key over `legacy.users`, triggers forced with `writes:
    :triggers` — the shapes the generated INSERT is asserted against. Not
    installed: `legacy.users` keys are bigints, so an :identity uuid mapping
    over it is a declaration for SQL-shaped assertions only, never a row.
    """
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Resource]

    postgres do
      table "identity_probe"
      schema "verified"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :uuid,
        primary_key?: true,
        allow_nil?: false,
        default: &Ash.UUID.generate/0

      attribute :login, :string, public?: true
    end

    actions do
      defaults [:read]
      default_accept [:login]

      create :create do
        primary? true
      end
    end

    strangler do
      phase :dual_write

      source AshStrangler.Test.Legacy.Users do
        writes :triggers

        key :id, from: :id, strategy: :identity
        map :login, from: :login
      end
    end
  end

  defp define(body) do
    name = "AshStrangler.KeyAllocationTest.Probe#{System.unique_integer([:positive])}"

    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string("""
        defmodule #{name} do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshStrangler.Resource]

          postgres do
            table "allocation_probe"
            schema "verified"
            repo AshStrangler.TestRepo
            migrate? false
          end

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end
end
