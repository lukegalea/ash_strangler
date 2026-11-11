# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.ObjectName do
  @moduledoc false
  # PostgreSQL stores an identifier of at most 63 **bytes**, and when a name is longer it
  # cuts it on a character boundary without complaint. These helpers do the same cut, so
  # the trigger modules can name an object exactly as PostgreSQL would store it, and can
  # take a table prefix that never splits a UTF-8 sequence.

  @max_bytes 63

  @doc "The longest identifier PostgreSQL stores, in bytes."
  def max_bytes, do: @max_bytes

  @doc "The name as PostgreSQL stores it: at most 63 bytes, cut on a character boundary."
  def truncate(name), do: byte_prefix(name, @max_bytes)

  @doc "The longest prefix of `string` of at most `max` bytes that ends on a character boundary."
  def byte_prefix(string, max) when is_binary(string) and is_integer(max) and max >= 0 do
    if byte_size(string) <= max, do: string, else: do_prefix(string, max, [])
  end

  defp do_prefix(<<char::utf8, rest::binary>>, left, acc) do
    size = byte_size(<<char::utf8>>)
    if size <= left, do: do_prefix(rest, left - size, [<<char::utf8>> | acc]), else: join(acc)
  end

  defp do_prefix(_rest, _left, acc), do: join(acc)

  defp join(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc "The first 8 hex characters of a SHA-256 of the table name."
  def hash(table),
    do: :sha256 |> :crypto.hash(table) |> Base.encode16(case: :lower) |> binary_part(0, 8)
end
