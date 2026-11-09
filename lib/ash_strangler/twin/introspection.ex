# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Twin.Introspection do
  @moduledoc """
  What a legacy relation looks like to the twin generator, as a function a task
  can call without loading Igniter.

  `mix ash_strangler.gen.twin` is only compiled when Igniter is, and Igniter is a
  dev and test dependency, so a task that runs in a host's CI (`mix
  ash_strangler.check`) cannot reach into it. Everything the generator decides
  about a *relation* rather than about a file lives here instead, and both tasks
  call it:

    * `read/2` reads the catalog through any function that runs SQL, so a task can
      read through the repo it already has open;
    * `columns/3` is the column list the generator writes: the Ash type of each
      column, its value set (a Postgres enum or a `CHECK (col IN (...))`), its
      nullability, and the columns it declines to declare, each with a note;
    * `identities/2` and `unique_sets/2` are the unique key sets the generator
      declares, which are the primary key and every unique constraint or index
      that is whole-table (no predicate), over plain columns (no expression), and
      over key columns only (never `INCLUDE` payload);
    * `coarse/2` and `pg_type/1` put a twin attribute and a Postgres type on the
      same footing for comparison.

  The catalog reading itself is `AshStrangler.Snapshot.Catalog`, and the type
  table and the `CHECK` parse are `AshStrangler.Snapshot.Types`; this module is
  the part of the generator that sits between them and the rendered file.

  ## Coarse types

  A twin attribute and a column agree when they are the same *coarse* type:
  `int2`, `int4` and `int8` are one integer; `timestamptz` and an Ash
  `:utc_datetime` are one aware timestamp; an `:atom` with `one_of` is text.
  Things that differ in kind stay different, and `citext` stays distinct from
  `text`. A typmod (`numeric(10, 2)`, `varchar(20)`) is never compared.
  """

  alias AshStrangler.Snapshot.{Catalog, Types}

  @typedoc "One column as the generator would declare it."
  @type column :: %{
          column: String.t(),
          name: String.t() | nil,
          allow_nil?: boolean(),
          primary_key?: boolean(),
          type: atom() | {:array, atom()} | nil,
          one_of: [String.t()] | nil,
          note: String.t() | nil
        }

  @typedoc "Runs one SQL statement with its parameters, as `repo.query/2` does."
  @type run :: (String.t(), list() -> {:ok, %{rows: [list()]}} | {:error, term()})

  # --- reading -----------------------------------------------------------

  # The schemas of the enums and domains the columns of `$1` use, through arrays
  # and domains over domains.
  @type_schemas """
  WITH RECURSIVE used(oid) AS (
    SELECT a.atttypid
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY($1) AND a.attnum > 0 AND NOT a.attisdropped
    UNION
    SELECT CASE WHEN t.typtype = 'd' THEN t.typbasetype ELSE t.typelem END
      FROM used u
      JOIN pg_type t ON t.oid = u.oid
     WHERE t.typtype = 'd' OR t.typcategory = 'A'
  )
  SELECT DISTINCT n.nspname
    FROM used u
    JOIN pg_type t ON t.oid = u.oid
    JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE t.typtype IN ('e', 'd') AND n.nspname <> 'pg_catalog'
  """

  @doc """
  The catalog of `schemas`, and of any schema holding an enum or domain their
  columns use, read through `run`.

  `run` has to read under an empty `search_path`, as the generator does: see
  `AshStrangler.Snapshot.Catalog.read/2` for what depends on it.

  `{:error, exception}` when a statement fails, rather than a raise, so the
  caller can tell a database that could not be read from a relation that is not
  there.
  """
  @spec read(run(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def read(run, schemas) do
    rows = fn sql, schemas ->
      case run.(sql, [schemas]) do
        {:ok, %{rows: rows}} -> rows
        {:error, error} -> throw({:introspection_failed, error})
      end
    end

    # A table's enum or domain can live in another schema, and without it in the
    # catalog the column reads as a type with no Ash type at all.
    schemas =
      (schemas ++ (rows.(@type_schemas, schemas) |> List.flatten()))
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, Catalog.read(&rows.(&1, schemas), schemas)}
  rescue
    error -> {:error, error}
  catch
    {:introspection_failed, error} -> {:error, error}
  end

  @doc "The catalog's entry for `\"schema.table\"`, or `:error` when the relation is not in it."
  @spec relation(map(), String.t()) :: {:ok, map()} | :error
  def relation(catalog, name), do: Map.fetch(catalog["relations"] || %{}, name)

  # --- what the generator writes -----------------------------------------

  @doc """
  The columns of `relation`, in declaration order, as the generator declares
  them. `secrets` are column names to leave out.

  A column with no `type` is not declared: its `note` says why (a secret, a name
  Elixir cannot take as an attribute, a Postgres type with no Ash type).
  """
  @spec columns(map(), map(), [String.t()]) :: [column()]
  def columns(relation, catalog, secrets \\ []) do
    relation
    |> typed_columns(catalog, secrets)
    |> Enum.map(&undeclare_unnameable(&1, secrets))
  end

  defp undeclare_unnameable(%{name: nil, column: column} = unnamed, secrets) do
    if column in secrets,
      do: unnamed,
      else: %{unnamed | type: nil, one_of: nil, note: unnameable_note(column)}
  end

  defp undeclare_unnameable(named, _secrets), do: named

  @doc """
  `columns/3`, except that a column no attribute name can be formed from keeps its
  type and value set.

  The generator cannot declare such a column, but a hand-written twin can, through
  `source:`, and what the column holds does not depend on what it is called.
  """
  @spec typed_columns(map(), map(), [String.t()]) :: [column()]
  def typed_columns(relation, catalog, secrets \\ []) do
    primary_key = (relation["primary_key"] || %{})["columns"] || []

    Enum.map(relation["columns"], fn column ->
      name = column["name"]

      base = %{
        column: name,
        name: attribute_name(name),
        allow_nil?: not column["not_null"],
        primary_key?: name in primary_key,
        type: nil,
        one_of: nil,
        note: nil
      }

      if name in secrets do
        %{
          base
          | note: "`#{name}` is declared secret (`twin do secrets ... end`) and is not carried."
        }
      else
        case Types.for_column(column, relation, catalog) do
          {:ok, typed} -> Map.merge(base, typed)
          {:omit, note} -> %{base | note: note}
        end
      end
    end)
  end

  defp unnameable_note(column) do
    """
    `#{column}` has no name Elixir will accept as an attribute, so it is not
    declared here. Ash's `source:` carries a column whose name merely differs from
    its attribute's -- it cannot supply a name where none can be formed.
    """
  end

  @doc """
  The attribute name a column takes, as a string, or `nil` when no name Elixir
  would want as an atom can be formed. A column that differs only in case or style
  keeps its real name in Ash's `source:`, which is what
  `AshStrangler.Twin.column!/2` reads.

  A string on purpose: the generator turns it into an atom when it writes the
  file, once, at codegen. A task that only compares (`mix ash_strangler.check`)
  never makes an atom out of a name the database gave it.
  """
  @spec attribute_name(String.t()) :: String.t() | nil
  def attribute_name(column) do
    underscored = Macro.underscore(column)

    if underscored =~ ~r/^[a-z][a-z0-9_]*$/, do: underscored, else: nil
  end

  @doc "`%{column name => attribute name}` for the columns that are declared."
  @spec declared([column()]) :: %{String.t() => String.t()}
  def declared(columns) do
    for %{type: type, name: name, column: column} <- columns,
        type != nil,
        into: %{},
        do: {column, name}
  end

  @doc """
  The identities the generator writes: one per whole-table unique constraint or
  index whose columns are all declared.

  The primary key is skipped, because it is `primary_key? true` already.
  A partial index makes a column unique among some rows, which is not what an
  identity claims. An expression key is recorded by the catalog as the
  expression's text, which is no declared column, so an index with one is not an
  identity either. Only key columns are recorded, never `INCLUDE` ones.
  """
  @spec identities(map(), [column()]) :: [
          %{name: String.t(), keys: [String.t()], columns: [String.t()]}
        ]
  def identities(relation, columns) do
    declared = declared(columns)
    primary_key = (relation["primary_key"] || %{})["columns"]

    for %{"name" => name, "columns" => keys, "predicate" => nil} <- relation["unique"],
        keys != primary_key,
        Enum.all?(keys, &Map.has_key?(declared, &1)) do
      %{name: name, keys: Enum.map(keys, &declared[&1]), columns: keys}
    end
  end

  @doc """
  The unique sets of a twin generated from `relation`, as `AshStrangler.Twin`
  reports them: the identities plus the primary key, as sets of column names.
  """
  @spec unique_sets(map(), [column()]) :: MapSet.t(MapSet.t(String.t()))
  def unique_sets(relation, columns) do
    declared = declared(columns)

    primary_key =
      for %{column: column, primary_key?: true} <- columns,
          Map.has_key?(declared, column),
          do: column

    sets = for identity <- identities(relation, columns), do: MapSet.new(identity.columns)

    sets = if primary_key == [], do: sets, else: [MapSet.new(primary_key) | sets]

    MapSet.new(sets)
  end

  # --- comparing types ---------------------------------------------------

  @doc """
  The Ash type a Postgres base type is carried as, or `nil`. See
  `AshStrangler.Snapshot.Types.ash_type/1`.
  """
  @spec pg_type(String.t()) :: atom() | nil
  defdelegate pg_type(typname), to: Types, as: :ash_type

  @doc """
  The coarse type of an Ash type, by what it is stored as.

  `{:array, type}` is `{:array, coarse}`. Two types that store as the same coarse
  type agree for the purposes of a twin; a pair that does not has changed.
  """
  @spec coarse(Ash.Type.t() | {:array, Ash.Type.t()}, keyword()) :: atom() | {:array, atom()}
  def coarse(type, constraints \\ [])

  def coarse({:array, inner}, constraints) do
    {:array, coarse(inner, Keyword.get(constraints, :items, []))}
  end

  def coarse(type, constraints) do
    type |> Ash.Type.get_type() |> Ash.Type.storage_type(constraints) |> family()
  end

  @doc """
  True when `coarse` is a type the generator's table can produce.

  One that is not (a custom `storage_type`, such as an `Ash.Type.Enum` stored as
  the Postgres enum's own name) cannot be set against a column's type: differing
  from it says nothing about whether the column changed.
  """
  @spec comparable?(atom() | {:array, atom()}) :: boolean()
  def comparable?({:array, inner}), do: comparable?(inner)
  def comparable?(coarse), do: Enum.any?(Types.ash_types(), &(coarse(&1) == coarse))

  defp family(storage)
       when storage in [:utc_datetime_usec, :utc_datetime, :timestamptz, :"timestamptz(6)"],
       do: :utc_datetime

  defp family(storage) when storage in [:naive_datetime_usec, :naive_datetime],
    do: :naive_datetime

  defp family(storage) when storage in [:time_usec, :time], do: :time
  defp family(storage) when storage in [:bigint, :smallint, :integer], do: :integer
  defp family(storage) when storage in [:text, :string], do: :string
  defp family(storage) when storage in [:jsonb, :json, :map], do: :map
  defp family({:array, inner}), do: {:array, family(inner)}
  defp family(storage), do: storage
end
