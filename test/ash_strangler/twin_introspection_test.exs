# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Twin.IntrospectionTest do
  @moduledoc """
  `AshStrangler.Twin.Introspection` is the seam both `mix ash_strangler.gen.twin`
  and `mix ash_strangler.check` read a legacy relation through, so these tests ask
  it what the generator would write for real tables: the same answer the twin is
  generated from, and the one the check holds a compiled twin to.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Twin.Introspection

  defp run(sql, params), do: TestRepo.query(sql, params)

  defp ddl!(sql), do: TestRepo.query!(sql, [])

  defp relation!(name) do
    {:ok, catalog} = Introspection.read(&run/2, ["legacy"])
    {:ok, relation} = Introspection.relation(catalog, "legacy.#{name}")
    {relation, catalog}
  end

  defp unique_sets(name) do
    {relation, catalog} = relation!(name)
    columns = Introspection.columns(relation, catalog)
    relation |> Introspection.unique_sets(columns) |> Enum.map(&Enum.sort/1) |> Enum.sort()
  end

  describe "reading" do
    test "a relation the schema does not have is :error, not a raise" do
      {:ok, catalog} = Introspection.read(&run/2, ["legacy"])

      assert Introspection.relation(catalog, "legacy.no_such_table") == :error
    end

    test "a query the database rejects is an {:error, _}" do
      assert {:error, %Postgrex.Error{}} =
               Introspection.read(fn _sql, _params -> TestRepo.query("SELECT nope", []) end, [
                 "legacy"
               ])
    end

    test "the catalog is the one the snapshot tooling reads" do
      {:ok, catalog} = Introspection.read(&run/2, ["legacy"])
      {:ok, users} = Introspection.relation(catalog, "legacy.users")

      assert Enum.any?(users["columns"], &(&1["name"] == "login"))
      assert users["primary_key"]["columns"] == ["id"]
    end
  end

  describe "what the generator writes for a column" do
    test "a CHECK value set, an enum and a citext column keep their distinct types" do
      ddl!("CREATE TYPE legacy.intro_state AS ENUM ('open', 'paid')")

      ddl!("""
      CREATE TABLE legacy.intro_orders (
        id bigint PRIMARY KEY,
        state legacy.intro_state NOT NULL,
        kind text CHECK (kind IN ('a', 'b')),
        handle citext,
        label text,
        amount numeric,
        tags text[]
      )
      """)

      {relation, catalog} = relation!("intro_orders")
      columns = Map.new(Introspection.columns(relation, catalog), &{&1.column, &1})

      assert %{type: :integer, primary_key?: true, allow_nil?: false} = columns["id"]
      assert %{type: :atom, one_of: ["open", "paid"], allow_nil?: false} = columns["state"]
      assert %{type: :atom, one_of: ["a", "b"]} = columns["kind"]
      assert %{type: :ci_string, one_of: nil} = columns["handle"]
      assert %{type: :string, one_of: nil} = columns["label"]
      assert %{type: :decimal} = columns["amount"]
      assert %{type: {:array, :string}} = columns["tags"]
    end

    test "a column Postgres has a type for and Ash does not is omitted with a note" do
      ddl!("CREATE TABLE legacy.intro_odd (id int PRIMARY KEY, addr inet)")

      {relation, catalog} = relation!("intro_odd")
      columns = Map.new(Introspection.columns(relation, catalog), &{&1.column, &1})

      assert columns["addr"].type == nil
      assert columns["addr"].note =~ "no Ash type"
    end

    test "a secret column is left out, with its note" do
      ddl!("CREATE TABLE legacy.intro_secret (id int PRIMARY KEY, digest text)")

      {relation, catalog} = relation!("intro_secret")
      columns = Map.new(Introspection.columns(relation, catalog, ["digest"]), &{&1.column, &1})

      assert columns["digest"].type == nil
      assert columns["digest"].note =~ "secret"
    end

    test "a column whose name Elixir will not take is not declared" do
      ddl!(~s|CREATE TABLE legacy.intro_names (id int PRIMARY KEY, "Weird Name!" text)|)

      {relation, catalog} = relation!("intro_names")
      columns = Map.new(Introspection.columns(relation, catalog), &{&1.column, &1})

      assert columns["Weird Name!"].name == nil
      assert columns["Weird Name!"].type == nil
    end
  end

  # What PR 1 fixed in `check`'s own index query is read here by the generator, a
  # different query over the same facts, and it has to give the same answers.
  describe "unique sets as the generator sees them" do
    test "a plain unique index and the primary key" do
      ddl!("CREATE TABLE legacy.intro_u1 (id int PRIMARY KEY, login text)")
      ddl!("CREATE UNIQUE INDEX intro_u1_login ON legacy.intro_u1 (login)")

      assert unique_sets("intro_u1") == [["id"], ["login"]]
    end

    test "an index mixing a plain column and an expression enforces neither alone" do
      ddl!("CREATE TABLE legacy.intro_u2 (id int PRIMARY KEY, login text, email text)")
      ddl!("CREATE UNIQUE INDEX intro_u2_mixed ON legacy.intro_u2 (login, lower(email))")

      assert unique_sets("intro_u2") == [["id"]]
    end

    test "an index over an expression alone enforces nothing" do
      ddl!("CREATE TABLE legacy.intro_u3 (id int PRIMARY KEY, login text)")
      ddl!("CREATE UNIQUE INDEX intro_u3_lower ON legacy.intro_u3 (lower(login))")

      assert unique_sets("intro_u3") == [["id"]]
    end

    test "a partial unique index enforces nothing" do
      ddl!("CREATE TABLE legacy.intro_u4 (id int PRIMARY KEY, login text, live boolean)")
      ddl!("CREATE UNIQUE INDEX intro_u4_live ON legacy.intro_u4 (login) WHERE live")

      assert unique_sets("intro_u4") == [["id"]]
    end

    test "INCLUDE columns on a unique index are payload, not key" do
      ddl!("CREATE TABLE legacy.intro_u5 (id int PRIMARY KEY, login text, email text)")
      ddl!("CREATE UNIQUE INDEX intro_u5_login ON legacy.intro_u5 (login) INCLUDE (email)")

      assert unique_sets("intro_u5") == [["id"], ["login"]]
    end

    test "INCLUDE columns on a unique constraint are payload, not key" do
      ddl!("""
      CREATE TABLE legacy.intro_u6 (
        id int PRIMARY KEY, login text, email text,
        CONSTRAINT intro_u6_login UNIQUE (login) INCLUDE (email)
      )
      """)

      assert unique_sets("intro_u6") == [["id"], ["login"]]
    end

    test "INCLUDE columns on a primary key are payload, not key" do
      ddl!("""
      CREATE TABLE legacy.intro_u7 (
        id int, login text, email text,
        CONSTRAINT intro_u7_pk PRIMARY KEY (id) INCLUDE (email)
      )
      """)

      {relation, _catalog} = relation!("intro_u7")

      assert relation["primary_key"]["columns"] == ["id"]
      assert unique_sets("intro_u7") == [["id"]]
    end

    test "a composite key keeps both columns, and only those" do
      ddl!("""
      CREATE TABLE legacy.intro_u8 (
        tenant int, login text, email text,
        CONSTRAINT intro_u8_pk PRIMARY KEY (tenant, login) INCLUDE (email)
      )
      """)

      assert unique_sets("intro_u8") == [["login", "tenant"]]
    end

    test "an identity is written for a unique set whose columns are all declared" do
      ddl!("CREATE TABLE legacy.intro_u9 (id int PRIMARY KEY, login text, email text)")
      ddl!("CREATE UNIQUE INDEX intro_u9_login ON legacy.intro_u9 (login) INCLUDE (email)")
      ddl!("CREATE UNIQUE INDEX intro_u9_mixed ON legacy.intro_u9 (login, lower(email))")

      {relation, catalog} = relation!("intro_u9")
      columns = Introspection.columns(relation, catalog)

      assert [%{name: "intro_u9_login", keys: ["login"]}] =
               Introspection.identities(relation, columns)
    end
  end

  describe "the type table" do
    test "citext is its own type, never text" do
      assert Introspection.coarse(Introspection.pg_type("citext")) == :ci_string
      assert Introspection.coarse(Introspection.pg_type("text")) == :string
      refute Introspection.coarse(:ci_string) == Introspection.coarse(:string)
    end

    test "integer widths and timestamp precisions are one coarse type" do
      assert Introspection.coarse(Introspection.pg_type("int2")) ==
               Introspection.coarse(Introspection.pg_type("int8"))

      assert Introspection.coarse(:utc_datetime) == Introspection.coarse(:utc_datetime_usec)
    end

    test "an atom with a value set is stored as text" do
      assert Introspection.coarse(:atom, one_of: [:a, :b]) == Introspection.coarse(:string)
    end

    test "an array is coarse over its element" do
      assert Introspection.coarse({:array, :integer}, items: []) == {:array, :integer}
    end

    test "a Postgres type with no Ash type is nil" do
      assert Introspection.pg_type("inet") == nil
      assert Introspection.pg_type("interval") == nil
    end
  end
end
