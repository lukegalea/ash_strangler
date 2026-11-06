# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.DerivedTest do
  @moduledoc """
  Derived rows against PostgreSQL: slots, a synthesized row, jsonb elements
  behind the integer guard, a filter, and composite logical keys.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Derived.{Info, Sql}
  alias AshStrangler.KeyKinds
  alias AshStrangler.Test.ClinicDerived.{Keys, Properties}

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  defp visit!(id, attrs \\ []) do
    q!("INSERT INTO clinic_derived.visits VALUES ($1, $2, $3, $4::jsonb, $5::jsonb, $1)", [
      id,
      attrs[:lead],
      attrs[:booked_at],
      attrs[:details],
      attrs[:metadata]
    ])
  end

  defp staff,
    do:
      q!(
        "SELECT __source, visit, person, role, position FROM clinic_derived.staff ORDER BY __source, position, person"
      )

  defp properties(visit),
    do:
      q!("SELECT property FROM clinic_derived.properties WHERE visit = $1 ORDER BY property", [
        visit
      ])
      |> List.flatten()

  describe "slots and synthesized rows" do
    test "a slot yields a row only where its filter holds" do
      visit!(1, lead: "ada")
      visit!(2)
      assert [["lead", 1, "ada", "lead", nil]] = staff()
    end

    test "a synthesized row is computed from the legacy row" do
      visit!(1, booked_at: ~U[2026-01-02 03:04:05.000000Z])
      assert [["booked", 1, "front desk", "booked", nil]] = staff()
    end

    test "one legacy row yields every source that applies" do
      visit!(1, lead: "ada", booked_at: ~U[2026-01-02 03:04:05.000000Z])
      assert ["booked", "lead"] = for([source | _] <- staff(), do: source)
    end
  end

  describe "text elements" do
    test "yield a row per string, in order, with a 1-based position" do
      visit!(1, details: %{guests: ["bo", "cy"]})
      assert [["guest", 1, "bo", "guest", 1], ["guest", 1, "cy", "guest", 2]] = staff()
    end

    test "non-strings and a non-array yield nothing" do
      visit!(1, details: %{guests: ["bo", 7, nil, true, %{}]})
      visit!(2, details: %{guests: "bo"})
      visit!(3, details: %{other: ["x"]})
      visit!(4)
      assert [["guest", 1, "bo", "guest", 1]] = staff()
    end

    test "a repeated element yields one row, the first" do
      visit!(1, details: %{guests: ["bo", "cy", "bo"]})
      assert [["guest", 1, "bo", "guest", 1], ["guest", 1, "cy", "guest", 2]] = staff()
    end
  end

  describe "the integer guard" do
    test "accepts integers, including integral floats, and nothing else" do
      visit!(1,
        metadata: %{
          propertyIds: [3, 5.0, 12.5, 1.0e10, "12", true, nil, [], %{}, -2_147_483_649, 7]
        }
      )

      assert properties(1) == [3, 5, 7]
    end

    test "the 32-bit bounds are inclusive" do
      visit!(1, metadata: %{propertyIds: [-2_147_483_648, 2_147_483_647, 2_147_483_648]})
      assert properties(1) == [-2_147_483_648, 2_147_483_647]
    end

    test "a malformed row does not fail the read of the others" do
      visit!(1, metadata: %{propertyIds: ["x", 1.0e30]})
      visit!(2, metadata: %{propertyIds: [9]})
      assert q!("SELECT visit, property FROM clinic_derived.properties") == [[2, 9]]
    end

    test "the shared filter applies to every source" do
      visit!(0, metadata: %{propertyIds: [1]})
      visit!(2, metadata: %{propertyIds: [1]})
      assert q!("SELECT visit FROM clinic_derived.properties") == [[2]]
    end

    test "5 and 5.0 are one element" do
      visit!(1, metadata: %{propertyIds: [5, 5.0]})
      assert properties(1) == [5]
    end

    test "the census counts what the guard refuses" do
      visit!(1, metadata: %{propertyIds: [3, 12.5, "12", 7]})
      visit!(2, metadata: %{propertyIds: [1.0e10]})
      [source] = Info.elements(Properties)
      assert [[3, 5]] = q!(Sql.element_census_sql(Properties, source))
    end
  end

  test "a tenant_of column is the packed key of its kind over the legacy columns" do
    visit!(5, metadata: %{propertyIds: [1]})
    [[clinic]] = q!("SELECT clinic FROM clinic_derived.properties")
    assert Ecto.UUID.cast!(clinic) == KeyKinds.encode(Keys, :clinic, [5])
  end

  describe "logical keys" do
    test "SQL agrees with the Elixir function" do
      visit!(1, lead: "ada", metadata: %{propertyIds: [4]}, details: %{guests: ["bo"]})
      [[lead]] = q!("SELECT id FROM clinic_derived.staff WHERE __source = 'lead'")
      [[guest]] = q!("SELECT id FROM clinic_derived.staff WHERE __source = 'guest'")
      [[property]] = q!("SELECT id FROM clinic_derived.properties")

      assert Ecto.UUID.cast!(lead) == KeyKinds.logical(Keys, :staff, [1, "lead"])
      assert Ecto.UUID.cast!(guest) == KeyKinds.logical(Keys, :staff, [1, "guest", "bo"])
      assert Ecto.UUID.cast!(property) == KeyKinds.logical(Keys, :property, [1, "listed", 4])
    end

    test "distinct sources, kinds and parents get distinct keys" do
      keys = [
        KeyKinds.logical(Keys, :staff, [1, "lead"]),
        KeyKinds.logical(Keys, :staff, [1, "booked"]),
        KeyKinds.logical(Keys, :staff, [2, "lead"]),
        KeyKinds.logical(Keys, :property, [1, "lead"])
      ]

      assert length(Enum.uniq(keys)) == 4
    end

    test "a component is not smeared into its neighbour" do
      assert KeyKinds.logical(Keys, :staff, ["a", "bc"]) !=
               KeyKinds.logical(Keys, :staff, ["ab", "c"])
    end

    test "a NULL component gives no key" do
      assert KeyKinds.logical(Keys, :staff, [1, nil]) == nil
    end

    test "the namespace depends on the estate and the tag" do
      assert KeyKinds.logical_namespace(Keys, :staff) !=
               KeyKinds.logical_namespace(Keys, :property)
    end

    test "an unknown kind raises" do
      assert_raise ArgumentError, ~r/no logical key kind/, fn ->
        KeyKinds.logical(Keys, :nope, [1])
      end
    end
  end

  test "the view is read-only" do
    assert_raise Postgrex.Error, ~r/cannot insert into view/, fn ->
      q!("INSERT INTO clinic_derived.staff (visit) VALUES (1)")
    end
  end
end
