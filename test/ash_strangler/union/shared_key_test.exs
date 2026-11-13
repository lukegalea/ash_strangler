# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.SharedKeyFixture.Keys do
  @moduledoc false
  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x5B1
    kind :org, 0x001, parts: [{"sk_fx.org_places.org_id", 32}], tenant?: true
    kind :person, 0x002, parts: [{"sk_fx.person_places.person_id", 32}], tenant?: true
    kind :place, 0x010, parts: [{"sk_fx.org_places.id", 32}]
  end
end

defmodule AshStrangler.SharedKeyFixture.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshStrangler.SharedKeyFixture.Legacy.OrgPlaces do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.SharedKeyFixture.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "org_places"
    schema "sk_fx"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
    attribute :org_id, :integer, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.SharedKeyFixture.Legacy.PersonPlaces do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.SharedKeyFixture.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "person_places"
    schema "sk_fx"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :place_id, :integer, public?: true
    attribute :person_id, :integer, public?: true
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.SharedKeyFixture.Places do
  @moduledoc """
  One place, two routes into the view: a place an organization holds comes from its own table,
  a place a single person holds comes through that person's link row. Both key it
  `{:place, id}`, so its id does not depend on which branch carries it.
  """
  use AshStrangler.Union

  union do
    schema "sk_fx"
    view "places"
    tenant :tenant

    column :label, :string
    column :tenant, :uuid

    legacy :by_org do
      twin AshStrangler.SharedKeyFixture.Legacy.OrgPlaces
      phase :read_from_legacy
      refused_because "the legacy system writes these rows"
      shares_key_with [:by_person]
      filter expr(not is_nil(org_id))
      key :id, strategy: {:uuid_v8, AshStrangler.SharedKeyFixture.Keys, :place}
      map :label, from: :label
      tenant_of :tenant, kind: {AshStrangler.SharedKeyFixture.Keys, :org}, from: :org_id
    end

    legacy :by_person do
      twin AshStrangler.SharedKeyFixture.Legacy.PersonPlaces
      phase :read_from_legacy
      refused_because "the legacy system writes these rows"
      shares_key_with [:by_org]
      key :place_id, strategy: {:uuid_v8, AshStrangler.SharedKeyFixture.Keys, :place}
      map :label, from: :label
      tenant_of :tenant, kind: {AshStrangler.SharedKeyFixture.Keys, :person}, from: :person_id
    end

    owned :native
  end
end

defmodule AshStrangler.SharedKeyTest do
  @moduledoc """
  Two branches that share a key kind (`shares_key_with`), against PostgreSQL: the estate's
  `key-disjoint` obligation counts an id both branches produce, and tenant inversion gives each
  tenant kind only the arm of the branch whose tenant is that kind.
  """

  # Serial: compiling the estate swaps the global :standard_error device.
  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Estate.Obligations
  alias AshStrangler.Inversion
  alias AshStrangler.KeyKinds
  alias AshStrangler.SharedKeyFixture.{Keys, Places}
  alias AshStrangler.Union.Info

  @catalog "test/fixtures/snapshot/clinic_union/catalog.json"
  @obligation "key-disjoint:places:by_org+by_person"

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  setup do
    q!("DROP SCHEMA IF EXISTS sk_fx CASCADE")
    q!("CREATE SCHEMA sk_fx")
    q!("CREATE TABLE sk_fx.org_places (id integer PRIMARY KEY, label text, org_id integer)")

    q!(
      "CREATE TABLE sk_fx.person_places (id integer PRIMARY KEY, place_id integer NOT NULL, person_id integer NOT NULL, label text)"
    )

    # Places 1-4 are held by organizations 1 and 2; places 5 and 6 by persons 7 and 8.
    q!(
      "INSERT INTO sk_fx.org_places SELECT g, 'place ' || g, CASE WHEN g <= 4 THEN 1 + g % 2 END FROM generate_series(1, 6) g"
    )

    q!("INSERT INTO sk_fx.person_places VALUES (10, 5, 7, 'place 5'), (11, 6, 8, 'place 6')")

    for %{up: up} <- AshStrangler.Migration.statements(Places), do: q!(up)
    :ok
  end

  defp place(n), do: Ecto.UUID.dump!(KeyKinds.encode(Keys, :place, [n]))
  defp org(n), do: KeyKinds.encode(Keys, :org, [n])
  defp person(n), do: KeyKinds.encode(Keys, :person, [n])

  defp estate do
    name = "AshStrangler.SharedKeyTest.E#{System.unique_integer([:positive])}"

    {modules, _io} =
      with_io(:stderr, fn ->
        """
        defmodule #{name} do
          use AshStrangler.Estate

          estate do
            snapshot #{inspect(@catalog)}
            resources [#{inspect(Places)}]
          end
        end
        """
        |> Code.compile_string()
        |> Enum.map(&elem(&1, 0))
      end)

    List.last(modules)
  end

  defp disjoint_row do
    Obligations.report(estate(), repo: TestRepo)["obligations"]
    |> Enum.find(&(&1["id"] == @obligation))
  end

  describe "the key-disjoint obligation" do
    test "the group is registered once, at error severity, sourced to the union" do
      assert Info.key_sharing_groups(Places) == [[:by_org, :by_person]]

      assert [obligation] =
               estate() |> Obligations.registry() |> Enum.filter(&(&1.id =~ "key-disjoint:"))

      assert obligation.id == @obligation
      assert obligation.severity == :error
      assert obligation.shape == :census
      assert obligation.source == inspect(Places)
    end

    test "disjoint branches pass: no id comes from both" do
      assert %{"status" => "pass", "violations" => 0, "total" => 6} = disjoint_row()
    end

    test "a planted collision counts once, and fails the report" do
      # Place 1 is an organization's, and now a person's link names it too.
      q!("INSERT INTO sk_fx.person_places VALUES (12, 1, 7, 'place 1')")

      assert [[2]] = q!("SELECT count(*) FROM sk_fx.places WHERE id = $1", [place(1)])
      assert %{"status" => "fail", "violations" => 1, "total" => 6} = disjoint_row()
    end
  end

  describe "tenant inversion over a shared key kind" do
    test "each tenant id yields only its own branch's arm" do
      assert Inversion.arms(Places, org(1)) == [{:by_org, [1]}, {:native, :original}]
      assert Inversion.arms(Places, person(7)) == [{:by_person, [7]}, {:native, :original}]
    end

    test "the inverted predicate returns the plain predicate's rows, for both tenant kinds" do
      for {tenant, expected} <- [
            {org(1), [2, 4]},
            {org(2), [1, 3]},
            {person(7), [5]},
            {person(8), [6]}
          ] do
        plain = q!(~s[SELECT id FROM sk_fx.places WHERE "tenant" = '#{tenant}' ORDER BY id])

        inverted =
          q!(
            "SELECT id FROM sk_fx.places WHERE #{Inversion.where_sql(Places, tenant)} ORDER BY id"
          )

        assert plain == inverted
        assert plain == Enum.map(Enum.sort_by(expected, &place/1), &[place(&1)])
      end
    end

    test "a place keeps its id when it moves from one branch to the other" do
      read = fn -> q!(~s[SELECT id, "__branch" FROM sk_fx.places WHERE label = 'place 5']) end
      assert read.() == [[place(5), "by_person"]]

      # An organization takes the place over: legacy sets its org_id and drops the person's link.
      q!("UPDATE sk_fx.org_places SET org_id = 1 WHERE id = 5")
      q!("DELETE FROM sk_fx.person_places WHERE place_id = 5")

      assert read.() == [[place(5), "by_org"]]
    end
  end
end
