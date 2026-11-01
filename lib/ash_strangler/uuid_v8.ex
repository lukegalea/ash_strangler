# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.UuidV8 do
  @moduledoc """
  Packs one or more legacy integers into an RFC 9562 version 8 UUID, and back.

  This is the invertible key: the canonical id of a row keyed by integers *is*
  those integers, behind a tag that says which estate and which kind of row
  they identify. No lookup table, no `legacy_id` column, and the legacy key is
  recoverable from the id alone.

  ## Layout

      bits   0..15   estate tag (16 bits)      ┐
      bits  16..27   kind tag (12 bits)        │ custom_a (48)
      bits  28..47   payload[0..19]            ┘
      bits  48..51   version 0b1000
      bits  52..63   payload[20..31]             custom_b (12)
      bits  64..65   variant 0b10
      bits  66..127  payload[32..93]             custom_c (62)

  The payload is 94 bits: the parts, each in its declared width (16, 32 or
  64), most significant first, then zeros. Each part is stored in **offset
  binary** (the sign bit flipped), so within one kind the UUIDs sort exactly as
  the legacy keys do, negative values included.

  ## One definition, two printers

  `encode/4` and `decode/4` are the Elixir side; `sql/4` and `part_sql/5` print
  the same functions as PostgreSQL expressions. The SQL uses only immutable
  built-ins (`bit` casts, `#`, `||`, `overlay`, `varbit_send`, `encode`), so an
  expression index over `sql/4` is legal and a view column built from it is
  indexable. The test suite asserts SQL and Elixir agree over generated inputs
  across every width.
  """

  import Bitwise

  @payload_bits 94
  @widths [16, 32, 64]

  @typedoc "A part width, in bits."
  @type width :: 16 | 32 | 64

  @doc "The widths a part may have."
  @spec widths() :: [width()]
  def widths, do: @widths

  @doc "How many payload bits the parts of a kind may use in total."
  @spec payload_bits() :: pos_integer()
  def payload_bits, do: @payload_bits

  @doc """
  The UUID for `parts` under `estate` and `tag`, as a lowercase hyphenated
  string. `nil` when any part is `nil`, as a SQL expression over a NULL column
  would be.

      iex> AshStrangler.UuidV8.encode(0x4C42, 0x001, [64], [42])
      "4c420018-0000-8000-8000-000a80000000"

  Raises `ArgumentError` when a part does not fit its width, or when the parts
  and widths disagree in number.
  """
  @spec encode(non_neg_integer(), non_neg_integer(), [width()], [integer() | nil]) ::
          String.t() | nil
  def encode(estate, tag, widths, parts) do
    check_header!(estate, tag, widths)

    if length(parts) != length(widths) do
      raise ArgumentError,
            "expected #{length(widths)} parts for widths #{inspect(widths, charlists: :as_lists)}, got #{inspect(parts, charlists: :as_lists)}"
    end

    if Enum.any?(parts, &is_nil/1) do
      nil
    else
      payload =
        widths
        |> Enum.zip(parts)
        |> Enum.reduce(<<>>, fn {width, part}, acc ->
          <<acc::bitstring, offset!(part, width)::size(width)>>
        end)

      pad = @payload_bits - bit_size(payload)
      <<a::20, b::12, c::62>> = <<payload::bitstring, 0::size(pad)>>

      format(<<estate::16, tag::12, a::20, 8::4, b::12, 2::2, c::62>>)
    end
  end

  @doc """
  The parts packed in `uuid`, when it carries `estate`, `tag`, version 8, the
  RFC variant and a zero pad; `:error` otherwise.
  """
  @spec decode(non_neg_integer(), non_neg_integer(), [width()], String.t()) ::
          {:ok, [integer()]} | :error
  def decode(estate, tag, widths, uuid) when is_binary(uuid) do
    check_header!(estate, tag, widths)

    case split(uuid) do
      {:ok, {^estate, ^tag, payload}} -> unpack(payload, widths)
      _ -> :error
    end
  end

  @doc """
  The estate tag, kind tag and 94-bit payload of a version 8 UUID, or `:error`
  when `uuid` is not a version 8 RFC-variant UUID.
  """
  @spec split(String.t()) :: {:ok, {non_neg_integer(), non_neg_integer(), bitstring()}} | :error
  def split(uuid) when is_binary(uuid) do
    case bytes(uuid) do
      {:ok, <<estate::16, tag::12, a::20, 8::4, b::12, 2::2, c::62>>} ->
        {:ok, {estate, tag, <<a::20, b::12, c::62>>}}

      _ ->
        :error
    end
  end

  @doc false
  @spec unpack(bitstring(), [width()]) :: {:ok, [integer()]} | :error
  def unpack(payload, widths) do
    {parts, rest} =
      Enum.map_reduce(widths, payload, fn width, bits ->
        <<value::size(^width), rest::bitstring>> = bits
        {value - (1 <<< (width - 1)), rest}
      end)

    pad = bit_size(rest)

    case rest do
      <<0::size(^pad)>> -> {:ok, parts}
      _ -> :error
    end
  end

  @doc """
  A PostgreSQL expression of type `uuid` equal to `encode/4` over the values
  of `part_sql`, one SQL expression per part (typically column references).

  NULL when any part is NULL.
  """
  @spec sql(non_neg_integer(), non_neg_integer(), [width()], [String.t()]) :: String.t()
  def sql(estate, tag, widths, part_sql) do
    check_header!(estate, tag, widths)

    payload =
      widths
      |> Enum.zip(part_sql)
      |> Enum.map(fn {width, part} -> part_bits(width, part) end)

    pad = @payload_bits - Enum.sum(widths)
    bits = Enum.join([header_literal(estate, tag) | payload] ++ pad_literal(pad), " || ")

    # Parenthesised whole: a bare trailing cast is not a valid index
    # expression, and the view and its expression index print the same text.
    "(encode(substring(varbit_send(overlay(overlay((#{bits}) placing B'1000' from 49 for 0) " <>
      "placing B'10' from 65 for 0)) from 5), 'hex')::uuid)"
  end

  @doc """
  A PostgreSQL expression for part `index` (zero-based) of the UUID that
  `uuid_sql` evaluates to: the inverse of `sql/4`, typed `smallint`, `integer`
  or `bigint` by the part's width.

  NULL when the UUID is NULL. A UUID that is not of this estate and kind is
  not silently decoded into a wrong integer: the expression fails with
  `invalid input syntax for type ...` quoting the offending UUID.
  """
  @spec part_sql(non_neg_integer(), non_neg_integer(), [width()], non_neg_integer(), String.t()) ::
          String.t()
  def part_sql(estate, tag, widths, index, uuid_sql) do
    check_header!(estate, tag, widths)

    width =
      Enum.at(widths, index) ||
        raise ArgumentError, "no part #{index} in #{inspect(widths, charlists: :as_lists)}"

    offset = widths |> Enum.take(index) |> Enum.sum()

    bits = "('x' || translate((#{uuid_sql})::text, '-', ''))::bit(128)"

    payload =
      "(substring(#{bits} from 29 for 20) || substring(#{bits} from 53 for 12) || " <>
        "substring(#{bits} from 67 for 62))"

    expected = header_literal(estate, tag)
    used = Enum.sum(widths)

    guard =
      "substring(#{bits} from 1 for 28) = (#{expected}) AND substring(#{bits} from 49 for 4) = B'1000' " <>
        "AND substring(#{bits} from 65 for 2) = B'10'" <>
        if(used < @payload_bits,
          do:
            " AND substring(#{payload} from #{used + 1}) = #{zero_literal(@payload_bits - used)}",
          else: ""
        )

    part = "substring(#{payload} from #{offset + 1} for #{width})"
    {value, type} = part_value(width, part)

    "(CASE WHEN (#{uuid_sql}) IS NULL THEN NULL WHEN #{guard} THEN #{value} " <>
      "ELSE ('not a key of this kind: ' || (#{uuid_sql})::text)::#{type} END)"
  end

  # --- helpers ---------------------------------------------------------------

  # Offset binary of a part: the sign bit flipped, so unsigned order is signed
  # order.
  defp offset!(part, width) when is_integer(part) do
    half = 1 <<< (width - 1)

    if part < -half or part >= half do
      raise ArgumentError, "#{part} does not fit in a #{width}-bit part"
    end

    part + half
  end

  defp offset!(part, width),
    do: raise(ArgumentError, "expected an integer for a #{width}-bit part, got: #{inspect(part)}")

  # The SQL mirror of `offset!/2`: the column's two's complement bits in the
  # part's width, sign bit flipped. `integer::bit(n)` keeps the rightmost n bits.
  defp part_bits(16, part), do: "((#{part})::int4::bit(16) # X'8000')"
  defp part_bits(32, part), do: "((#{part})::int4::bit(32) # X'80000000')"
  defp part_bits(64, part), do: "((#{part})::int8::bit(64) # X'8000000000000000')"

  # bit(16) casts to an unsigned integer, so the 16-bit part subtracts its
  # offset; the 32- and 64-bit parts flip the sign bit back and let the cast
  # read two's complement.
  defp part_value(16, part), do: {"((#{part})::int4 - 32768)::int2", "int2"}
  defp part_value(32, part), do: {"((#{part}) # X'80000000')::int4", "int4"}
  defp part_value(64, part), do: {"((#{part}) # X'8000000000000000')::int8", "int8"}

  defp pad_literal(0), do: []
  defp pad_literal(pad), do: [zero_literal(pad)]

  defp zero_literal(bits), do: "B'" <> String.duplicate("0", bits) <> "'"

  # The estate and kind tags, as one 28-bit literal.
  defp header_literal(estate, tag), do: "B'" <> binary(estate, 16) <> binary(tag, 12) <> "'"

  defp binary(value, bits), do: String.pad_leading(Integer.to_string(value, 2), bits, "0")

  defp check_header!(estate, tag, widths) do
    cond do
      not (is_integer(estate) and estate in 0..0xFFFF) ->
        raise ArgumentError, "estate tag must be an integer in 0..0xFFFF, got: #{inspect(estate)}"

      not (is_integer(tag) and tag in 1..0xFFF) ->
        raise ArgumentError, "kind tag must be an integer in 1..0xFFF, got: #{inspect(tag)}"

      widths == [] or Enum.any?(widths, &(&1 not in @widths)) ->
        raise ArgumentError, "part widths must be a non-empty list of 16, 32 or 64"

      Enum.sum(widths) > @payload_bits ->
        raise ArgumentError,
              "part widths #{inspect(widths, charlists: :as_lists)} sum to #{Enum.sum(widths)} bits; a v8 payload holds #{@payload_bits}"

      true ->
        :ok
    end
  end

  defp bytes(uuid) do
    case Base.decode16(String.replace(uuid, "-", ""), case: :mixed) do
      {:ok, <<_::binary-size(16)>> = bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp format(
         <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(6)>>
       ) do
    Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
  end
end
