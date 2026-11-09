# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Twin.Fixture do
  @moduledoc """
  Writes rows into a legacy relation through its twin: fixture and seed data
  for a stand-in schema, as the legacy application would have written them.

      AshStrangler.Twin.Fixture.insert!(MyApp.Legacy.Members, %{email: "a@example.com", home_branch_id: 1})
      #=> %{id: 1, email: "a@example.com", home_branch_id: 1, referrer_id: nil}

      AshStrangler.Twin.Fixture.insert_all!(MyApp.Legacy.Copies, rows)
      #=> 100_000

  Rows go in with a plain `INSERT` against the twin's table, so the database's
  own constraints, defaults, identity columns and triggers apply, and nothing of
  the canonical side (views, `INSTEAD OF` triggers, policies) is involved.
  Values are keyed by twin attribute and dumped through the attribute's Ash
  type; a key the twin does not declare is refused, which includes every
  declared secret.

  The repo is the twin's own unless `repo:` is given.
  """

  alias AshStrangler.Twin

  # PostgreSQL's limit on bind parameters in one statement.
  @max_parameters 65_535

  @doc """
  Inserts one row and returns it as read back (`RETURNING *`), keyed by twin
  attribute and cast through each attribute's type.
  """
  @spec insert!(Ash.Resource.t(), map() | keyword(), keyword()) :: map()
  def insert!(twin, attrs, opts \\ []) do
    attrs = Map.new(attrs)
    columns = Map.keys(attrs)
    {sql, params} = statement(twin, columns, [attrs], "RETURNING *")

    %{columns: names, rows: [row]} = repo(twin, opts).query!(sql, params)
    load(twin, names, row)
  end

  @doc """
  Inserts `rows` (maps keyed by twin attribute; every row may name different
  attributes, missing ones take the column default) in as few statements as
  PostgreSQL's parameter limit allows, and returns how many were inserted.
  """
  @spec insert_all!(Ash.Resource.t(), Enumerable.t(), keyword()) :: non_neg_integer()
  def insert_all!(twin, rows, opts \\ []) do
    repo = repo(twin, opts)

    rows
    |> Stream.map(&Map.new/1)
    |> Stream.chunk_by(&Map.keys/1)
    |> Stream.flat_map(fn chunk ->
      columns = chunk |> hd() |> Map.keys()
      Stream.chunk_every(chunk, max(div(@max_parameters, max(length(columns), 1)), 1))
    end)
    |> Enum.reduce(0, fn chunk, count ->
      {sql, params} = statement(twin, chunk |> hd() |> Map.keys(), chunk, "")
      %{num_rows: inserted} = repo.query!(sql, params)
      count + inserted
    end)
  end

  defp statement(twin, attributes, rows, suffix) do
    attributes = Enum.sort(attributes)
    known = Map.new(Ash.Resource.Info.attributes(twin), &{&1.name, &1})

    for attribute <- attributes, not Map.has_key?(known, attribute) do
      raise ArgumentError, """
      #{inspect(twin)} has no attribute #{inspect(attribute)}. A fixture writes \
      only the columns the twin declares; secrets and columns with no Ash type \
      are not among them.
      """
    end

    column_list = Enum.map_join(attributes, ", ", &AshStrangler.Sql.Printer.column(twin, &1))
    width = length(attributes)

    {values, params} =
      rows
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {row, index}, acc ->
        placeholders = Enum.map_join(1..width//1, ", ", &"$#{index * width + &1}")
        dumped = Enum.map(attributes, &dump!(twin, known[&1], Map.get(row, &1)))
        {"(#{placeholders})", [dumped | acc]}
      end)

    params = params |> Enum.reverse() |> Enum.concat()
    relation = quote_relation(twin)

    sql =
      if width == 0 do
        "INSERT INTO #{relation} DEFAULT VALUES #{suffix}"
      else
        "INSERT INTO #{relation} (#{column_list}) VALUES #{Enum.join(values, ", ")} #{suffix}"
      end

    {sql, params}
  end

  defp dump!(_twin, _attribute, nil), do: nil

  defp dump!(twin, attribute, value) do
    with {:ok, cast} <- Ash.Type.cast_input(attribute.type, value, attribute.constraints),
         {:ok, dumped} <- Ash.Type.dump_to_native(attribute.type, cast, attribute.constraints) do
      dumped
    else
      _ ->
        raise ArgumentError,
              "#{inspect(value)} is not a valid #{inspect(attribute.type)} for " <>
                "#{inspect(twin)}.#{attribute.name}"
    end
  end

  defp load(twin, names, row) do
    by_column =
      Map.new(Ash.Resource.Info.attributes(twin), &{to_string(&1.source || &1.name), &1})

    names
    |> Enum.zip(row)
    |> Enum.flat_map(fn {name, value} ->
      case by_column[name] do
        nil ->
          []

        attribute ->
          {:ok, loaded} = Ash.Type.cast_stored(attribute.type, value, attribute.constraints)
          [{attribute.name, loaded}]
      end
    end)
    |> Map.new()
  end

  defp quote_relation(twin) do
    table = ~s("#{Twin.table!(twin)}")

    case AshPostgres.DataLayer.Info.schema(twin) do
      nil -> table
      schema -> ~s("#{schema}".#{table})
    end
  end

  defp repo(twin, opts) do
    case Keyword.get(opts, :repo) || AshPostgres.DataLayer.Info.repo(twin, :mutate) do
      repo when is_function(repo) -> repo.(twin, :mutate)
      repo -> repo
    end
  end
end
