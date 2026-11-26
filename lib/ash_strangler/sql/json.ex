# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Json do
  @moduledoc """
  The guards that read a JSON value as SQL, shared by a derived view's `element`
  sources and a union's `json_key` columns, so both read a value the same way.

  A value of another JSON type reads NULL, and so does a number that is not an
  integer in the range of the integer type it is read as: `12.5`, `1e10` and
  `"12"` are refused, never cast. Each guard is a `CASE`, never an `AND`:
  PostgreSQL does not promise to stop at the first false operand, and the cast
  raises for a value that is not a number.
  """

  @doc """
  `json`, a jsonb expression, as an integer of `width` bits (`smallint`,
  `integer` or `bigint`), or NULL.
  """
  @spec integer(String.t(), 16 | 32 | 64) :: String.t()
  def integer(json, width \\ 32) do
    {min, max, type} = bounds(width)

    "CASE WHEN jsonb_typeof(#{json}) = 'number' THEN " <>
      "CASE WHEN (#{json})::numeric = trunc((#{json})::numeric) AND (#{json})::numeric BETWEEN #{min} AND #{max} " <>
      "THEN ((#{json})::numeric)::#{type} END END"
  end

  @doc "`json`, a jsonb expression, as text when it is a JSON string, or NULL."
  @spec text(String.t()) :: String.t()
  def text(json), do: "CASE WHEN jsonb_typeof(#{json}) = 'string' THEN #{json} #>> '{}' END"

  defp bounds(16), do: {-32_768, 32_767, "smallint"}
  defp bounds(32), do: {-2_147_483_648, 2_147_483_647, "integer"}
  defp bounds(64), do: {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807, "bigint"}
end
