# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.InversionFixture.Keys do
  @moduledoc false
  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x1A7
    kind :org, 0x001, parts: [{"inv_fx.north_items.org_id", 32}], tenant?: true
    kind :region, 0x002, parts: [{"inv_fx.south_items.region_id", 32}], tenant?: true
  end
end

defmodule AshStrangler.InversionFixture.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

for {module, table, column} <- [{"NorthItems", "north_items", :org_id}, {"SouthItems", "south_items", :region_id}] do
  defmodule Module.concat(AshStrangler.InversionFixture.Legacy, module) do
    @moduledoc false
    use Ash.Resource,
      domain: AshStrangler.InversionFixture.Legacy,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Twin]

    postgres do
      table unquote(table)
      schema "inv_fx"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :label, :string, public?: true
      attribute unquote(column), :integer, public?: true
    end

    actions do
      defaults [:read]
    end
  end
end

defmodule AshStrangler.InversionFixture.Items do
  @moduledoc false
  use AshStrangler.Union

  union do
    schema "inv_fx"
    view "items"
    tenant :tenant

    column :label, :string
    column :tenant, :uuid

    legacy :north do
      twin AshStrangler.InversionFixture.Legacy.NorthItems
      phase :read_from_legacy
      refused_because "north writes these rows"
      key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
      map :label, from: :label
      tenant_of :tenant, kind: {AshStrangler.InversionFixture.Keys, :org}, from: :org_id
    end

    legacy :south do
      twin AshStrangler.InversionFixture.Legacy.SouthItems
      phase :read_from_legacy
      refused_because "south writes these rows"
      key :id, strategy: {:uuid_v5, namespace: "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d"}
      map :label, from: :label
      tenant_of :tenant, kind: {AshStrangler.InversionFixture.Keys, :region}, from: :region_id
    end

    owned :native
  end
end

defmodule AshStrangler.InversionFixture.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.InversionFixture.Legacy,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "items"
    schema "inv_fx"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :label, :string, public?: true
    attribute :tenant, :uuid, public?: true
    attribute :__branch, :string, public?: true
    attribute :__tenant_p0, :integer, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.InversionTest do
  @moduledoc """
  Predicate inversion against PostgreSQL: the plan shape of the tenant predicate with and without
  it, on tables big enough for the planner to prefer an index, and the rows each form returns.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Inversion
  alias AshStrangler.InversionFixture.{Item, Items, Keys}

  require Ash.Query

  @rows 30_000

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  setup do
    q!("DROP SCHEMA IF EXISTS inv_fx CASCADE")
    q!("CREATE SCHEMA inv_fx")

    q!(
      "CREATE TABLE inv_fx.north_items (id integer PRIMARY KEY, label text, org_id integer NOT NULL)"
    )

    q!(
      "CREATE TABLE inv_fx.south_items (id integer PRIMARY KEY, label text, region_id integer NOT NULL)"
    )

    # The legacy tables' own indexes: the point is to use them, not to add ours.
    q!("CREATE INDEX north_org_idx ON inv_fx.north_items (org_id)")
    q!("CREATE INDEX south_region_idx ON inv_fx.south_items (region_id)")

    for table <- [:north_items, :south_items] do
      q!(
        "INSERT INTO inv_fx.#{table} SELECT g, 'row ' || g, 1 + g % 100 FROM generate_series(1, #{@rows}) g"
      )

      q!("ANALYZE inv_fx.#{table}")
    end

    for %{up: up} <- AshStrangler.Migration.statements(Items), do: q!(up)

    q!("INSERT INTO inv_fx.items (label, tenant) VALUES ('native a', $1), ('native b', $2)", [
      Ecto.UUID.dump!(org(7)),
      Ecto.UUID.dump!(org(8))
    ])

    :ok
  end

  defp org(n), do: AshStrangler.KeyKinds.encode(Keys, :org, [n])

  defp plan(where) do
    [[[%{"Plan" => plan}]]] =
      q!("EXPLAIN (FORMAT JSON) SELECT id, label FROM inv_fx.items WHERE #{where}")

    nodes(plan)
  end

  defp nodes(%{"Plans" => children} = node),
    do: [node | Enum.flat_map(children, &nodes/1)]

  defp nodes(node), do: [node]

  defp scans(nodes, relation, types),
    do: for(%{"Relation Name" => ^relation, "Node Type" => type} <- nodes, type in types, do: type)

  @seq ["Seq Scan"]
  @indexed ["Index Scan", "Bitmap Heap Scan", "Index Only Scan"]

  test "the plain predicate evaluates the packing expression over the whole legacy table" do
    nodes = plan(~s["tenant" = '#{org(7)}'])
    assert scans(nodes, "north_items", @seq) != []
  end

  test "the inverted predicate uses the legacy index and leaves the other branch's table alone" do
    nodes = plan(Inversion.where_sql(Items, org(7)))

    assert scans(nodes, "north_items", @seq) == []
    assert scans(nodes, "north_items", @indexed) != []
    # The region branch's kind does not decode an org key: its arm is gone, so nothing reads it.
    assert scans(nodes, "south_items", @seq ++ @indexed) == []
  end

  test "both forms return the same rows" do
    id = org(7)

    plain = q!(~s[SELECT id FROM inv_fx.items WHERE "tenant" = '#{id}' ORDER BY id])
    inverted = q!("SELECT id FROM inv_fx.items WHERE #{Inversion.where_sql(Items, id)} ORDER BY id")

    assert plain == inverted
    assert length(plain) == div(@rows, 100) + 1
  end

  test "the owned branch keeps the original predicate" do
    inverted = q!("SELECT label FROM inv_fx.items WHERE #{Inversion.where_sql(Items, org(7))} AND label LIKE 'native%'")
    assert inverted == [["native a"]]
  end

  test "a key of another kind or estate, or no key at all, matches only owned rows" do
    region = AshStrangler.KeyKinds.encode(Keys, :region, [7])

    assert [{:south, [7]}, {:native, :original}] = Inversion.arms(Items, region)
    assert [{:native, :original}] = Inversion.arms(Items, Ecto.UUID.generate())
    assert [{:native, :original}] = Inversion.arms(Items, "not a key")
  end

  test "the Ash filter is the same predicate" do
    id = org(7)

    rows =
      Item
      |> Ash.Query.filter(^Inversion.filter(Items, Item, id))
      |> Ash.Query.select([:id, :label])
      |> Ash.read!()

    plain = q!(~s[SELECT id FROM inv_fx.items WHERE "tenant" = '#{id}'])
    assert rows |> Enum.map(& &1.id) |> Enum.sort() == plain |> Enum.map(&Ecto.UUID.load!(hd(&1))) |> Enum.sort()
  end

  test "the hidden columns are the last ones, one per key part" do
    assert Items |> AshStrangler.Union.Info.tenant_part_columns() == ["__tenant_p0"]
    assert [["__tenant_p0"]] = q!("SELECT column_name FROM information_schema.columns WHERE table_schema = 'inv_fx' AND table_name = 'items' ORDER BY ordinal_position DESC LIMIT 1")
  end
end
