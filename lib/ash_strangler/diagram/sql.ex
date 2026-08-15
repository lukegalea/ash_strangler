# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Diagram.Sql do
  @moduledoc """
  Works out which legacy columns a mapping expression reads.

  This is the one piece of the diagram that is *inferred* rather than declared.
  Everything else comes straight out of the DSL, but a `from:` expression is an
  opaque string — `AshStrangler` hands it to Postgres verbatim and never parses
  it, which is deliberate (see `AshStrangler.Sql.View`). Drawing an edge per
  source column means guessing which identifiers in that string are columns.

  ## It degrades visibly, never silently

  The extraction is a heuristic: strip string literals, casts and numbers, drop
  anything that looks like a function call or a SQL keyword, and treat what is
  left as column references. That is right for the expressions people actually
  write, and it will occasionally be wrong.

  So when it finds nothing at all it returns `:unresolved` rather than an empty
  list, and the caller draws a node saying so. A diagram that quietly omits the
  edges it could not work out is worse than no diagram, because a reader cannot
  tell the difference between "nothing feeds this" and "the generator gave up" —
  which is the same argument `unmapped` exists to make in the DSL itself.

  Pass `known_columns:` to intersect the result against the real table, which
  turns the heuristic into a filter and removes the guesswork entirely.
  """

  # Keywords that can appear in a mapping expression. Function names do not need
  # to be here -- they are dropped by the `(` rule -- so this is only the bare
  # words that would otherwise read as columns.
  @keywords ~w(
    and as asc at between by case cast collate cross current_date current_time
    current_timestamp default desc distinct else end escape exists false filter
    first from full group having ilike in inner interval into is join last
    lateral left like limit localtime localtimestamp natural not null nulls
    offset on or order outer over partition right select similar some symmetric
    then time timestamp true union unknown using when where with within zone
  )

  @keyword_set MapSet.new(@keywords)

  @typedoc """
  The columns an expression reads, or `:unresolved` when none could be found.
  """
  @type extraction() :: {:ok, [String.t()]} | :unresolved

  @doc """
  The legacy columns `expression` reads, in the order they first appear.

  Qualified references keep their qualifier (`"addr.city"`), because that is how
  a mapping says which relation it read from and the diagram needs to put the
  node in the right subgraph.

  ## Options

    * `:known_columns` — the columns the relation actually has. When given, the
      result is intersected with it, which turns the heuristic into a filter.
      Qualified references are matched on their qualifier and their bare name.

  ## Examples

      iex> AshStrangler.Diagram.Sql.columns("coalesce(first_name,'') || ' ' || coalesce(last_name,'')")
      {:ok, ["first_name", "last_name"]}

      iex> AshStrangler.Diagram.Sql.columns("CASE WHEN is_deleted THEN 'archived' ELSE 'pending' END")
      {:ok, ["is_deleted"]}

      iex> AshStrangler.Diagram.Sql.columns("now()")
      :unresolved
  """
  @spec columns(String.t() | nil, keyword()) :: extraction()
  def columns(expression, opts \\ [])

  def columns(nil, _opts), do: :unresolved

  def columns(expression, opts) when is_binary(expression) do
    found =
      expression
      |> strip_literals()
      |> scan_identifiers()
      |> Enum.reject(&keyword?/1)
      |> Enum.uniq()
      |> restrict(opts[:known_columns])

    case found do
      [] -> :unresolved
      columns -> {:ok, columns}
    end
  end

  @doc """
  Collapses an expression onto one line and shortens it for use as a label.

  Mapping expressions are written as heredocs and carry newlines and runs of
  indentation, neither of which survive a Mermaid label. Truncation is honest
  rather than clever -- no attempt is made to summarise a `CASE` into something
  shorter, because a summary that drops an arm is a diagram that lies.
  """
  @spec summarize(String.t(), pos_integer()) :: String.t()
  def summarize(expression, limit \\ 64) when is_binary(expression) do
    collapsed =
      expression
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(collapsed) <= limit do
      collapsed
    else
      collapsed
      |> String.slice(0, limit - 3)
      |> trim_to_word()
      |> Kernel.<>("...")
    end
  end

  # Cut at a word boundary rather than mid-token. A label ending "and no r..."
  # reads as a rendering fault; ending "and no..." reads as elision. It matters
  # most for `because:` reasons, where the label *is* the payload -- carrying
  # why a value cannot travel back is half the point of drawing the mapping.
  #
  # Only when a boundary is near the end: a long unbroken token (a URL, a
  # snake_case identifier) has no useful boundary, and backing up to the
  # previous space would drop more than the ragged edge costs.
  defp trim_to_word(text) do
    trimmed = String.trim_trailing(text)

    case :binary.matches(trimmed, " ") do
      [] ->
        trimmed

      matches ->
        {last, _} = List.last(matches)

        if last >= byte_size(trimmed) - 12 do
          trimmed |> binary_part(0, last) |> String.trim_trailing()
        else
          trimmed
        end
    end
  end

  # Single-quoted literals become spaces so `'demo_legacy.accounts:'` cannot
  # contribute a phantom `accounts` column, and `::type` casts go the same way.
  # Double-quoted identifiers are kept -- those are real column references.
  @spec strip_literals(String.t()) :: String.t()
  defp strip_literals(expression) do
    expression
    |> String.replace(~r/'(?:[^']|'')*'/, " ")
    |> String.replace(~r/::\s*[a-zA-Z_][a-zA-Z0-9_]*(\s*\[\s*\])?/, " ")
    |> String.replace(~r/\b\d[\d.]*\b/, " ")
  end

  # An identifier not followed by `(` -- the parenthesis is what separates
  # `coalesce(` from the `first_name` inside it.
  @spec scan_identifiers(String.t()) :: [String.t()]
  defp scan_identifiers(expression) do
    ~r/"?([a-zA-Z_][a-zA-Z0-9_]*)"?(\s*\.\s*"?([a-zA-Z_][a-zA-Z0-9_]*)"?)?(\s*\()?/
    |> Regex.scan(expression)
    |> Enum.flat_map(&identifier/1)
  end

  # A trailing `(` means the whole reference was a function call.
  defp identifier([_full, _head, _dotted, _tail, "" <> _ = paren]) when paren != "", do: []
  defp identifier([_full, head, _dotted, tail | _]) when tail != "", do: [head <> "." <> tail]
  defp identifier([_full, head | _]), do: [head]

  @spec keyword?(String.t()) :: boolean()
  defp keyword?(identifier) do
    identifier
    |> String.split(".")
    |> Enum.all?(&MapSet.member?(@keyword_set, String.downcase(&1)))
  end

  @spec restrict([String.t()], [String.t()] | nil) :: [String.t()]
  defp restrict(columns, nil), do: columns

  defp restrict(columns, known) do
    known_set = MapSet.new(known, &String.downcase/1)

    Enum.filter(columns, fn column ->
      bare = column |> String.split(".") |> List.last() |> String.downcase()

      MapSet.member?(known_set, String.downcase(column)) or MapSet.member?(known_set, bare)
    end)
  end
end
