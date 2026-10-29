# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.RepresentationTest.LifecycleProbe do
  @moduledoc """
  One collapse carrying all four answers to "what about a state the legacy
  schema cannot represent?": an extension state, a refuse state, a lossy
  state, and a derived state — plus the two legacy-encoded states the
  fixture's other tests exercise.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "lifecycle_probe_v"
    schema "verified"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :notes, :string, public?: true, default: ""

    attribute :lifecycle_state, :atom do
      public? true
      constraints one_of: [:negotiating, :archived, :expired, :cancelled, :ready, :draft]
    end
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      map :login, from: :login

      extension([:notes])

      collapse :lifecycle_state do
        hit_policy :first

        state :negotiating, representation: {:extension, :lifecycle_state}
        state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]
        state :expired, when: expr(is_nil(salt)), derived: true

        state :cancelled,
          representation: {:refuse, reason: "no cancelled encoding in legacy.users"}

        state :ready,
          representation: {:lossy, to: :draft, loss: "terms finalised but not executed"}

        state :draft, when: :otherwise, set: [deleted_at: nil]
      end
    end
  end
end

defmodule AshStrangler.RepresentationTest do
  @moduledoc """
  The four declared answers for unrepresentable states, at the generated-SQL
  level: what the view reads, what the trigger writes, what it refuses, and
  what the obligations stop flagging once a declaration exists.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @probe AshStrangler.RepresentationTest.LifecycleProbe

  describe "the generated SQL" do
    test "the extension table gains the implicit state column, typed by the attribute" do
      extension =
        @probe
        |> AshStrangler.Migration.statements()
        |> Enum.find(&(&1.name == :strangler_lifecycle_probe_v_extension))

      assert extension.up =~ ~s|"notes" text|
      assert extension.up =~ ~s|"lifecycle_state" text|
    end

    test "the forward CASE reads the extension state first, then the guards, never refuse or lossy" do
      view = AshStrangler.Sql.View.build(@probe)

      ext_pos =
        String.split(view.view.up, ~s|ext."lifecycle_state" = 'negotiating'|)
        |> hd()
        |> String.length()

      archived_pos =
        String.split(view.view.up, "deleted_at IS NOT NULL") |> hd() |> String.length()

      assert ext_pos < archived_pos
      refute view.view.up =~ "'cancelled'"
      refute view.view.up =~ "'ready'"
      # derived IS forward-producible
      assert view.view.up =~ "'expired'"
    end

    test "the update trigger holds legacy columns for the extension state and refuses the unrepresentable" do
      update =
        @probe
        |> AshStrangler.Sql.Triggers.build()
        |> Enum.find(&(&1.name == :strangler_lifecycle_probe_v_update_function))

      # extension state: hold the stored legacy value on UPDATE
      assert update.up =~ "WHEN 'negotiating' THEN deleted_at"
      # lossy: the arm applies the `to:` state's set values (draft -> NULL)
      assert update.up =~ "WHEN 'ready' THEN NULL"
      # refuse + derived raise before anything is written
      assert update.up =~
               "strangler: state :cancelled is unrepresentable in legacy"

      assert update.up =~ "USING ERRCODE = 'P0001'"
      assert update.up =~ "a derived state is a function of the legacy data"
      # the refuse state gets no backward arm
      refute update.up =~ "WHEN 'cancelled' THEN"
    end

    test "on INSERT the extension state's hold renders the fallback assignment" do
      insert =
        @probe
        |> AshStrangler.Sql.Triggers.build()
        |> Enum.find(&(&1.name == :strangler_lifecycle_probe_v_insert_function))

      # draft's deleted_at is NULL: a newly created row in an extension state
      # stores the fresh-row flags, not a derivation from a row that does not
      # exist.
      assert insert.up =~ "WHEN 'negotiating' THEN NULL"
    end

    test "the extension upsert keeps the state column in step" do
      update =
        @probe
        |> AshStrangler.Sql.Triggers.build()
        |> Enum.find(&(&1.name == :strangler_lifecycle_probe_v_update_function))

      assert update.up =~
               ~s|"lifecycle_state" = (CASE NEW.lifecycle_state WHEN 'negotiating' THEN 'negotiating' ELSE NULL END)|
    end
  end

  describe "the obligations" do
    test "declared states are exempt from surjectivity" do
      flags =
        @probe
        |> AshStrangler.Obligations.check()
        |> Enum.filter(&(&1.obligation == :surjectivity))

      # :negotiating, :cancelled, :ready and :expired are all declared answers;
      # none of them is "a clause somebody meant to write".
      assert flags == []
    end
  end

  describe "VerifyCollapseRepresentation" do
    defp verifier, do: AshStrangler.Verifiers.VerifyCollapseRepresentation

    test "refuses an extension state with no extension block" do
      probe =
        define(
          ~s|
        attribute :status, :atom do
          public? true
          constraints one_of: [:on, :off]
        end
      |,
          ~S/
        collapse :status do
          hit_policy :first

          state :on, representation: {:extension, :status}
          state :off, when: :otherwise, set: [deleted_at: nil]
        end
      /
        )

      assert {:error, error} = verifier().verify(probe)
      assert Exception.message(error) =~ "no `extension` block"
    end

    test "refuses a derived state without a when or with a set" do
      probe =
        define(
          ~s|
        attribute :status, :atom do
          public? true
          constraints one_of: [:on, :off]
        end
      |,
          ~S/
        extension [:notes]

        collapse :status do
          hit_policy :first

          state :on, derived: true
          state :off, when: :otherwise, set: [deleted_at: nil]
        end
      /
        )

      assert {:error, error} = verifier().verify(probe)
      assert Exception.message(error) =~ "derived state :on requires a `when:`"
    end

    test "refuses a lossy state whose to: names no state" do
      probe =
        define(
          ~s|
        attribute :status, :atom do
          public? true
          constraints one_of: [:on, :off, :ready]
        end
      |,
          ~S/
        extension [:notes]

        collapse :status do
          hit_policy :first

          state :ready, representation: {:lossy, to: :nonexistent, loss: "gone"}
          state :off, when: :otherwise, set: [deleted_at: nil]
        end
      /
        )

      assert {:error, error} = verifier().verify(probe)
      assert Exception.message(error) =~ "names no state of this table"
    end

    test "refuses a represented state with a when or a set" do
      probe =
        define(
          ~s|
        attribute :status, :atom do
          public? true
          constraints one_of: [:on, :off]
        end
      |,
          ~S/
        extension [:notes]

        collapse :status do
          hit_policy :first

          state :on,
            when: expr(is_nil(salt)),
            representation: {:refuse, reason: "no encoding"}

          state :off, when: :otherwise, set: [deleted_at: nil]
        end
      /
        )

      assert {:error, error} = verifier().verify(probe)
      assert Exception.message(error) =~ "takes no `when:`"
    end

    test "accepts the fully-declared table" do
      assert :ok = verifier().verify(@probe.spark_dsl_config())
    end
  end

  # --- harness -----------------------------------------------------------------

  defp define(attrs, collapse) do
    name = "AshStrangler.RepresentationTest.Probe#{System.unique_integer([:positive])}"

    {result, _io} =
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
              table "representation_probe_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false
              attribute :login, :string, public?: true
              attribute :notes, :string, public?: true
              #{attrs}
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :dual_write

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                map :login, from: :login

                #{collapse}
              end
            end
          end
          """,
          [],
          file: "probe_representation.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end
end
