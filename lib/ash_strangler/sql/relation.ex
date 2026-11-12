# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Relation do
  @moduledoc """
  Reads a relation named by a person, the way SQL would.

  A relation that comes from a twin never goes through here: `AshStrangler.Twin.schema_and_table/1`
  hands over the schema and the table separately, and nothing re-parses a string the library
  built itself. This is for the strings that genuinely arrive from outside, such as the
  `legacy.users` of `mix ash_strangler.gen.twin legacy.users` or the `schema.table.column` of a
  `--secret`.

  An unquoted dot separates two names. A double-quoted name may contain dots, and a doubled
  quote inside it stands for one quote: `"odd.schema".t` is the schema `odd.schema` and the
  table `t`. An unquoted name is taken as written, without PostgreSQL's folding to lower case,
  because the legacy catalog is spelled with the case it was created with.
  """

  @type parts :: {schema :: String.t() | nil, table :: String.t()}

  @doc """
  The schema and table of `text`: `{schema, table}` for `schema.table`, `{nil, table}` for a bare
  `table`.

  Anything else (an empty name, an unterminated quote, more than two names) is refused with a
  message that quotes the input.
  """
  @spec parse(String.t()) :: {:ok, parts()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    case names(text) do
      {:ok, [table]} -> {:ok, {nil, table}}
      {:ok, [schema, table]} -> {:ok, {schema, table}}
      {:ok, _more} -> {:error, "expected table or schema.table, got #{inspect(text)}"}
      {:error, reason} -> {:error, "#{reason} in #{inspect(text)}"}
    end
  end

  @doc "`parse/1`, raising `ArgumentError` on a refusal."
  @spec parse!(String.t()) :: parts()
  def parse!(text) do
    case parse(text) do
      {:ok, parts} -> parts
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  The schema, table and column of `text`, which must name all three: `schema.table.column`.
  """
  @spec parse_column(String.t()) :: {:ok, {String.t(), String.t(), String.t()}} | {:error, String.t()}
  def parse_column(text) when is_binary(text) do
    case names(text) do
      {:ok, [schema, table, column]} -> {:ok, {schema, table, column}}
      {:ok, _other} -> {:error, "expected schema.table.column, got #{inspect(text)}"}
      {:error, reason} -> {:error, "#{reason} in #{inspect(text)}"}
    end
  end

  @doc """
  The names `text` is made of, split on its unquoted dots.
  """
  @spec names(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def names(text) when is_binary(text), do: read(text, [])

  defp read("", _acc), do: {:error, "an empty name"}

  defp read(<<?", rest::binary>>, acc) do
    with {:ok, name, rest} <- quoted(rest, []) do
      case rest do
        "" -> {:ok, Enum.reverse([name | acc])}
        <<".", more::binary>> -> read(more, [name | acc])
        _ -> {:error, "text after a closing quote"}
      end
    end
  end

  defp read(text, acc) do
    {name, rest} = unquoted(text, [])

    cond do
      name == "" -> {:error, "an empty name"}
      String.contains?(name, ~s(")) -> {:error, "a quote inside an unquoted name"}
      rest == "" -> {:ok, Enum.reverse([name | acc])}
      true -> read(String.slice(rest, 1..-1//1), [name | acc])
    end
  end

  defp unquoted("." <> _ = rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp unquoted("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp unquoted(<<char, rest::binary>>, acc), do: unquoted(rest, [<<char>> | acc])

  defp quoted("", _acc), do: {:error, "an unterminated quote"}
  defp quoted(<<?", ?", rest::binary>>, acc), do: quoted(rest, [~s(") | acc])

  defp quoted(<<?", rest::binary>>, acc) do
    case acc |> Enum.reverse() |> IO.iodata_to_binary() do
      "" -> {:error, "an empty quoted name"}
      name -> {:ok, name, rest}
    end
  end

  defp quoted(<<char, rest::binary>>, acc), do: quoted(rest, [<<char>> | acc])
end
