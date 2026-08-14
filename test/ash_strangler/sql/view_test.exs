defmodule AshStrangler.Sql.ViewTestRepo do
  @moduledoc """
  Compile-only Ecto repo for `AshStrangler.Sql.ViewTest`.

  Generating SQL from a `strangler` mapping needs a `postgres do repo end` to
  exist and compile -- `Spark.Dsl.Transformer.build_entity/4` validates against
  the target extension's schema, and the schema requires it -- but it never
  needs to connect. No test here starts this repo or touches a database.
  """
  use AshPostgres.Repo, otp_app: :ash_strangler, warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule AshStrangler.Sql.ViewTest.UuidV5User do
  @moduledoc """
  The plan's §5.1 worked example, trimmed to what a golden-SQL test needs:
  one plain mapping, one computed read-only mapping, one constant, one
  unmapped attribute, and a `{:uuid_v5, ...}` key -- so the index-generation
  path is covered too.
  """

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "users"
    schema "strangler"
    repo AshStrangler.Sql.ViewTestRepo
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :full_name, :string, public?: true
    attribute :organization_id, :uuid, public?: true
    attribute :created_by_id, :uuid, public?: true
  end

  strangler do
    phase :read_from_legacy

    source "legacy.users" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :email, "email", cast: :citext

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong."
      end

      constant :organization_id, "'00000000-0000-0000-0000-0000000000fe'::uuid"

      unmapped [:created_by_id], as: :null, because: "No provenance for pre-migration rows."
    end
  end
end

defmodule AshStrangler.Sql.ViewTest.IdentityKeyThing do
  @moduledoc "Covers the `:identity` key strategy: no derived-expression index."

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "things"
    repo AshStrangler.Sql.ViewTestRepo
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :name, :string, public?: true
  end

  strangler do
    phase :read_from_legacy

    source "legacy.things" do
      key :id, from: "row_uuid", strategy: :identity
      map :name, "name"
    end
  end
end

defmodule AshStrangler.Sql.ViewTest do
  @moduledoc """
  Golden-SQL tests (§8.2 of the plan: DSL in, SQL out, checked as a fixture) --
  no database, no live connection. These exercise `AshStrangler.Sql.View`
  directly and, separately, confirm the transformer actually lands the
  statements in `[:postgres, :custom_statements]` where `mix ash.codegen` will
  find them.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshStrangler.Sql.ViewTest.{IdentityKeyThing, UuidV5User}

  describe "build/1, {:uuid_v5, ...} key" do
    setup do
      {:ok, result: AshStrangler.Sql.View.build(UuidV5User)}
    end

    test "the view selects every attribute plus __legacy_id, derives the key, and reads from the legacy relation",
         %{result: result} do
      assert result.view.name == :strangler_users_view

      assert result.view.up == """
             CREATE OR REPLACE VIEW "strangler"."users" AS
             SELECT
               uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text) AS id,
               id AS __legacy_id,
               (email)::citext AS email,
               coalesce(first_name,'') || ' ' || coalesce(last_name,'') AS full_name,
               '00000000-0000-0000-0000-0000000000fe'::uuid AS organization_id,
               NULL AS created_by_id
             FROM legacy.users;
             """
    end

    test "down drops the view, schema-qualified", %{result: result} do
      assert result.view.down == ~S(DROP VIEW IF EXISTS "strangler"."users";)
    end

    test "the uuid_v5 key derives an expression index, schema-qualified in both directions", %{
      result: result
    } do
      assert result.key_index.name == :strangler_users_key_index

      assert result.key_index.up == """
             CREATE INDEX IF NOT EXISTS strangler_users_key_idx ON legacy.users
               (uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text));
             """

      assert result.key_index.down == "DROP INDEX IF EXISTS legacy.strangler_users_key_idx;"
    end
  end

  describe "build/1, :identity key" do
    test "no expression index is generated -- the legacy column is used unchanged" do
      result = AshStrangler.Sql.View.build(IdentityKeyThing)

      assert result.key_index == nil

      assert result.view.up == """
             CREATE OR REPLACE VIEW "public"."things" AS
             SELECT
               row_uuid::uuid AS id,
               row_uuid AS __legacy_id,
               name AS name
             FROM legacy.things;
             """
    end
  end

  describe "the DeriveStatements transformer, incomplete mappings" do
    test "fails the resource's own compilation, naming the unmapped attribute" do
      # Unlike AshStrangler's verifiers (which run in a separate process after
      # compilation and only fail a build under --warnings-as-errors -- see
      # AshStrangler.VerifiersTest's moduledoc), a *transformer* returning
      # `{:error, ...}` raises synchronously as part of compiling the
      # `defmodule` itself. There is no partial view to emit, so this fails
      # loudly and immediately rather than deferring to VerifyCompleteMapping.
      assert_raise Spark.Error.DslError, ~r/:mystery/, fn ->
        define_resource!("""
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :mystery, :string, public?: true
        end

        strangler do
          phase :read_from_legacy

          source "legacy.widgets" do
            key :id, from: "id", strategy: :identity
          end
        end
        """)
      end
    end
  end

  describe "the DeriveStatements transformer" do
    test "lands the view and index in [:postgres, :custom_statements]" do
      names =
        UuidV5User
        |> AshPostgres.DataLayer.Info.custom_statements()
        |> Enum.map(& &1.name)

      assert :strangler_users_view in names
      assert :strangler_users_key_index in names
    end

    test "does not touch custom_statements for a resource with the extension but no strangler mapping" do
      resource =
        define_resource!("""
        attributes do
          uuid_primary_key :id
        end
        """)

      assert AshPostgres.DataLayer.Info.custom_statements(resource) == []
    end
  end

  defp define_resource!(body) do
    name = "AshStranglerViewTest#{System.unique_integer([:positive])}"

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
            table "#{String.downcase(name)}"
            repo AshStrangler.Sql.ViewTestRepo
          end

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module
  end
end
