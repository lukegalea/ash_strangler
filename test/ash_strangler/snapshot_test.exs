# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.SnapshotTest do
  @moduledoc """
  The snapshot pipeline against a real server: derive, verify (G-SNAP),
  capture and drift (G-DRIFT).

  Every database here is a scratch one created from `template0` and dropped
  afterwards, so nothing touches the shared test schema and nothing needs the
  sandbox. The fixture in `test/fixtures/snapshot/clinic` is committed with the
  catalog and lock `derive/3` produced, which is what the reproduction tests
  hold the code to.
  """

  # Serial: the task tests set the global Mix shell.
  use ExUnit.Case, async: false

  alias AshStrangler.Snapshot
  alias AshStrangler.Snapshot.Catalog

  @fixture "test/fixtures/snapshot/clinic"

  defp config, do: AshStrangler.TestRepo.config()

  defp copy_fixture(tmp_dir, files \\ ~w(extensions.sql schema.sql catalog.json lock.json)) do
    for file <- files, do: File.cp!(Path.join(@fixture, file), Path.join(tmp_dir, file))
    tmp_dir
  end

  defp execute(config, statements) do
    Snapshot.with_connection(config, fn conn ->
      Enum.each(statements, &Postgrex.query!(conn, &1, []))
    end)
  end

  describe "normalise/1" do
    test "drops psql meta-commands and version lines, and makes CREATE SCHEMA idempotent" do
      dump = """
      --
      -- PostgreSQL database dump
      --

      \\restrict Ppivc32Yn3IB8V2NEBCdv2n9yx

      -- Dumped from database version 18.6
      -- Dumped by pg_dump version 18.6

      CREATE SCHEMA public;
      CREATE SCHEMA IF NOT EXISTS clinic;

      \\unrestrict Ppivc32Yn3IB8V2NEBCdv2n9yx

      """

      normalised = Snapshot.normalise(dump)

      refute normalised =~ "restrict"
      refute normalised =~ "Dumped"
      assert normalised =~ "CREATE SCHEMA IF NOT EXISTS public;"
      assert normalised =~ "CREATE SCHEMA IF NOT EXISTS clinic;"
      refute normalised =~ "IF NOT EXISTS IF NOT EXISTS"
      assert String.ends_with?(normalised, ";\n")
      assert Snapshot.normalise(normalised) == normalised
    end
  end

  describe "derive/3" do
    @tag :tmp_dir
    test "reproduces the committed catalog byte for byte, and locks every file", %{tmp_dir: dir} do
      copy_fixture(dir, ~w(extensions.sql schema.sql))

      assert {:ok, lock} =
               Snapshot.derive(dir, config(), schemas: ["clinic"], heads: %{"app" => "003"})

      assert File.read!(Path.join(dir, "catalog.json")) ==
               File.read!(Path.join(@fixture, "catalog.json"))

      assert lock["schemas"] == ["clinic"]
      assert lock["heads"] == %{"app" => %{"head" => "003", "count" => nil}}
      assert Map.keys(lock["files"]) == ~w(catalog.json extensions.sql schema.sql)
      assert lock["derived_on"] =~ "PostgreSQL"
    end

    test "the catalog records what the verifiers and the drift gate need" do
      {:ok, catalog} = Snapshot.read_catalog(Path.join(@fixture, "catalog.json"))

      # Extension placement is a fact of the catalog, not of the machine.
      assert catalog["extensions"] == %{"citext" => "clinic"}
      assert catalog["enums"] == %{"clinic.visit_kind" => ["checkup", "urgent", "follow_up"]}
      assert %{"udt" => "pg_catalog.text"} = catalog["domains"]["clinic.postcode"]

      patients = catalog["relations"]["clinic.patients"]
      columns = Map.new(patients["columns"], &{&1["name"], &1})

      assert patients["kind"] == "table"

      assert Enum.map(patients["columns"], & &1["name"]) ==
               ~w(id email full_name status postcode tags password_digest location created_at)

      assert columns["email"]["type"] == "clinic.citext"
      assert columns["tags"]["array"] == true
      assert columns["status"]["default"] == "'active'::text"
      assert patients["primary_key"]["columns"] == ["id"]

      assert [%{"name" => "patients_status_check", "values" => ["active", "archived"]}] =
               patients["checks"]

      assert [
               %{"name" => "patients_active_name_index", "predicate" => predicate},
               %{"name" => "patients_email_index", "columns" => ["email"], "predicate" => nil}
             ] = patients["unique"]

      assert predicate =~ "active"

      visits = catalog["relations"]["clinic.visits"]

      assert [%{"references" => %{"relation" => "clinic.patients"}, "on_delete" => "cascade"}] =
               visits["foreign_keys"]

      assert %{"identity" => "by_default"} = hd(visits["columns"])
    end
  end

  describe "verify/2 (G-SNAP)" do
    test "passes on the committed fixture" do
      assert Snapshot.verify(@fixture, config()) == :ok
    end

    @tag :tmp_dir
    test "refuses a schema.sql edited after the lock", %{tmp_dir: dir} do
      copy_fixture(dir)
      File.write!(Path.join(dir, "schema.sql"), "-- edited\n", [:append])

      assert {:error, problems} = Snapshot.verify(dir, config())
      assert "schema.sql does not match its hash in the lock" in problems
    end

    @tag :tmp_dir
    test "refuses a catalog that was edited by hand, even with its hash updated", %{tmp_dir: dir} do
      copy_fixture(dir)
      catalog_path = Path.join(dir, "catalog.json")

      edited =
        catalog_path
        |> File.read!()
        |> String.replace(
          ~s("name": "full_name",\n          "not_null": true),
          ~s("name": "full_name",\n          "not_null": false)
        )

      refute edited == File.read!(catalog_path)
      File.write!(catalog_path, edited)

      # Re-hash it into the lock, as a careless author would.
      lock = Path.join(dir, "lock.json")
      {:ok, decoded} = Snapshot.read_lock(dir)
      hash = :sha256 |> :crypto.hash(edited) |> Base.encode16(case: :lower)
      File.write!(lock, Catalog.encode(put_in(decoded, ["files", "catalog.json"], hash)))

      assert {:error, [problem]} = Snapshot.verify(dir, config())
      assert problem =~ "column clinic.patients.full_name changed"
    end
  end

  describe "capture/3" do
    @tag :tmp_dir
    test "a capture of the loaded fixture derives the same catalog, with heads read from the database",
         %{tmp_dir: dir} do
      copy_fixture(dir, ~w(extensions.sql))

      Snapshot.with_scratch_database(config(), fn source ->
        :ok = Snapshot.load(@fixture, source)

        execute(source, [
          "CREATE SCHEMA meta",
          "CREATE TABLE meta.migrations (name text)",
          "INSERT INTO meta.migrations VALUES ('001_init'), ('002_visits'), ('003_rooms')"
        ])

        assert {:ok, lock} =
                 Snapshot.capture(dir, source,
                   schemas: ["clinic"],
                   head_from: %{"app" => "meta.migrations.name"}
                 )

        assert lock["heads"] == %{"app" => %{"head" => "003_rooms", "count" => 3}}
        assert lock["captured"]["pg_dump"] =~ "pg_dump"
        assert lock["captured"]["server"]
      end)

      schema = File.read!(Path.join(dir, "schema.sql"))
      refute schema =~ "\\restrict"
      assert schema =~ "CREATE SCHEMA IF NOT EXISTS clinic;"
      refute File.exists?(Path.join(dir, ".schema.sql.raw"))

      assert File.read!(Path.join(dir, "catalog.json")) ==
               File.read!(Path.join(@fixture, "catalog.json"))
    end
  end

  describe "drift/3 (G-DRIFT)" do
    test "a database built from the snapshot has no drift, and every kind of change is named" do
      Snapshot.with_scratch_database(config(), fn live ->
        :ok = Snapshot.load(@fixture, live)

        assert {:ok, %{differences: [], allowed: []}} = Snapshot.drift(@fixture, live)

        execute(live, [
          "ALTER TABLE clinic.visits ADD COLUMN cost numeric",
          "ALTER TABLE clinic.patients ALTER COLUMN full_name TYPE varchar(200)",
          "ALTER TABLE clinic.visits ALTER COLUMN notes SET NOT NULL",
          "ALTER TABLE clinic.patients DROP COLUMN tags",
          "CREATE VIEW clinic.open_visits AS SELECT id FROM clinic.visits",
          "CREATE TABLE clinic.audit_log (id integer)",
          "ALTER TYPE clinic.visit_kind ADD VALUE 'remote'",
          "ALTER EXTENSION citext SET SCHEMA public",
          # This package's own triggers are the strangle, not drift.
          "CREATE FUNCTION clinic.noop() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NULL; END'",
          "CREATE TRIGGER strangler_watch_clinic_visits AFTER INSERT ON clinic.visits " <>
            "FOR EACH ROW EXECUTE FUNCTION clinic.noop()"
        ])

        assert {:ok, report} = Snapshot.drift(@fixture, live, ["relation clinic.audit_*"])

        assert Enum.map(report.allowed, & &1.id) == ["relation clinic.audit_log"]

        by_id = Map.new(report.differences, &{&1.id, &1})

        assert %{change: :removed} = by_id["extension citext"]

        assert %{change: :changed, locked: ~w(checkup urgent follow_up)} =
                 by_id["enum clinic.visit_kind"]

        assert %{change: :added, live: %{"kind" => "view"}} = by_id["relation clinic.open_visits"]
        assert %{change: :added} = by_id["column clinic.visits.cost"]
        assert %{change: :removed} = by_id["column clinic.patients.tags"]
        # The extension moved, so the column's printed type moved with it.
        assert %{change: :changed} = by_id["column clinic.patients.email"]

        assert Snapshot.describe(by_id["column clinic.patients.full_name"]) =~
                 ~s|type "text" -> "character varying(200)"|

        assert Snapshot.describe(by_id["column clinic.visits.notes"]) =~ "not_null false -> true"
        refute Enum.any?(report.differences, &String.starts_with?(&1.id, "trigger"))
      end)
    end
  end

  describe "mix ash_strangler.snapshot" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    @tag :tmp_dir
    test "derive then verify, through the task and a --url", %{tmp_dir: dir} do
      copy_fixture(dir, ~w(extensions.sql schema.sql))
      c = config()

      url =
        "postgres://#{c[:username]}:#{c[:password]}@#{c[:hostname]}:#{c[:port]}/#{c[:database]}"

      Mix.Task.rerun("ash_strangler.snapshot", ["derive", dir, "--schema", "clinic", "--url", url])

      assert_received {:mix_shell, :info, [written]}
      assert written == "#{dir}: catalog and lock written (3 files hashed)"

      Mix.Task.rerun("ash_strangler.snapshot", ["verify", dir, "--url", url])
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "lock, files and catalog agree"

      File.write!(Path.join(dir, "schema.sql"), "-- edited\n", [:append])

      assert catch_exit(Mix.Task.rerun("ash_strangler.snapshot", ["verify", dir, "--url", url])) ==
               {:shutdown, 1}

      assert_received {:mix_shell, :error, [_problem]}
    end
  end
end
