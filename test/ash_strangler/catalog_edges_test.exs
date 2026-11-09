# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.CatalogEdgesTest do
  @moduledoc """
  The catalog at its edges: constraints that look like an `IN` list and are
  not, constraints that exist and do not hold yet, and the strangle's own
  objects, which are never drift and never part of a capture.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.Snapshot
  alias AshStrangler.Snapshot.{Catalog, Types}

  defp config, do: AshStrangler.TestRepo.config()

  defp introspect(statements) do
    Snapshot.with_scratch_database(config(), fn scratch ->
      Snapshot.with_connection(scratch, fn conn ->
        Enum.each(["CREATE SCHEMA s" | statements], &Postgrex.query!(conn, &1, []))
        Catalog.introspect(conn, ["s"])
      end)
    end)
  end

  defp server_version do
    Snapshot.with_connection(config(), fn conn ->
      %{rows: [[version]]} = Postgrex.query!(conn, "SHOW server_version_num", [])
      String.to_integer(version)
    end)
  end

  describe "an IN-list value set is read only from a constraint that is nothing else" do
    test "the plain and the varchar shapes yield their values" do
      assert Types.check_values(
               "CHECK ((state = ANY (ARRAY['open'::text, 'closed'::text])))",
               "state"
             ) == {:ok, ["open", "closed"]}

      assert Types.check_values(
               "CHECK (((state)::text = ANY ((ARRAY['a, b'::character varying, " <>
                 "'it''s'::character varying])::text[])))",
               "state"
             ) == {:ok, ["a, b", "it's"]}

      assert Types.check_values(
               "CHECK (((state)::text = ANY (ARRAY[('open'::character varying)::text, " <>
                 "('closed'::character varying)::text])))",
               "state"
             ) == {:ok, ["open", "closed"]}

      assert Types.check_values("CHECK ((state = 'only'::text))", "state") == {:ok, ["only"]}
    end

    test "a value set combined with anything else is not one" do
      for definition <- [
            "CHECK (((state = ANY (ARRAY['open'::text, 'closed'::text])) OR (state ~~ 'custom:%'::text)))",
            "CHECK (((state = ANY (ARRAY['open'::text, 'closed'::text])) AND (state <> 'closed'::text)))",
            "CHECK ((state = ANY (ARRAY['open'::text, 'closed'::text]))) NOT VALID",
            "CHECK (((state IS NULL) OR (state = ANY (ARRAY['open'::text]))))"
          ] do
        assert Types.check_values(definition, "state") == :error, definition
      end
    end

    test "drift sees a CHECK narrowed by a clause beside its IN list" do
      locked =
        introspect([
          "CREATE TABLE s.t (state text CONSTRAINT state_ok CHECK (state IN ('open', 'closed')))"
        ])

      live =
        introspect([
          "CREATE TABLE s.t (state text CONSTRAINT state_ok " <>
            "CHECK (state IN ('open', 'closed') AND state <> 'closed'))"
        ])

      assert [%{id: "check s.t.state_ok", change: :changed}] = Catalog.diff(locked, live)
      assert [%{"values" => nil}] = live["relations"]["s.t"]["checks"]
    end
  end

  test "a domain's NOT NULL is its not_null, not one of its checks" do
    catalog = introspect(["CREATE DOMAIN s.code AS text NOT NULL CHECK (VALUE <> '')"])

    assert %{"not_null" => true, "checks" => [%{"name" => "code_check"}]} =
             catalog["domains"]["s.code"]
  end

  test "a NOT NULL that is NOT VALID does not hold, so the column is nullable and the constraint is named" do
    if server_version() >= 180_000 do
      catalog =
        introspect([
          "CREATE TABLE s.t (id int PRIMARY KEY, a int)",
          "INSERT INTO s.t VALUES (2, NULL)",
          "ALTER TABLE s.t ADD CONSTRAINT nn NOT NULL a NOT VALID"
        ])

      relation = catalog["relations"]["s.t"]

      assert %{"name" => "a", "not_null" => false} =
               Enum.find(relation["columns"], &(&1["name"] == "a"))

      assert [%{"name" => "nn", "columns" => ["a"], "validated" => false, "values" => nil}] =
               relation["checks"]

      validated =
        introspect([
          "CREATE TABLE s.t (id int PRIMARY KEY, a int)",
          "ALTER TABLE s.t ADD CONSTRAINT nn NOT NULL a"
        ])

      assert Enum.map(Catalog.diff(catalog, validated), & &1.id) == [
               "column s.t.a",
               "check s.t.nn"
             ]
    end
  end

  # `mix ash_strangler.gen.twin` writes its identities from this catalog, so what
  # the catalog calls a unique set is what the generated twin declares.
  describe "unique sets read only an index's key columns" do
    test "an expression key is printed as the expression, and INCLUDE columns are left out" do
      catalog =
        introspect([
          "CREATE TABLE s.t (id int, a text, b text, c text)",
          "CREATE UNIQUE INDEX plain_include ON s.t (a) INCLUDE (b)",
          "CREATE UNIQUE INDEX mixed ON s.t (c, lower(b))"
        ])

      unique = Map.new(catalog["relations"]["s.t"]["unique"], &{&1["name"], &1["columns"]})

      assert unique["plain_include"] == ["a"]
      assert unique["mixed"] == ["c", "lower(b)"]
    end

    test "a primary key and a unique constraint with INCLUDE columns list only the key" do
      catalog =
        introspect([
          "CREATE TABLE s.t (id int, a text, b text, " <>
            "PRIMARY KEY (id) INCLUDE (a), UNIQUE (a) INCLUDE (b))"
        ])

      relation = catalog["relations"]["s.t"]

      assert %{"columns" => ["id"]} = relation["primary_key"]
      assert [%{"columns" => ["a"]}] = relation["unique"]
    end
  end

  describe "the strangle's own objects" do
    test "are skipped on both sides of a diff" do
      relation = fn triggers ->
        %{
          "relations" => %{"s.t" => %{"kind" => "table", "columns" => [], "triggers" => triggers}}
        }
      end

      ours = %{"name" => "strangler_watch_s_t", "definition" => "CREATE TRIGGER ..."}
      theirs = %{"name" => "audit", "definition" => "CREATE TRIGGER audit ..."}

      assert Catalog.diff(relation.([ours, theirs]), relation.([theirs])) == []
      assert Catalog.diff(relation.([theirs]), relation.([ours, theirs])) == []

      assert [%{id: "trigger s.t.audit"}] =
               Catalog.diff(relation.([ours, theirs]), relation.([ours]))
    end

    test "are left out of a captured schema.sql" do
      dump = """
      --
      -- Name: t; Type: TABLE; Schema: s; Owner: -
      --

      CREATE TABLE s.t (
          id integer NOT NULL
      );


      --
      -- Name: strangler_ledger_s_t(); Type: FUNCTION; Schema: s; Owner: -
      --

      CREATE FUNCTION s.strangler_ledger_s_t() RETURNS trigger
          LANGUAGE plpgsql
          AS $strangler$
      BEGIN
        -- a comment
        RETURN NULL;
      END $strangler$;


      --
      -- Name: strangler_t_key_idx; Type: INDEX; Schema: s; Owner: -
      --

      CREATE INDEX strangler_t_key_idx ON s.t USING btree (id);


      --
      -- Name: t_id_idx; Type: INDEX; Schema: s; Owner: -
      --

      CREATE INDEX t_id_idx ON s.t USING btree (id);


      --
      -- Name: "Odd Table" strangler_watch_s_t; Type: TRIGGER; Schema: s; Owner: -
      --

      CREATE TRIGGER strangler_watch_s_t AFTER INSERT ON s."Odd Table" FOR EACH ROW EXECUTE FUNCTION public.f();


      --
      -- PostgreSQL database dump complete
      --
      """

      normalised = Snapshot.normalise(dump)

      refute normalised =~ "strangler_"
      assert normalised =~ "CREATE TABLE s.t ("
      assert normalised =~ "CREATE INDEX t_id_idx ON s.t USING btree (id);\n"
      assert normalised =~ "-- PostgreSQL database dump complete"
      assert Snapshot.normalise(normalised) == normalised
    end
  end
end
