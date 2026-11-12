# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TwinSnapshotTest.Clinic do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
    resource AshStrangler.TwinSnapshotTest.Shop.Accounts
  end
end

defmodule AshStrangler.TwinSnapshotTest.Shop.Accounts do
  @moduledoc "A twin with a secret, a watch and a ledgered resource over it."
  use Ash.Resource,
    domain: AshStrangler.TwinSnapshotTest.Clinic,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "shop"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    secrets [:pin]
    watch "shop_accounts_changed"
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.TwinSnapshotTest.Account do
  @moduledoc "A ledgered resource over the shop twin."
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "accounts"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.TwinSnapshotTest.Shop.Accounts do
      notify? true
      ledger? true
      notify_channel "shop_accounts_ledger"

      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
      map :login, from: :login
    end
  end
end

defmodule AshStrangler.TwinSnapshotTest do
  @moduledoc """
  The twin side of the snapshot: generation from a catalog, V-SNAPSHOT,
  secret omission, V-LEDGER, ledger failure isolation and the watch trigger.

  Verifier failures are printed by the parallel checker rather than raised
  (see `AshStrangler.VerifiersTest`), so the negative cases compile a probe
  and call the verifier over its `spark_dsl_config/0`.
  """

  # Serial: compiling the probes swaps the global :standard_error device to
  # keep the parallel checker's verifier warnings out of the output, and an
  # async test capturing stderr at the same moment would read them.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Snapshot
  alias AshStrangler.TwinSnapshotTest.{Account, Clinic}
  alias AshStrangler.TwinSnapshotTest.Shop.Accounts

  alias AshStrangler.Verifiers.{
    VerifyLedger,
    VerifySecrets,
    VerifySnapshot,
    VerifyTwin,
    VerifyWatch
  }

  @catalog_path "test/fixtures/snapshot/clinic/catalog.json"

  setup_all do
    {:ok, catalog} = Snapshot.read_catalog(@catalog_path)
    %{catalog: catalog}
  end

  # Twins rendered for one probe share its namespace, so a foreign key from
  # `<probe>.Visits` resolves to `<probe>.Patients`.
  defp render(catalog, relation, module, overrides \\ %{}) do
    patients =
      module |> Module.split() |> Enum.drop(-1) |> Kernel.++(["Patients"]) |> Module.concat()

    AshStrangler.Twin.Generator.render(
      Map.merge(
        %{
          relation: relation,
          schema: relation |> String.split(".") |> hd(),
          table: relation |> String.split(".") |> List.last(),
          catalog: catalog,
          module: module,
          domain: Clinic,
          repo: AshStrangler.TestRepo,
          destination: fn
            "clinic.patients" -> patients
            _ -> nil
          end,
          secrets: ["password_digest"],
          snapshot: @catalog_path,
          watch: nil,
          command: " --test"
        },
        overrides
      )
    )
  end

  defp probe_name,
    do:
      Module.concat([AshStrangler.TwinSnapshotTest, "Probe#{System.unique_integer([:positive])}"])

  # Compiles `source` and returns the module, keeping the parallel checker's
  # printed verifier warnings out of the test output.
  defp compile(source) do
    {result, _output} =
      with_io(:stderr, fn ->
        Code.compile_string(source) |> Enum.map(&elem(&1, 0)) |> List.last()
      end)

    result
  end

  defp rejection(verifier, module) do
    case verifier.verify(module.spark_dsl_config()) do
      {:error, error} -> Exception.message(error)
      other -> flunk("#{inspect(verifier)} accepted #{inspect(module)}: #{inspect(other)}")
    end
  end

  describe "gen.twin --from-snapshot (AshStrangler.Twin.Generator)" do
    test "writes twins that V-SNAPSHOT accepts, typed from the catalog alone", %{catalog: catalog} do
      base = probe_name()
      patients = compile(render(catalog, "clinic.patients", Module.concat(base, Patients)))

      visits =
        compile(render(catalog, "clinic.visits", Module.concat(base, Visits), %{secrets: []}))

      assert VerifySnapshot.verify(patients.spark_dsl_config()) == :ok
      assert VerifySnapshot.verify(visits.spark_dsl_config()) == :ok
      assert VerifySecrets.verify(patients.spark_dsl_config()) == :ok

      attribute = &Ash.Resource.Info.attribute/2

      assert Ash.Resource.Info.primary_key(patients) == [:id]
      assert attribute.(patients, :email).type == Ash.Type.CiString
      assert attribute.(patients, :email).allow_nil? == false
      assert attribute.(patients, :status).constraints[:one_of] == [:active, :archived]
      assert attribute.(patients, :postcode).type == Ash.Type.String
      assert attribute.(patients, :tags).type == {:array, Ash.Type.String}
      assert attribute.(patients, :created_at).type == Ash.Type.NaiveDatetime

      # The secret is gone, and so is the column with no Ash type.
      refute attribute.(patients, :password_digest)
      refute attribute.(patients, :location)
      assert AshStrangler.Twin.secrets(patients) == ["password_digest"]

      # A partial unique index makes a column unique among some rows, which is
      # not what an identity claims.
      assert Enum.map(Ash.Resource.Info.identities(patients), & &1.name) == [
               :patients_email_index
             ]

      assert attribute.(visits, :kind).constraints[:one_of] == [:checkup, :urgent, :follow_up]
      assert attribute.(visits, :room).source == :Room
      assert %{destination: ^patients} = Ash.Resource.Info.relationship(visits, :patient)

      # The catalog is an external resource, so a new capture recompiles the twin.
      assert @catalog_path in List.flatten(
               Keyword.get_values(patients.__info__(:attributes), :external_resource)
             )
    end
  end

  describe "gen.twin output a host can keep without repair" do
    test "two keys to one table get two relationships, named from their attributes", %{
      catalog: catalog
    } do
      catalog =
        update_in(catalog, ["relations", "clinic.visits"], fn visits ->
          [patient] = Enum.filter(visits["columns"], &(&1["name"] == "patient_id"))
          [key] = visits["foreign_keys"]

          extra =
            for column <- ~w(referringPatientId billedPatientId) do
              {%{patient | "name" => column, "not_null" => false},
               %{key | "name" => "visits_#{column}_fkey", "columns" => [column]}}
            end

          visits
          |> Map.update!("columns", &(&1 ++ Enum.map(extra, fn {column, _} -> column end)))
          |> Map.update!("foreign_keys", &(&1 ++ Enum.map(extra, fn {_, fk} -> fk end)))
        end)

      source = render(catalog, "clinic.visits", probe_name(), %{secrets: []})

      assert source =~ "belongs_to :patient, "
      assert source =~ "belongs_to :referring_patient, "
      assert source =~ "belongs_to :billed_patient, "
    end

    test "an unparsed CHECK is quoted in lines short enough for a line-length check", %{
      catalog: catalog
    } do
      values = Enum.map_join(1..12, ", ", &"'value_number_#{&1}'::text")

      catalog =
        update_in(catalog, ["relations", "clinic.patients", "checks"], fn [check] ->
          [
            %{
              check
              | "values" => nil,
                "definition" => "CHECK (((status IS NULL) OR (status = ANY (ARRAY[#{values}]))))"
            }
          ]
        end)

      source = render(catalog, "clinic.patients", probe_name())

      assert source =~ "did not parse"
      assert source =~ "'value_number_12'::text]))))"
      # Comments, which a line-length check reads; strings and heredocs it skips.
      comments = source |> String.split("\n") |> Enum.filter(&(String.trim(&1) =~ ~r/^#/))
      assert Enum.filter(comments, &(String.length(&1) > 98)) == []
    end
  end

  describe "V-SNAPSHOT" do
    test "names every column a hand edit made disagree with the catalog", %{catalog: catalog} do
      module = probe_name()
      source = render(catalog, "clinic.patients", module)

      broken =
        source
        |> String.replace("attribute :email, :ci_string,", "attribute :email, :string,")
        |> String.replace(
          "attribute :full_name, :string, allow_nil?: false,",
          "attribute :full_name, :string,"
        )
        |> String.replace(
          "constraints one_of: [:active, :archived]",
          "constraints one_of: [:active]"
        )
        |> String.replace(~r/\n\s*attribute :tags, .*\n/, "\n")
        |> String.replace(
          "attribute :created_at,",
          "attribute :nickname, :string, public?: true\n    attribute :created_at,"
        )

      refute broken == source
      message = rejection(VerifySnapshot, compile(broken))

      assert message =~ "`email`: the catalog's type gives :ci_string"
      assert message =~ "`full_name`: the catalog says NOT NULL"
      assert message =~ "`status`: the catalog's value set is [\"active\", \"archived\"]"
      assert message =~ "`tags`: the catalog has it (text[]); the twin does not declare it"
      assert message =~ "`nickname`: the twin declares it; the catalog has no such column"
      assert message =~ "mix ash_strangler.gen.twin --from-snapshot #{@catalog_path}"
    end

    @tag :tmp_dir
    test "editing a column's type in the catalog breaks the twin, naming the column",
         %{catalog: catalog, tmp_dir: dir} do
      edited =
        put_in(
          catalog,
          ["relations", "clinic.patients", "columns"],
          Enum.map(
            catalog["relations"]["clinic.patients"]["columns"],
            fn
              %{"name" => "full_name"} = column ->
                %{column | "type" => "integer", "udt" => "pg_catalog.int4"}

              column ->
                column
            end
          )
        )

      path = Path.join(dir, "catalog.json")
      File.write!(path, Snapshot.Catalog.encode(edited))

      twin = compile(render(catalog, "clinic.patients", probe_name(), %{snapshot: path}))
      message = rejection(VerifySnapshot, twin)

      assert message =~
               "`full_name`: the catalog's type gives :integer; the twin declares Ash.Type.String"

      refute message =~ "`email`"
    end

    test "refuses a relation, or a secret, the catalog does not have", %{catalog: catalog} do
      missing =
        render(catalog, "clinic.patients", probe_name())
        |> String.replace(~s(table "patients"), ~s(table "invoices"))

      assert rejection(VerifySnapshot, compile(missing)) =~ "has no relation `clinic.invoices`"

      secret =
        render(catalog, "clinic.patients", probe_name(), %{secrets: ["password_digest", "pin"]})

      assert rejection(VerifySnapshot, compile(secret)) =~
               "`pin`: declared secret, but the catalog has no such column"
    end
  end

  describe "secrets" do
    test "a twin may not carry a column it declares secret", %{catalog: catalog} do
      source =
        catalog
        |> render("clinic.patients", probe_name())
        |> String.replace("secrets [:password_digest]", "secrets [:password_digest, :full_name]")

      assert rejection(VerifySecrets, compile(source)) =~
               "`full_name` is declared secret and is also an attribute"
    end

    test "a mapping that names a secret column fails to compile" do
      module = probe_name()

      source = """
      defmodule #{inspect(module)} do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Resource]

        postgres do
          table "accounts_v"
          schema "strangler"
          repo AshStrangler.TestRepo
          migrate? false
        end

        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :login, :string, public?: true
          attribute :pin, :string, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_legacy

          source #{inspect(Accounts)} do
            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
            map :login, from: :login
            map :pin, from: :pin
          end
        end
      end
      """

      message = rejection(VerifyTwin, compile(source))
      assert message =~ "`pin` is declared secret on #{inspect(Accounts)}"
    end
  end

  describe "V-LEDGER" do
    test "the row image is the twin's columns, so the secret is not in it" do
      assert AshStrangler.Sql.Ledger.image_columns(Account) == ["id", "login"]
      assert VerifyLedger.verify(Account.spark_dsl_config()) == :ok

      function =
        Enum.find(
          AshStrangler.Sql.Ledger.build(Account),
          &(&1.name == :strangler_ledger_shop_accounts_function)
        )

      refute function.up =~ "pin"
      refute function.up =~ "to_jsonb"
    end

    test "refuses a ledger whose image would include a declared secret" do
      module = probe_name()

      # In :read_from_new the image is the resource's own columns, and one of
      # them carries the legacy secret's name.
      source = """
      defmodule #{inspect(module)} do
        use Ash.Resource,
          domain: nil,
          validate_domain_inclusion?: false,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Resource]

        postgres do
          table "accounts_owned"
          schema "strangler"
          repo AshStrangler.TestRepo
          migrate? false
        end

        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :login, :string, public?: true
          attribute :pin, :string, public?: true
        end

        actions do
          defaults [:read]
        end

        strangler do
          phase :read_from_new

          source #{inspect(Accounts)} do
            notify? true
            ledger? true

            key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
            map :login, from: :login
            unmapped [:pin], because: "new in this application"
          end
        end
      end
      """

      assert rejection(VerifyLedger, compile(source)) =~ "would include `pin`"
    end
  end

  describe "trigger failure isolation and the watch trigger, on a real server" do
    @table """
    CREATE TABLE shop.accounts (id bigserial PRIMARY KEY, login text NOT NULL, pin text)
    """

    test "a dropped ledger table does not abort the legacy insert, and the image holds no secret" do
      Snapshot.with_scratch_database(AshStrangler.TestRepo.config(), fn config ->
        Snapshot.with_connection(config, fn conn ->
          query = &Postgrex.query!(conn, &1, [])
          query.("CREATE SCHEMA shop")
          query.(@table)
          Enum.each(AshStrangler.Sql.Ledger.build(Account), &query.(&1.up))

          query.("INSERT INTO shop.accounts (login, pin) VALUES ('ada', '1234')")
          %{rows: [[new_row]]} = query.("SELECT new_row FROM legacy_change_events")
          assert new_row == %{"id" => 1, "login" => "ada"}

          query.("DROP TABLE legacy_change_events")

          {:ok, %{num_rows: 1}} =
            Postgrex.query(
              conn,
              "INSERT INTO shop.accounts (login, pin) VALUES ('grace', '5678')",
              []
            )

          assert %{rows: [[2]]} = query.("SELECT count(*) FROM shop.accounts")
        end)
      end)
    end

    test "a column the image names, renamed or dropped by the legacy schema, does not abort its writes" do
      Snapshot.with_scratch_database(AshStrangler.TestRepo.config(), fn config ->
        Snapshot.with_connection(config, fn conn ->
          query = &Postgrex.query!(conn, &1, [])
          query.("CREATE SCHEMA shop")
          query.(@table)
          Enum.each(AshStrangler.Sql.Ledger.build(Account), &query.(&1.up))
          query.("INSERT INTO shop.accounts (login, pin) VALUES ('ada', '1234')")

          query.("ALTER TABLE shop.accounts RENAME COLUMN login TO username")

          for statement <- [
                "INSERT INTO shop.accounts (username, pin) VALUES ('grace', '5678')",
                "UPDATE shop.accounts SET pin = '0000' WHERE id = 1",
                "DELETE FROM shop.accounts WHERE id = 2"
              ] do
            assert {:ok, %{num_rows: 1}} = Postgrex.query(conn, statement, [])
          end

          query.("ALTER TABLE shop.accounts DROP COLUMN username")

          assert {:ok, %{num_rows: 1}} =
                   Postgrex.query(conn, "UPDATE shop.accounts SET pin = '1'", [])

          assert %{rows: [[1]]} = query.("SELECT count(*) FROM legacy_change_events")
        end)
      end)
    end

    test "a watched twin notifies its key, and only its key, on its own channel" do
      [function, trigger] = AshStrangler.Sql.Watch.build(Accounts)
      assert function.name == :strangler_watch_shop_accounts_function
      # An ordinary column is spelled as this function always spelled it.
      assert function.up =~ ~s|json_build_object('id', affected."id")|
      assert trigger.up =~ ~s(AFTER INSERT OR UPDATE OR DELETE ON "shop"."accounts")
      assert Accounts in AshStrangler.Migration.resources([Clinic])
      assert AshStrangler.Migration.statements(Accounts) == [function, trigger]

      Snapshot.with_scratch_database(AshStrangler.TestRepo.config(), fn config ->
        Snapshot.with_connection(config, fn conn ->
          query = &Postgrex.query!(conn, &1, [])
          query.("CREATE SCHEMA shop")
          query.(@table)
          query.(function.up)
          query.(trigger.up)

          {:ok, listener} = Postgrex.Notifications.start_link(Keyword.drop(config, [:pool]))
          {:ok, _ref} = Postgrex.Notifications.listen(listener, "shop_accounts_changed")

          query.("INSERT INTO shop.accounts (login, pin) VALUES ('ada', '1234')")
          assert_receive {:notification, ^listener, _ref, "shop_accounts_changed", payload}, 2_000

          assert Jason.decode!(payload) ==
                   %{"relation" => "shop.accounts", "op" => "insert", "key" => %{"id" => 1}}

          GenServer.stop(listener)
        end)
      end)
    end

    test "a watch needs a primary key" do
      module = probe_name()

      source = """
      defmodule #{inspect(module)} do
        use Ash.Resource,
          domain: #{inspect(Clinic)},
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Twin]

        postgres do
          table "log"
          schema "shop"
          repo AshStrangler.TestRepo
          migrate? false
        end

        twin do
          watch "shop_log"
        end

        attributes do
          attribute :line, :string, public?: true
        end

        actions do
          defaults [:read]
        end
      end
      """

      assert rejection(VerifyWatch, compile(source)) =~ "`watch` needs a primary key"
    end
  end
end
