# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UnionVerifierTest do
  @moduledoc """
  Negative compile fixtures for `VerifyUnion`. Verifier failures are printed by
  the parallel checker rather than raised (see `AshStrangler.VerifiersTest`),
  so each case compiles a probe and calls the verifier over its
  `spark_dsl_config/0`.
  """

  # Serial: compiling probes swaps the global :standard_error device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Verifiers.VerifyUnion

  @north ~S"""
    legacy :north do
      twin AshStrangler.Test.Clinic.Legacy.NorthVisits
      phase :dual_write
      refused_because "north writes"
      key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
      map :patient, from: :patient_name
      map :visited_on, from: :seen_on
      unmapped [:notes], because: "none"
    end
  """

  @south ~S"""
    legacy :south do
      twin AshStrangler.Test.Clinic.Legacy.SouthVisits
      phase :dual_write
      refused_because "south writes"
      key :id, strategy: {:uuid_v5, namespace: "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d"}
      map :patient, from: :name
      map :visited_on, from: :date
      map :notes, from: :remarks
    end
  """

  @columns "column :patient, :string\n column :visited_on, :date\n column :notes, :string\n"

  defp probe(body) do
    name = "AshStrangler.UnionVerifierTest.Probe#{System.unique_integer([:positive])}"

    {module, io} =
      with_io(:stderr, fn ->
        try do
          """
          defmodule #{name} do
            use AshStrangler.Union

            union do
              schema "clinic_union"
              view "visits"
              #{body}
            end
          end
          """
          |> Code.compile_string()
          |> Enum.map(&elem(&1, 0))
          |> List.last()
        rescue
          error in CompileError -> {:compile_error, Exception.message(error)}
        end
      end)

    if match?({:compile_error, _}, module), do: flunk("probe did not compile: #{io}")
    module
  end

  defp inside(branch, extra), do: String.replace(branch, ~r/end\s*\z/, extra <> "\nend\n")

  defp rejection(body) do
    module = probe(body)

    case VerifyUnion.verify(module.spark_dsl_config()) do
      {:error, error} -> Exception.message(error)
      other -> flunk("accepted: #{inspect(other)}")
    end
  end

  defp valid(overrides \\ []) do
    Enum.join(
      [
        Keyword.get(overrides, :columns, @columns),
        Keyword.get(overrides, :north, @north),
        Keyword.get(overrides, :south, @south),
        Keyword.get(overrides, :owned, "owned :native")
      ],
      "\n"
    )
  end

  test "the base fixture is accepted" do
    assert :ok = VerifyUnion.verify(probe(valid()).spark_dsl_config())
  end

  test "no owned branch, or two" do
    assert rejection(valid(owned: "")) =~ "exactly one `owned` branch (found 0)"
    assert rejection(valid(owned: "owned :a\nowned :b")) =~ "(found 2)"
  end

  test "no legacy branch" do
    assert rejection(valid(north: "", south: "")) =~ "at least one `legacy` branch"
  end

  test "duplicate columns and branches" do
    assert rejection(valid(columns: @columns <> "column :notes, :string")) =~
             "column :notes is declared 2 times"

    assert rejection(valid(south: String.replace(@south, "legacy :south", "legacy :north"))) =~
             "branch :north is declared 2 times"
  end

  test "a column named like the key" do
    assert rejection(valid(columns: @columns <> "column :id, :uuid")) =~
             "key column :id is also declared as a column"
  end

  test "a twin that is not a twin" do
    assert rejection(
             valid(
               north:
                 String.replace(@north, "AshStrangler.Test.Clinic.Legacy.NorthVisits", "Enum")
             )
           ) =~
             "branch :north: Enum is not a twin module"
  end

  test "a column no mapping answers, a mapping for no column, a column answered twice" do
    assert rejection(
             valid(north: String.replace(@north, "unmapped [:notes], because: \"none\"", ""))
           ) =~
             "branch :north: column :notes is not answered"

    assert rejection(valid(north: inside(@north, "map :ghost, from: :seen_on"))) =~
             ":ghost is not a declared column"

    assert rejection(valid(north: inside(@north, "constant :notes, \"x\""))) =~
             "mapping for column :notes is declared 2 times"
  end

  test "a mapping that reads a column the twin does not have" do
    assert rejection(valid(north: String.replace(@north, "from: :patient_name", "from: :nope"))) =~
             "branch :north: map reads :nope, which AshStrangler.Test.Clinic.Legacy.NorthVisits does not have"

    assert rejection(
             valid(
               north:
                 String.replace(@north, "from: :patient_name", "from: expr(nope <> patient_name)")
             )
           ) =~
             "map reads :nope"
  end

  test "a filter that reads a column the twin does not have" do
    assert rejection(valid(north: inside(@north, "filter expr(ghost == 1)"))) =~
             "branch :north: filter reads :ghost, which AshStrangler.Test.Clinic.Legacy.NorthVisits does not have"

    assert :ok =
             VerifyUnion.verify(
               probe(valid(north: inside(@north, "filter expr(seen_on > ^~D[2026-01-01])"))).spark_dsl_config()
             )
  end

  test "keys: none, two, an unsupported strategy, a key column the twin lacks" do
    key = ~S|key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}|

    assert rejection(valid(north: String.replace(@north, key, ""))) =~
             "branch :north: declare exactly one `key` (found 0)"

    assert rejection(valid(north: inside(@north, key))) =~ "(found 2)"

    assert rejection(valid(north: String.replace(@north, key, "key :id, strategy: :hash"))) =~
             "unsupported key strategy :hash"

    assert rejection(
             valid(north: String.replace(@north, key, ~S|key :nope, strategy: :identity|))
           ) =~
             "key reads :nope"
  end

  test "two branches sharing a key namespace would collide" do
    shared =
      String.replace(
        @south,
        "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d",
        "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"
      )

    assert rejection(valid(south: shared)) =~ "share a key namespace"
  end

  test "an empty refusal reason" do
    assert rejection(valid(north: String.replace(@north, ~S|"north writes"|, ~S|" "|))) =~
             "`refused_because` is empty"
  end

  test "two columns mapped from one legacy column on a :dual_write branch" do
    columns = @columns <> "column :alias, :string"
    shared = inside(@south, "map :alias, from: :name")
    north = inside(@north, "unmapped [:alias], because: \"none\"")

    assert rejection(valid(columns: columns, north: north, south: shared)) =~
             "columns :patient, :alias are all mapped from :name"

    read_only = String.replace(shared, "phase :dual_write", "phase :read_from_legacy")

    assert :ok =
             VerifyUnion.verify(
               probe(valid(columns: columns, north: north, south: read_only)).spark_dsl_config()
             )

    expr = inside(@south, "map :alias, from: expr(name)")

    assert :ok =
             VerifyUnion.verify(
               probe(valid(columns: columns, north: north, south: expr)).spark_dsl_config()
             )
  end

  describe "write rules" do
    test "not_written_back on an owned branch, on an unknown column, and in two writers" do
      assert rejection(
               valid(owned: ~S|owned :native do not_written_back [:notes], because: "x" end|)
             ) =~ "owned branch takes no `not_written_back`"

      assert rejection(valid(south: inside(@south, ~S|not_written_back [:ghost], because: "x"|))) =~
               "`not_written_back` names :ghost, which is not a declared column"

      columns = @columns <> "column :alias, :string"
      north = inside(@north, "unmapped [:alias], because: \"none\"")
      shared = inside(@south, "map :alias, from: :name")

      assert rejection(valid(columns: columns, north: north, south: shared)) =~
               "are all mapped from :name"

      assert :ok =
               VerifyUnion.verify(
                 probe(
                   valid(
                     columns: columns,
                     north: north,
                     south: inside(shared, ~S|not_written_back [:alias], because: "x"|)
                   )
                 ).spark_dsl_config()
               )
    end

    test "an extension column is not also not_written_back, and refuse_delete is single" do
      columns = @columns <> "column :tpl, :string"
      north = inside(@north, "unmapped [:tpl], because: \"none\"")
      south = inside(@south, "extension [:tpl]")

      assert :ok =
               VerifyUnion.verify(
                 probe(valid(columns: columns, north: north, south: south)).spark_dsl_config()
               )

      assert rejection(
               valid(
                 columns: columns,
                 north: north,
                 south: inside(south, ~S|not_written_back [:tpl], because: "x"|)
               )
             ) =~ "stored in the extension table"

      twice = inside(@south, ~S|refuse_delete because: "a"| <> "\nrefuse_delete because: \"b\"")
      assert rejection(valid(south: twice)) =~ "at most one `refuse_delete`"
    end
  end
end
