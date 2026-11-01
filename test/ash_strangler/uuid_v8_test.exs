# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UuidV8Test do
  @moduledoc """
  The packed key is one definition printed twice, so the claims under test are:

    * decode inverts encode, for every width and every value a part can hold;
    * the SQL printer and the Elixir function agree, over 10^5 generated cases
      spread across every width combination, in both directions;
    * a UUID of another estate, kind, version or pad never decodes.
  """

  use AshStrangler.DataCase, async: true
  use ExUnitProperties

  import Bitwise

  alias AshStrangler.{KeyKinds, UuidV8}
  alias AshStrangler.Test.Library.Keys

  @estate 0x4C42

  # Every combination the 94-bit payload admits, in order.
  @combinations [
    [16],
    [32],
    [64],
    [16, 16],
    [16, 32],
    [32, 16],
    [16, 64],
    [64, 16],
    [32, 32],
    [16, 16, 16],
    [16, 16, 32],
    [32, 32, 16],
    [16, 16, 16, 16],
    [16, 16, 16, 32]
  ]

  defp range(width), do: -(1 <<< (width - 1))..((1 <<< (width - 1)) - 1)

  defp part(width) do
    min..max//_ = range(width)
    StreamData.one_of([StreamData.member_of([min, max, -1, 0, 1]), StreamData.integer(min..max)])
  end

  defp parts(widths), do: widths |> Enum.map(&part/1) |> StreamData.fixed_list()

  describe "the Elixir printer" do
    test "matches the documented layout" do
      assert UuidV8.encode(@estate, 0x001, [64], [42]) == "4c420018-0000-8000-8000-000a80000000"

      <<_::binary-size(14), version::binary-size(1), _::binary-size(4), variant::binary-size(1),
        _::binary>> = UuidV8.encode(@estate, 0x123, [32, 16], [7, -7])

      assert version == "8"
      assert variant in ["8", "9", "a", "b"]
    end

    property "decode inverts encode for every width combination" do
      check all(
              widths <- StreamData.member_of(@combinations),
              tag <- StreamData.integer(1..0xFFF),
              values <- parts(widths),
              max_runs: 2_000
            ) do
        uuid = UuidV8.encode(@estate, tag, widths, values)
        assert UuidV8.decode(@estate, tag, widths, uuid) == {:ok, values}
      end
    end

    property "within a kind, uuid order is the legacy key's order" do
      check all(
              widths <- StreamData.member_of(@combinations),
              a <- parts(widths),
              b <- parts(widths),
              max_runs: 500
            ) do
        ua = UuidV8.encode(@estate, 1, widths, a)
        ub = UuidV8.encode(@estate, 1, widths, b)
        assert compare(ua, ub) == compare(a, b)
      end
    end

    test "a part that does not fit its width is refused" do
      assert_raise ArgumentError, ~r/does not fit in a 16-bit part/, fn ->
        UuidV8.encode(@estate, 1, [16], [32_768])
      end

      assert_raise ArgumentError, ~r/sum to 96 bits/, fn ->
        UuidV8.encode(@estate, 1, [64, 32], [1, 1])
      end
    end

    test "a nil part encodes to nil, as SQL's NULL would" do
      assert UuidV8.encode(@estate, 1, [16, 32], [1, nil]) == nil
    end

    test "never decodes a uuid of another estate, kind, version or pad" do
      uuid = UuidV8.encode(@estate, 7, [32], [99])

      assert UuidV8.decode(@estate + 1, 7, [32], uuid) == :error
      assert UuidV8.decode(@estate, 8, [32], uuid) == :error
      assert UuidV8.decode(@estate, 7, [32], Ash.UUID.generate()) == :error
      # Same tag, but the payload was packed for a narrower layout: the pad is
      # not zero.
      assert UuidV8.decode(@estate, 7, [16], uuid) == :error
      assert UuidV8.decode(@estate, 7, [32], "not a uuid") == :error
    end
  end

  describe "the registry" do
    test "encodes and decodes by kind name" do
      uuid = KeyKinds.encode(Keys, :copy, [3, 9_000_000_000])

      assert KeyKinds.decode(Keys, uuid) == {:ok, {:copy, [3, 9_000_000_000]}}
      assert KeyKinds.decode(Keys, :copy, uuid) == {:ok, [3, 9_000_000_000]}
      assert KeyKinds.decode(Keys, :member, uuid) == :error
      assert KeyKinds.decode(Keys, Ash.UUID.generate()) == :error
    end

    test "equal integers of different kinds are different ids" do
      refute KeyKinds.encode(Keys, :member, [1]) == KeyKinds.encode(Keys, :loan, [1])
    end
  end

  describe "SQL against Elixir" do
    # 10^5 cases in total, sent as arrays so each width combination is one
    # round trip per batch rather than one per case.
    @cases 100_000
    @batch 10_000

    test "the SQL printer equals the Elixir printer, and each decodes the other" do
      per_combination = div(@cases, length(@combinations)) + 1

      total =
        for widths <- @combinations, reduce: 0 do
          count ->
            tag = :rand.uniform(0xFFF)

            values = Enum.map(1..per_combination, fn _ -> Enum.map(widths, &random_part/1) end)

            values
            |> Enum.chunk_every(@batch)
            |> Enum.each(&assert_agree(widths, tag, &1))

            count + length(values)
        end

      assert total >= @cases
    end

    defp assert_agree(widths, tag, rows) do
      columns = Enum.zip(rows |> Enum.zip_with(& &1) |> Enum.with_index(), widths)

      unnest =
        Enum.map_join(columns, ", ", fn {{_values, index}, width} ->
          "$#{index + 1}::#{pg_type(width)}[]"
        end)

      names = Enum.map_join(0..(length(widths) - 1), ", ", &"p#{&1}")
      parts = Enum.map(0..(length(widths) - 1), &"p#{&1}")
      encoded = UuidV8.sql(@estate, tag, widths, parts)

      decoded =
        Enum.map_join(0..(length(widths) - 1), ", ", fn index ->
          UuidV8.part_sql(@estate, tag, widths, index, "($#{length(widths) + 1}::uuid[])[n]")
        end)

      sql = """
      SELECT (#{encoded})::text, #{decoded}
      FROM unnest(#{unnest}) WITH ORDINALITY AS t(#{names}, n)
      ORDER BY n
      """

      elixir = Enum.map(rows, &UuidV8.encode(@estate, tag, widths, &1))
      params = Enum.map(columns, fn {{values, _index}, _width} -> values end)

      %{rows: result} =
        TestRepo.query!(sql, params ++ [Enum.map(elixir, &Ecto.UUID.dump!/1)])

      for {[sql_uuid | sql_parts], elixir_uuid, values} <- Enum.zip([result, elixir, rows]) do
        assert sql_uuid == elixir_uuid,
               "SQL #{sql_uuid} != Elixir #{elixir_uuid} for #{inspect(values)}"

        assert sql_parts == values,
               "SQL decoded #{inspect(sql_parts)}, expected #{inspect(values)}"

        assert UuidV8.decode(@estate, tag, widths, sql_uuid) == {:ok, values}
      end
    end

    test "the SQL decode refuses a key of another kind instead of misreading it" do
      foreign = UuidV8.encode(@estate, 2, [32], [5])
      sql = "SELECT #{UuidV8.part_sql(@estate, 1, [32], 0, "$1::uuid")}"

      assert_raise Postgrex.Error, ~r/not a key of this kind/, fn ->
        TestRepo.query!(sql, [Ecto.UUID.dump!(foreign)])
      end

      assert %{rows: [[nil]]} = TestRepo.query!(sql, [nil])
    end

    test "the SQL refuses a part too wide for its width, as the Elixir encoder does" do
      for width <- [16, 32, 64], value <- [-(1 <<< (width - 1)) - 1, 1 <<< (width - 1)] do
        assert_raise ArgumentError, ~r/does not fit in a #{width}-bit part/, fn ->
          UuidV8.encode(@estate, 1, [width], [value])
        end

        sql = "SELECT (#{UuidV8.sql(@estate, 1, [width], ["$1::numeric"])})::text"

        assert_raise Postgrex.Error, ~r/out of range/, fn ->
          TestRepo.query!(sql, [Decimal.new(value)])
        end
      end
    end

    test "the SQL is immutable, so it can back an expression index" do
      TestRepo.query!("CREATE TEMP TABLE packed_probe (a smallint, b bigint)", [])

      TestRepo.query!(
        "CREATE INDEX ON packed_probe ((#{UuidV8.sql(@estate, 3, [16, 64], ["a", "b"])}))",
        []
      )
    end
  end

  # A uniform draw over the whole width, with the edges a fifth of the time.
  defp random_part(width) do
    min..max//_ = range(width)

    if :rand.uniform(5) == 1,
      do: Enum.random([min, max, -1, 0, 1]),
      else: Enum.random(min..max)
  end

  defp pg_type(16), do: "int2"
  defp pg_type(32), do: "int4"
  defp pg_type(64), do: "int8"

  defp compare(a, b) when a < b, do: :lt
  defp compare(a, b) when a > b, do: :gt
  defp compare(_a, _b), do: :eq
end
