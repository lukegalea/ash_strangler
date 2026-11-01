# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Snapshot.Types do
  @moduledoc """
  The Ash type a legacy column takes on its twin, decided once.

  `mix ash_strangler.gen.twin` writes twins with it and
  `AshStrangler.Verifiers.VerifySnapshot` checks twins against it. One function
  serving both is what makes "the generated twin passes the verifier" a property
  of the code rather than a coincidence of two tables kept in step by hand.

  The input is a column from an `AshStrangler.Snapshot.Catalog`, so the answer
  depends only on the pinned catalog and never on a live database.

  ## `CHECK (col IN (...))` becomes `:atom` with `one_of`, and that is load-bearing

  A textual column with a `CHECK` constraint naming its values, or a column of
  a Postgres enum type, is typed `:atom` with `one_of` rather than `:string`.
  `AshStrangler.Obligations` decides `GetTotal` by enumerating the legacy
  column's domain. With `one_of` the domain exists and a `decode` that forgets
  a value fails the build. Without it the obligation degrades to a SQL
  assertion that `mix ash_strangler.check` measures against rows.

  The parse is deliberately conservative. PostgreSQL normalises `IN (...)` to
  `= ANY (ARRAY[...])`, and only that shape (the whole constraint, over one
  column, with literal operands) is read. A value set combined with anything
  else produces `:string` and a note: a `one_of` that is too wide is as wrong as
  one that is too narrow.
  """

  @types %{
    "int2" => :integer,
    "int4" => :integer,
    "int8" => :integer,
    "float4" => :float,
    "float8" => :float,
    "numeric" => :decimal,
    "bool" => :boolean,
    "text" => :string,
    "varchar" => :string,
    "bpchar" => :string,
    "citext" => :ci_string,
    "uuid" => :uuid,
    "date" => :date,
    "time" => :time,
    "timestamp" => :naive_datetime,
    "timestamptz" => :utc_datetime_usec,
    "json" => :map,
    "jsonb" => :map,
    "bytea" => :binary
  }

  @textual ~w(text varchar bpchar citext)

  @typedoc "What a twin declares for a column: its type, and its value set when it has one."
  @type typed :: %{
          type: atom() | {:array, atom()},
          one_of: [String.t()] | nil,
          note: String.t() | nil
        }

  @doc """
  The twin attribute type for `column` of `relation` in `catalog`.

  Returns `{:ok, typed}`, or `{:omit, note}` when PostgreSQL's type has no Ash
  type. An omitted column is not declared on the twin, and `note` says why in
  words a generated file can carry as a comment.
  """
  @spec for_column(map(), map(), map()) :: {:ok, typed()} | {:omit, String.t()}
  def for_column(column, relation, catalog) do
    udt = base_udt(column["udt"], catalog)

    cond do
      enum = column["array"] == false && get_in(catalog, ["enums", udt]) ->
        {:ok, %{type: :atom, one_of: enum, note: nil}}

      column["array"] ->
        case @types[type_name(udt)] do
          nil -> {:omit, untyped_note(column)}
          type -> {:ok, %{type: {:array, type}, one_of: nil, note: nil}}
        end

      type_name(udt) in @textual ->
        {:ok, textual(column, relation, @types[type_name(udt)])}

      type = @types[type_name(udt)] ->
        {:ok, %{type: type, one_of: nil, note: nil}}

      true ->
        {:omit, untyped_note(column)}
    end
  end

  @doc """
  The literal values of a `CHECK` constraint over `column`, when the constraint
  is exactly `column IN (...)` (or `column = 'only'`). `:error` otherwise.
  """
  @spec check_values(String.t(), String.t()) :: {:ok, [String.t()]} | :error
  def check_values(definition, column) do
    body = strip_check(definition)

    with true <- any_form?(body, column),
         [_ | _] = literals <- literals(body) do
      {:ok, literals}
    else
      _ -> equality_form(body, column)
    end
  end

  # A domain is typed by what it is a domain over.
  defp base_udt(udt, catalog) do
    case get_in(catalog, ["domains", udt]) do
      %{"udt" => base} -> base_udt(base, catalog)
      nil -> udt
    end
  end

  defp type_name(udt), do: udt |> String.split(".", parts: 2) |> List.last()

  defp textual(column, relation, type) do
    checks =
      relation
      |> Map.get("checks", [])
      |> Enum.filter(&(&1["columns"] == [column["name"]]))

    case Enum.find(checks, & &1["values"]) do
      %{"values" => values} ->
        %{type: :atom, one_of: values, note: nil}

      nil when checks == [] ->
        %{type: type, one_of: nil, note: nil}

      nil ->
        %{type: type, one_of: nil, note: unparsed_note(column, hd(checks))}
    end
  end

  defp unparsed_note(column, check) do
    """
    `#{column["name"]}` carries a CHECK constraint this generator did not parse:

      #{check["definition"]}

    Only `CHECK (col IN (...))` -- which PostgreSQL stores as `= ANY (ARRAY[...])`
    -- yields a value set. Without one there is no domain to enumerate, so a
    `decode` over this column cannot be proven total at compile time and
    `mix ash_strangler.check` measures it against the rows instead.
    """
  end

  defp untyped_note(column) do
    """
    `#{column["name"]}` is `#{column["type"]}`, which has no Ash type, so it is not declared here.

    A mapping cannot read it as a typed reference. It is reachable only through
    `expr(fragment("..."))`, which classifies opaque -- no derived inverse, no
    lineage, `because:` required.
    """
  end

  # --- the CHECK parse ---------------------------------------------------

  # PostgreSQL rewrites `IN (...)` into `= ANY (ARRAY[...])` and prints the
  # result, so that is the only shape worth matching. Both variants appear: a
  # `text` column gives `(col = ANY (ARRAY['a'::text, ...]))` and a `varchar` one
  # gives `((col)::text = ANY ((ARRAY['a'::character varying, ...])::text[]))`.
  defp strip_check(definition) do
    definition
    |> String.replace(~r/^CHECK\s*\(/, "")
    |> String.replace(~r/\)$/, "")
    |> String.trim()
    |> unwrap_parens()
  end

  defp unwrap_parens("(" <> rest = body) do
    if String.ends_with?(rest, ")") and balanced?(String.slice(rest, 0..-2//1)) do
      rest |> String.slice(0..-2//1) |> String.trim() |> unwrap_parens()
    else
      body
    end
  end

  defp unwrap_parens(body), do: body

  defp balanced?(body) do
    body
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      _grapheme, depth when depth < 0 -> {:halt, -1}
      "(", depth -> {:cont, depth + 1}
      ")", depth -> {:cont, depth - 1}
      _grapheme, depth -> {:cont, depth}
    end)
    |> Kernel.==(0)
  end

  defp any_form?(body, column) do
    Regex.match?(~r/^\(?"?#{Regex.escape(column)}"?\)?(::[a-z ]+)?\s*=\s*ANY\s*\(/i, body) and
      String.contains?(body, "ARRAY[")
  end

  # Quoted literals are scanned rather than the ARRAY body split on commas: a
  # value may contain a comma, and `''` is how a quote is escaped inside one.
  defp literals(body) do
    ~r/'((?:[^']|'')*)'/
    |> Regex.scan(body)
    |> Enum.map(fn [_match, literal] -> String.replace(literal, "''", "'") end)
  end

  # `CHECK (col IN ('only'))` collapses to a plain equality, and a one-value
  # domain is still a domain.
  defp equality_form(body, column) do
    case Regex.run(
           ~r/^\(?"?#{Regex.escape(column)}"?\)?(?:::[a-z ]+)?\s*=\s*'((?:[^']|'')*)'(?:::[a-z \[\]]+)?$/i,
           body
         ) do
      [_match, literal] -> {:ok, [String.replace(literal, "''", "'")]}
      _ -> :error
    end
  end
end
