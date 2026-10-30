# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Extension do
  @moduledoc """
  Builds the extension table a resource declares with `extension [...]`.

  One table per resource, named after the resource's own view:
  `"<view_schema>"."<table>_extension"`, keyed by the canonical primary key,
  one column per extension attribute, typed by `Printer.pg_type!/1` from the
  attribute's own Ash type — the same function the view's casts use, so the
  column and the view expression that reads it cannot disagree about the type.

  The table lives in the **same schema as the view**, on purpose: the view
  `LEFT JOIN`s it, and a join across schema boundaries is one more `search_path`
  opinion a compatibility layer does not need. When the schema is created by
  `AshStrangler.Sql.View.schema_statement/1`, this table lands inside it.

  "No extension row" is a meaningful state, not a corruption: every legacy row
  that predates the resource has one, and reads the attribute's declared
  literal default through `COALESCE` (or NULL where no default is declared).
  That is also why there is no `NOT NULL` on extension columns — the table
  must be able to hold the NULLs of history.

  The ledger precedent applies to placement: the table is infrastructure the
  migrating session owns, created where the compatibility layer itself lives.
  """

  alias AshStrangler.{Info, Lens}
  alias AshStrangler.Sql.Printer

  @doc """
  The extension table's qualified name, quoted — the single definition read by
  the migration, the view's `FROM` clause and the triggers.
  """
  @spec relation(Ash.Resource.t() | Spark.Dsl.t()) :: String.t()
  def relation(resource_or_dsl) do
    table = AshPostgres.DataLayer.Info.table(resource_or_dsl)
    schema = AshPostgres.DataLayer.Info.schema(resource_or_dsl) || "public"

    ~s("#{schema}"."#{table}_extension")
  end

  @doc """
  The extension alias the view binds the join to. One definition, so the join
  and the `:strangler_ext` printer node cannot drift.
  """
  @spec join_alias() :: String.t()
  def join_alias, do: "ext"

  @doc """
  Builds the `CREATE TABLE` for `resource_or_dsl`, or `[]` when the source
  declares no `extension` block — and in the phases that cannot have one
  (`:read_from_new` folds extension columns into the owned table before
  cutover; `:decommissioned` has nothing left to extend).
  """
  def build(resource_or_dsl) do
    case Info.source(resource_or_dsl) do
      %{extensions: [_ | _]} = source ->
        if Info.strangler_phase!(resource_or_dsl) in [:read_from_legacy, :dual_write] do
          [table_statement(resource_or_dsl, source)]
        else
          []
        end

      _ ->
        []
    end
  end

  defp table_statement(resource_or_dsl, source) do
    key = Info.key(resource_or_dsl)
    attributes = attribute_index(resource_or_dsl)

    pk_column = key_column!(key, attributes)

    declared =
      source.extensions
      |> Enum.flat_map(& &1.attributes)
      |> Enum.map(fn attribute ->
        attr = Map.fetch!(attributes, attribute)
        ~s("#{attribute}" #{Printer.pg_type!(attr.type)})
      end)

    # A `{:extension, :column}` state adds its column implicitly, typed by the
    # collapse attribute's own Ash type — `lifecycle_state :atom` is `text`, the
    # same typing the view's forward conditions read.
    implicit =
      source.mappings
      |> Enum.filter(&is_struct(&1, AshStrangler.Collapse))
      |> Enum.flat_map(&Lens.extension_state_columns/1)
      |> Enum.uniq()
      |> Enum.map(fn column ->
        attr = Map.fetch!(attributes, collapse_attribute(source, column))
        ~s("#{column}" #{Printer.pg_type!(attr.type)})
      end)

    columns = declared ++ implicit

    up = """
    CREATE TABLE IF NOT EXISTS #{relation(resource_or_dsl)} (
      #{pk_column} PRIMARY KEY,#{if columns == [], do: "", else: "\n  " <> Enum.join(columns, ",\n  ")}
    )
    """

    [
      %{
        name: table_statement_name(resource_or_dsl),
        up: up,
        down: "DROP TABLE IF EXISTS #{relation(resource_or_dsl)};"
      }
    ]
  end

  defp collapse_attribute(source, column) do
    source.mappings
    |> Enum.find(fn mapping ->
      is_struct(mapping, AshStrangler.Collapse) and
        column in Lens.extension_state_columns(mapping)
    end)
    |> Map.get(:attribute)
  end

  defp table_statement_name(resource_or_dsl) do
    table = AshPostgres.DataLayer.Info.table(resource_or_dsl)
    :"strangler_#{table}_extension"
  end

  defp key_column!(key, attributes) do
    attr = Map.fetch!(attributes, key.attribute)

    ~s("#{key.attribute}" #{Printer.pg_type!(attr.type)} NOT NULL)
  end

  defp attribute_index(resource_or_dsl) do
    Map.new(Ash.Resource.Info.attributes(resource_or_dsl), &{&1.name, &1})
  end
end
