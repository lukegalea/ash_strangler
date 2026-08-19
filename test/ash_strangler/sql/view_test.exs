# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

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

defmodule AshStrangler.Sql.ViewTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Sql.ViewTest.Legacy.Users
    resource AshStrangler.Sql.ViewTest.Legacy.Things
  end
end

defmodule AshStrangler.Sql.ViewTest.Legacy.Users do
  @moduledoc """
  The twin the golden-SQL fixture maps.

  Declaring it is what makes the generated SQL derivable at all: `email`'s
  `(email)::citext` comes from comparing this `:string` against the resource's
  `:ci_string`, and `first_name`/`last_name` resolve to real columns rather than
  to identifiers a regex found in a string.
  """
  use Ash.Resource,
    domain: AshStrangler.Sql.ViewTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "users"
    schema "legacy"
    repo AshStrangler.Sql.ViewTestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :email, :string
    attribute :first_name, :string
    attribute :last_name, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Sql.ViewTest.Legacy.Things do
  @moduledoc "A twin whose key is already a uuid, so no derivation is needed."
  use Ash.Resource,
    domain: AshStrangler.Sql.ViewTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "things"
    schema "legacy"
    repo AshStrangler.Sql.ViewTestRepo
    migrate? false
  end

  attributes do
    attribute :row_uuid, :uuid, primary_key?: true, allow_nil?: false
    attribute :name, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Sql.ViewTest.UuidV5User do
  @moduledoc """
  The worked example, trimmed to what a golden-SQL test needs: one plain
  mapping, one computed read-only mapping, one constant, one unmapped attribute,
  and a `{:uuid_v5, ...}` key -- so the index-generation path is covered too.
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

    source AshStrangler.Sql.ViewTest.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      # No `cast:`. The `::citext` in the golden SQL below is DERIVED from the
      # twin's `:string` against this resource's `:ci_string`.
      map :email, from: :email

      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong."

      constant :organization_id, expr(type("00000000-0000-0000-0000-0000000000fe", :uuid))

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

    source AshStrangler.Sql.ViewTest.Legacy.Things do
      key :id, from: :row_uuid, strategy: :identity
      map :name, from: :name
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
               (coalesce(first_name, '') || (' ' || coalesce(last_name, ''))) AS full_name,
               ('00000000-0000-0000-0000-0000000000fe')::uuid AS organization_id,
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

  describe "incomplete mappings" do
    test "building the view raises, naming every attribute with no legacy source" do
      # Where this surfaces changed when the custom_statements path was
      # removed. It used to raise while compiling the `defmodule`, because a
      # transformer returning `{:error, ...}` does that. Now generation happens
      # in `mix ash_strangler.gen.migration`, so the failure lands there --
      # still before any SQL reaches a database, which is what matters.
      #
      # This is deliberately STRICTER than VerifyCompleteMapping, which exempts
      # private attributes: a view's SELECT list has no such exemption.
      resource =
        define_resource!("""
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :mystery, :string, public?: false
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Sql.ViewTest.Legacy.Things do
            key :id, from: :row_uuid, strategy: :identity
          end
        end
        """)

      assert_raise ArgumentError, ~r/:mystery/, fn ->
        AshStrangler.Migration.statements(resource)
      end
    end

    test "a PUBLIC unmapped attribute is still caught at compile time by the verifier" do
      resource =
        define_resource!("""
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :mystery, :string, public?: true
        end

        strangler do
          phase :read_from_legacy

          source AshStrangler.Sql.ViewTest.Legacy.Things do
            key :id, from: :row_uuid, strategy: :identity
          end
        end
        """)

      assert {:error, error} =
               AshStrangler.Verifiers.VerifyCompleteMapping.verify(resource.spark_dsl_config())

      assert Exception.message(error) =~ ":mystery"
    end
  end

  describe "AshStrangler.Migration.statements/1" do
    test "orders the schema before the view before its key index, so a migration runs top to bottom" do
      names = UuidV5User |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      assert names == [
               :strangler_strangler_schema,
               :strangler_users_view,
               :strangler_users_key_index
             ]
    end

    test "creates the schema the view is declared in" do
      # Nothing did, before. Every test in this repository creates `strangler`
      # by hand in its setup (test/support/legacy_schema.ex), so the suite could
      # not see that a generated migration run against a fresh database failed
      # on its first statement with ERROR 3F000 (invalid_schema_name).
      [schema | _] = AshStrangler.Migration.statements(UuidV5User)

      assert schema.up == ~s(CREATE SCHEMA IF NOT EXISTS "strangler";)
    end

    test "the schema down drops it only once it holds nothing" do
      # `DROP SCHEMA ... RESTRICT` raises on a non-empty schema rather than
      # declining, and CASCADE would take another resource's view with it. So
      # the drop is guarded by a check for any remaining relation or function.
      [schema | _] = AshStrangler.Migration.statements(UuidV5User)

      assert schema.down =~ "pg_class"
      assert schema.down =~ "pg_proc"
      assert schema.down =~ ~s(DROP SCHEMA IF EXISTS "strangler")
      refute schema.down =~ "CASCADE"
    end

    test "no schema statement for a view living in public, which always exists" do
      refute Enum.any?(
               AshStrangler.Migration.statements(IdentityKeyThing),
               &(&1.name == :strangler_public_schema)
             )
    end

    test "returns nothing for a resource with the extension but no strangler mapping" do
      resource =
        define_resource!("""
        attributes do
          uuid_primary_key :id
        end
        """)

      assert AshStrangler.Migration.statements(resource) == []
    end

    test "emits no custom_statements at all -- that path provably cannot work" do
      # Recorded as a test because it was tried and shipped before being
      # disproved. `migrate? true` makes ash.codegen emit a `create table` for
      # the view's own name, so the view DDL then fails against it; `migrate?
      # false` stops the resource producing a snapshot, and custom_statements
      # are only read from snapshots. There is no setting in between, so the
      # DDL goes through mix ash_strangler.gen.migration instead.
      assert AshPostgres.DataLayer.Info.custom_statements(UuidV5User) == []
    end

    test "every statement is a single SQL command" do
      # Ecto sends a migration's execute/1 string on the extended protocol,
      # which rejects multiple commands with 42601. A statement carrying both a
      # CREATE FUNCTION and its CREATE TRIGGER fails at migrate time, so this
      # asserts the property rather than trusting it.
      for statement <- AshStrangler.Migration.statements(UuidV5User) do
        refute statement.up |> String.trim_trailing() |> String.trim_trailing(";") =~ ";",
               "#{statement.name} up carries more than one command:\n#{statement.up}"
      end
    end
  end

  describe "AshStrangler.Migration.render/2" do
    test "the rendered migration parses without a single compiler warning" do
      # Every SQL line used to sit at column 0 inside a heredoc whose closing
      # delimiter was indented, which Elixir 1.18 reports as "The current
      # heredoc line is indented too little" -- once per statement, on every
      # generated migration. A generated file that warns is unusable under
      # --warnings-as-errors and teaches people to scroll past warnings.
      source = AshStrangler.Migration.render("Elixir.RenderedMigrationTest", [UuidV5User])

      {_ast, stderr} = with_io(:stderr, fn -> Code.string_to_quoted!(source) end)

      assert stderr == "", "rendering emitted compiler diagnostics:\n#{stderr}"
    end

    test "the indentation the heredoc strips leaves the SQL byte-identical" do
      source = AshStrangler.Migration.render("Elixir.RenderedMigrationTest", [UuidV5User])
      {:ok, ast} = Code.string_to_quoted(source)

      executed =
        ast
        |> Macro.prewalk([], fn
          {:execute, _, [sql]} = node, acc when is_binary(sql) -> {node, [sql | acc]}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      statements = AshStrangler.Migration.statements(UuidV5User)

      expected =
        Enum.map(statements, &String.trim(&1.up)) ++ Enum.map(statements, &String.trim(&1.down))

      assert Enum.sort(Enum.map(executed, &String.trim/1)) == Enum.sort(expected)
    end

    test "resources sharing a schema emit one CREATE SCHEMA between them" do
      source =
        AshStrangler.Migration.render("Elixir.RenderedMigrationTest", [UuidV5User, UuidV5User])

      assert source |> String.split("CREATE SCHEMA") |> length() == 2
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
