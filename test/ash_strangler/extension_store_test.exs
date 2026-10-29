# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ExtensionStoreTest do
  @moduledoc """
  The extension store, against the real database: the generated DDL runs (the
  suite installs it verbatim at boot), the view `LEFT JOIN`s the table in, and
  the `INSTEAD OF` triggers keep it in step transactionally.

  The read that matters most is the *pre-existing legacy row*: it has no
  extension row at all, and it must read the declared default through
  `COALESCE` — not NULL, and not an error.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Test.ExtendedUser

  @extension_table ExtendedUser.extension_table()

  describe "the generated DDL" do
    test "creates the extension table keyed by the canonical key" do
      extension =
        ExtendedUser
        |> AshStrangler.Migration.statements()
        |> Enum.find(&(&1.name == :strangler_extended_users_extension))

      assert extension.up =~ ~s|CREATE TABLE IF NOT EXISTS "strangler"."extended_users_extension"|
      assert extension.up =~ ~s|"id" uuid NOT NULL PRIMARY KEY|
      assert extension.up =~ ~s|"notes" text|
      assert extension.up =~ ~s|"risk_score" bigint|
      assert extension.down =~ ~s|DROP TABLE IF EXISTS "strangler"."extended_users_extension"|
    end

    test "the view joins the extension table and reads the declared default" do
      view =
        ExtendedUser
        |> AshStrangler.Migration.statements()
        |> Enum.find(&(&1.name == :strangler_extended_users_view))

      assert view.up =~
               ~s|LEFT JOIN "strangler"."extended_users_extension" AS ext ON ext."id" = |

      # uuid_generate_v5, the same expression the id column is
      assert view.up =~ "uuid_generate_v5("
      assert view.up =~ ~s|coalesce(ext."notes", '') AS notes|
      assert view.up =~ ~s|ext."risk_score" AS risk_score|
    end

    test "any extension attribute forces the INSTEAD OF triggers" do
      assert AshStrangler.Info.writes(ExtendedUser) == :triggers
      assert AshStrangler.Mechanism.resource_mechanism(ExtendedUser) == :instead_of
    end
  end

  describe "reads" do
    test "a pre-existing legacy row reads the declared default, and NULL where none is declared" do
      legacy_id = insert_legacy_user!(login: "ext-pre-existing")

      record = Ash.get!(ExtendedUser, derived_id(legacy_id))

      assert record.notes == ""
      assert record.risk_score == nil
    end
  end

  describe "writes" do
    test "create writes the legacy row and always the extension row" do
      record =
        Ash.create!(ExtendedUser, %{login: "ext-created", email: "created@example.com"})

      %Postgrex.Result{rows: rows} =
        TestRepo.query!("SELECT login FROM legacy.users WHERE id = $1::bigint", [
          legacy_id_for(record.id)
        ])

      assert [%{"login" => "ext-created"}] = Enum.map(rows, &Map.new(Enum.zip(~w(login), &1)))

      %Postgrex.Result{rows: [[notes, risk_score]]} =
        TestRepo.query!("SELECT notes, risk_score FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      # The command supplied neither value. `risk_score` is NULL until first
      # written. `notes` the extension row holds as NULL too -- the column
      # list of the INSERT did not mention it -- and that is fine: the
      # canonical read is what the invariant is about, and the view projects
      # the declared default through COALESCE whether the extension row is
      # absent or merely NULL in that column.
      assert {notes, risk_score} == {nil, nil}

      assert Ash.get!(ExtendedUser, record.id).notes == ""
    end

    test "update writes both stores inside one transaction, and the extension write does not touch legacy columns" do
      legacy_id = insert_legacy_user!(login: "ext-update")
      record = Ash.get!(ExtendedUser, derived_id(legacy_id))

      Ash.update!(record, %{notes: "renegotiating", risk_score: 7})

      assert {%{"login" => "ext-update"}, {"renegotiating", 7}} =
               read_both_stores!(legacy_id, record.id)
    end

    test "the first update of a pre-existing legacy row inserts its extension row" do
      legacy_id = insert_legacy_user!(login: "ext-first-update")
      record = Ash.get!(ExtendedUser, derived_id(legacy_id))

      %Postgrex.Result{num_rows: 0} =
        TestRepo.query!("SELECT 1 FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      Ash.update!(record, %{notes: "late arrival"})

      %Postgrex.Result{rows: [[notes]]} =
        TestRepo.query!("SELECT notes FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert notes == "late arrival"
    end

    test "destroy removes both rows" do
      legacy_id = insert_legacy_user!(login: "ext-delete")
      record = Ash.get!(ExtendedUser, derived_id(legacy_id))

      Ash.update!(record, %{notes: "going away"})
      Ash.destroy!(record)

      %Postgrex.Result{num_rows: 0} =
        TestRepo.query!("SELECT 1 FROM #{@extension_table} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])

      assert {:error, _} = Ash.get(ExtendedUser, record.id)

      %Postgrex.Result{num_rows: 0} =
        TestRepo.query!("SELECT 1 FROM legacy.users WHERE id = $1", [legacy_id])
    end
  end

  # --- the verifier ------------------------------------------------------------

  describe "VerifyExtension" do
    defp verifier, do: AshStrangler.Verifiers.VerifyExtension

    test "refuses a second extension block" do
      probe =
        define(~s|
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
          attribute :login, :string, public?: true
            attribute :notes, :string, public?: true
            attribute :risk_score, :integer, public?: true
          end

          strangler do
            phase :dual_write

            source AshStrangler.Test.Legacy.Users do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
              map :login, from: :login
              extension [:notes]
              extension [:risk_score]
            end
          end
        |)

      assert {:error, error} = verifier().verify(probe)
      assert Exception.message(error) =~ "2 `extension` blocks on one source"
    end

    test "refuses an extension attribute something else accounts for" do
      probe =
        define(~s|
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
          attribute :login, :string, public?: true
            attribute :notes, :string, public?: true
          end

          strangler do
            phase :dual_write

            source AshStrangler.Test.Legacy.Users do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
              map :login, from: :login
              map :notes, from: :salt
              extension [:notes]
            end
          end
        |)

      assert {:error, error} = verifier().verify(probe)
      message = Exception.message(error)

      assert message =~ "extension attribute :notes"
      assert message =~ "already accounted for"
    end

    test "refuses an extension attribute that does not exist on the resource" do
      probe =
        define(~s|
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
            attribute :login, :string, public?: true
          end

          strangler do
            phase :dual_write

            source AshStrangler.Test.Legacy.Users do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
              map :login, from: :login
              extension [:nonexistent]
            end
          end
        |)

      assert {:error, error} = verifier().verify(probe)
      assert Exception.message(error) =~ ":nonexistent is not an attribute"
    end

    test "refuses a function default on an extension attribute" do
      probe =
        define(~s|
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
          attribute :login, :string, public?: true
            attribute :notes, :string, public?: true, default: &Ash.UUID.generate/0
          end

          strangler do
            phase :dual_write

            source AshStrangler.Test.Legacy.Users do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
              map :login, from: :login
              extension [:notes]
            end
          end
        |)

      assert {:error, error} = verifier().verify(probe)
      message = Exception.message(error)

      assert message =~ "extension :notes declares a function default"
      assert message =~ "a different value every time"
    end

    test "refuses the extension table past cutover" do
      probe =
        define(~s|
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
          attribute :login, :string, public?: true
            attribute :notes, :string, public?: true
          end

          strangler do
            phase :read_from_new

            source AshStrangler.Test.Legacy.Users do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
              map :login, from: :login
              extension [:notes]
            end
          end
        |)

      assert {:error, error} = verifier().verify(probe)
      message = Exception.message(error)

      assert message =~ "phase :read_from_new owns a real table"
      assert message =~ "fold extension columns into"
      assert message =~ "before cutover"
    end
  end

  # --- harness -----------------------------------------------------------------

  defp define(body) do
    name = "AshStrangler.ExtensionStoreTest.Probe#{System.unique_integer([:positive])}"

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
            table "extension_probe"
            schema "verified"
            repo AshStrangler.TestRepo
            migrate? false
          end

          actions do
            defaults [:read]
          end

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end

  # The legacy id behind a canonical id, read off the view's `__legacy_id`
  # column -- raw SQL, so the assertion cannot be satisfied by the same path
  # the code under test uses.
  defp legacy_id_for(canonical_id) do
    %Postgrex.Result{rows: [[legacy_id]]} =
      TestRepo.query!(
        "SELECT __legacy_id FROM strangler.extended_users WHERE id = $1",
        [Ecto.UUID.dump!(canonical_id)]
      )

    legacy_id
  end

  defp read_both_stores!(legacy_id, canonical_id) do
    %Postgrex.Result{rows: [[login]]} =
      TestRepo.query!("SELECT login FROM legacy.users WHERE id = $1", [legacy_id])

    %Postgrex.Result{rows: [[notes, risk_score]]} =
      TestRepo.query!("SELECT notes, risk_score FROM #{@extension_table} WHERE id = $1", [
        Ecto.UUID.dump!(canonical_id)
      ])

    {%{"login" => login}, {notes, risk_score}}
  end
end
