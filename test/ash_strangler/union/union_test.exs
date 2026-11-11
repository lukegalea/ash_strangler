# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionTest do
  @moduledoc """
  The union view and its `INSTEAD OF` triggers against PostgreSQL: two legacy
  branches (north `:read_from_legacy`, south `:dual_write`) and an owned branch.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Error.BranchWriteRefused
  alias AshStrangler.Test.Clinic.Visit
  alias AshStrangler.Union.Info

  @visits AshStrangler.Test.Clinic.Visits

  defp q!(sql, params \\ []), do: TestRepo.query!(sql, params, mode: :savepoint).rows

  defp north!(id, name),
    do: q!("INSERT INTO clinic_union.north_visits VALUES ($1, $2, '2026-01-02')", [id, name])

  defp south!(id, name),
    do: q!("INSERT INTO clinic_union.south_visits VALUES ($1, $2, '2026-01-03', 'r')", [id, name])

  defp id_of(branch, patient),
    do:
      q!("SELECT id FROM clinic_union.visits WHERE __branch = $1 AND patient = $2", [
        branch,
        patient
      ])
      |> hd()
      |> hd()

  defp refusal!(result) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} = result
    assert [%BranchWriteRefused{} = error] = errors
    error
  end

  describe "the view" do
    test "reads both legacy branches and the owned branch, each row naming its branch" do
      north!(1, "ada")
      south!(1, "bo")
      q!("INSERT INTO clinic_union.visits (patient) VALUES ('cy')")

      rows = q!("SELECT __branch, patient FROM clinic_union.visits ORDER BY patient")
      assert rows == [["north", "ada"], ["south", "bo"], ["native", "cy"]]
    end

    test "branches with the same legacy id still get different keys" do
      north!(7, "ada")
      south!(7, "bo")
      assert [[a], [b]] = q!("SELECT id FROM clinic_union.visits ORDER BY patient")
      assert a != b
    end

    test "unmapped columns read NULL and every column has the declared type" do
      north!(1, "ada")
      assert [[nil, ~D[2026-01-02]]] = q!("SELECT notes, visited_on FROM clinic_union.visits")
    end

    test "a key index backs the legacy branch's key lookup" do
      for n <- 1..3000,
          do: q!("INSERT INTO clinic_union.north_visits VALUES ($1, $2, NULL)", [n, "p#{n}"])

      q!("ANALYZE clinic_union.north_visits")
      id = id_of("north", "p5")
      q!("SET LOCAL enable_seqscan = off")

      plan =
        "EXPLAIN SELECT * FROM clinic_union.visits WHERE id = $1"
        |> q!([id])
        |> Enum.map_join("\n", &hd/1)

      assert plan =~ "strangler_visits_north_key_idx"
    end
  end

  describe "owned branch writes" do
    test "an insert through INSTEAD OF returns the stored row, key and defaults included" do
      assert [[id, "ada", ~D[2026-02-01], nil, "native"]] =
               q!("""
               INSERT INTO clinic_union.visits (patient, visited_on) VALUES ('ada', '2026-02-01')
               RETURNING id, patient, visited_on, notes, __branch
               """)

      assert is_binary(id) and byte_size(id) == 16
      assert [["ada"]] = q!("SELECT patient FROM clinic_union.visits_owned WHERE id = $1", [id])
    end

    test "an Ash create returns a record with its key, and update and destroy work" do
      visit = Ash.create!(Visit, %{patient: "ada", visited_on: ~D[2026-02-01]})
      assert visit.id
      assert Ash.get!(Visit, visit.id).patient == "ada"

      updated = Ash.update!(visit, %{patient: "ada l.", notes: "n"})
      assert %{patient: "ada l.", notes: "n"} = Ash.get!(Visit, visit.id)
      assert updated.patient == "ada l."

      Ash.destroy!(visit)
      assert [] = Ash.read!(Visit)
    end

    test "a supplied key is kept" do
      id = Ecto.UUID.generate()
      visit = Ash.create!(Visit, %{id: id, patient: "ada"})
      assert visit.id == id
    end

    test "a supplied key that names a live legacy row is refused, so ids stay unique in the view" do
      north!(1, "ada")
      id = id_of("north", "ada")

      assert_raise Postgrex.Error, ~r/already exists in visits/, fn ->
        q!("INSERT INTO clinic_union.visits (id, patient) VALUES ($1, 'x')", [id])
      end

      assert [[1]] = q!("SELECT count(*) FROM clinic_union.visits WHERE id = $1", [id])
    end

    test "an insert that names a legacy branch is refused" do
      assert_raise Postgrex.Error, ~r/ash_error/, fn ->
        q!("INSERT INTO clinic_union.visits (__branch, patient) VALUES ('north', 'x')")
      end
    end
  end

  describe "legacy branch writes" do
    test "a write to a :read_from_legacy branch is refused with the declared reason, as a typed error" do
      north!(1, "ada")
      visit = Ash.get!(Visit, id_of("north", "ada"))

      error = refusal!(Ash.update(visit, %{patient: "x"}))
      assert error.branch == "north"
      assert error.phase == "read_from_legacy"
      assert error.operation == "update"
      assert error.reason == "the north system writes these rows until its cutover"
      assert Exception.message(error) =~ "the north system writes these rows until its cutover"

      assert refusal!(Ash.destroy(visit)).operation == "delete"
      assert [["ada"]] = q!("SELECT patient_name FROM clinic_union.north_visits")
    end

    test "a :dual_write branch carries updates and deletes to the legacy table" do
      south!(1, "bo")
      visit = Ash.get!(Visit, id_of("south", "bo"))

      Ash.update!(visit, %{patient: "bo b.", notes: "n2", visited_on: ~D[2026-03-03]})

      assert [["bo b.", ~D[2026-03-03], "n2"]] =
               q!("SELECT name, date, remarks FROM clinic_union.south_visits")

      Ash.destroy!(visit)
      assert [] = q!("SELECT 1 FROM clinic_union.south_visits")
    end

    test "a :dual_write branch refuses a column it has no legacy column for" do
      # Move north to :dual_write inside this transaction (DDL is transactional).
      module = "AshStrangler.UnionTest.Variant#{System.unique_integer([:positive])}"

      [{variant, _}] =
        Code.compile_string(AshStrangler.Test.Clinic.source(module, :dual_write, :dual_write))

      for %{up: up} <- AshStrangler.Migration.statements(variant), do: q!(up)

      north!(1, "ada")
      id = id_of("north", "ada")

      assert_raise Postgrex.Error, ~r/column notes has no legacy column/, fn ->
        q!("UPDATE clinic_union.visits SET notes = 'x' WHERE id = $1", [id])
      end

      q!("UPDATE clinic_union.visits SET patient = 'ada l.' WHERE id = $1", [id])
      assert [["ada l."]] = q!("SELECT patient_name FROM clinic_union.north_visits")
    end
  end

  describe "a schema whose name contains a dot" do
    # The key index's `down` used to split the spelled relation on its first
    # dot to find the schema, so a quoted schema that itself contains a dot
    # produced `DROP INDEX IF EXISTS "odd.strangler_visits_north_key_idx"`,
    # which names nothing. The schema comes from the twin now.
    test "the union's SQL executes, and the key index drops from the dotted schema" do
      q!(~s|CREATE SCHEMA IF NOT EXISTS "odd.schema"|)

      q!(
        ~s|CREATE TABLE "odd.schema".north_visits (id integer PRIMARY KEY, patient_name text NOT NULL, seen_on date)|
      )

      module = "AshStrangler.UnionTest.Dotted#{System.unique_integer([:positive])}"

      # The compile result also carries the twin and the Inspect implementation
      # its resource derives; the union is the module the string named.
      [union] =
        Code.compile_string("""
        defmodule #{module} do
          use AshStrangler.Union

          union do
            schema "odd.schema"
            view "visits"

            column :patient, :string, null?: false

            legacy :north do
              twin #{module}.NorthVisits
              phase :read_from_legacy
              refused_because "north writes these rows until its cutover"
              key :id, strategy: {:uuid_v5, namespace: "2f1e4c5a-9b3d-5e7f-8a6b-1c2d3e4f5a6b"}
              map :patient, from: :patient_name
            end

            owned :native
          end
        end

        defmodule #{module}.NorthVisits do
          use Ash.Resource,
            domain: AshStrangler.Test.Clinic.Legacy,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshStrangler.Twin]

          postgres do
            table "north_visits"
            schema "odd.schema"
            repo AshStrangler.TestRepo
            migrate? false
          end

          attributes do
            attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
            attribute :patient_name, :string, allow_nil?: false, public?: true
            attribute :seen_on, :date, public?: true
          end

          actions do
            defaults [:read]
          end
        end
        """)
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1 == Module.concat([module])))

      statements = AshStrangler.Migration.statements(union)
      # DDL is transactional: everything here rolls back with the test.
      for %{up: up} <- statements, do: q!(up)

      assert [[1]] =
               q!(
                 "SELECT count(*) FROM pg_indexes WHERE schemaname = 'odd.schema' AND indexname = 'strangler_visits_north_key_idx'"
               )

      index = Enum.find(statements, &(&1.name == :strangler_visits_north_key_idx))
      q!(index.down)

      assert [[0]] =
               q!(
                 "SELECT count(*) FROM pg_indexes WHERE schemaname = 'odd.schema' AND indexname = 'strangler_visits_north_key_idx'"
               )
    end
  end

  describe "lens kinds" do
    test "report where each column of each branch comes from" do
      assert Info.lens_kinds(@visits, :north) == %{
               id: :key,
               patient: :column,
               visited_on: :column,
               notes: :null
             }

      assert Info.lens_kinds(@visits, :south) == %{
               id: :key,
               patient: :column,
               visited_on: :column,
               notes: :column
             }

      assert Info.lens_kinds(@visits, :native) == %{
               id: :owned,
               patient: :owned,
               visited_on: :owned,
               notes: :owned
             }
    end

    test "phases, resource phase and twin derivation" do
      assert Info.phase(@visits, :north) == :read_from_legacy
      assert Info.phase(@visits, :south) == :dual_write
      assert Info.resource_phase(@visits) == :read_from_legacy
      assert Info.twin_derived?(:column) and Info.twin_derived?(:expression)

      refute Info.twin_derived?(:constant) or Info.twin_derived?(:owned) or
               Info.twin_derived?(:null)
    end
  end
end
