# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Additive do
  @moduledoc """
  The statements that make regenerating a migration additive.

  `CREATE TABLE IF NOT EXISTS` does nothing to a table that exists, and
  `CREATE OR REPLACE VIEW` refuses any change but appending columns. Both
  helpers here close those two gaps and stay idempotent, so a migration
  regenerated after a column was declared runs cleanly over an installed layer
  and over an empty database alike.

  **`add_columns/3`** follows a `CREATE TABLE IF NOT EXISTS` with one
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for every declared column, typed as
  the `CREATE` types it. A column that is `NOT NULL` with no default cannot be
  added to a table that already holds rows, so a guard statement ahead of the
  `ALTER` refuses that case with a message that says what to do, instead of
  PostgreSQL's bare `column contains null values`. Its `down` is a no-op: like the
  table's own `down`, it never destroys rows, and a dropped column is data lost.

  **`reshape_view/3`** runs before a `CREATE OR REPLACE VIEW`. When the installed
  view's column names are a prefix of the new list (the view is unchanged, or
  columns were appended) it does nothing, so grants and dependent objects are
  left alone. When a column was inserted mid-list, renamed, removed or reordered,
  it drops the view with a plain `DROP VIEW` (never `CASCADE`): a view or
  function that depends on it makes the migration fail loudly rather than be
  dropped silently. The statements that follow re-create the view and, in the
  generated order, the `INSTEAD OF` triggers that the drop took with it. A
  column that changes only its *type* is still refused by PostgreSQL.
  """

  alias AshStrangler.Sql.Printer

  @type column :: %{name: String.t(), definition: String.t(), not_null_no_default?: boolean()}

  @doc """
  The statements adding `columns` to the already-quoted `table`, or `[]`.

  `columns` are `%{name:, definition:, not_null_no_default?:}`; `definition` is
  the column's full text as the `CREATE TABLE` writes it (`"name" type [NOT NULL]`).
  """
  @spec add_columns(atom(), String.t(), [column()]) :: [
          %{name: atom(), up: String.t(), down: String.t()}
        ]
  def add_columns(_name, _table, []), do: []

  def add_columns(name, table, columns) do
    alter = %{
      name: :"#{name}_add_columns",
      up:
        "ALTER TABLE #{table}\n" <>
          Enum.map_join(columns, ",\n", &"  ADD COLUMN IF NOT EXISTS #{&1.definition}") <>
          ";",
      down: "SELECT 1;"
    }

    guarded = Enum.filter(columns, & &1.not_null_no_default?)

    if guarded == [], do: [alter], else: [guard(name, table, guarded), alter]
  end

  defp guard(name, table, guarded) do
    checks =
      Enum.map_join(guarded, "", fn column ->
        message =
          "column #{column.name} is NOT NULL with no default and #{table} already holds rows: " <>
            "add it nullable, backfill it, then SET NOT NULL, or declare it nullable"

        """
          IF NOT EXISTS (
            SELECT 1 FROM pg_attribute
             WHERE attrelid = to_regclass(#{Printer.literal(table)}) AND attname = #{Printer.literal(column.name)}
               AND attnum > 0 AND NOT attisdropped
          ) AND EXISTS (SELECT 1 FROM #{table}) THEN
            RAISE EXCEPTION '%', #{Printer.literal(message)};
          END IF;
        """
      end)

    %{
      name: :"#{name}_add_columns_guard",
      up: """
      DO $strangler$
      BEGIN
        IF to_regclass(#{Printer.literal(table)}) IS NULL THEN
          RETURN;
        END IF;
      #{String.trim_trailing(checks)}
      END $strangler$;
      """,
      down: "SELECT 1;"
    }
  end

  @doc """
  The statement that drops `view` ahead of its `CREATE OR REPLACE VIEW` when the
  installed column names are not a prefix of `names`, the new list in view order.
  """
  @spec reshape_view(atom(), String.t(), [String.t() | atom()]) :: %{
          name: atom(),
          up: String.t(),
          down: String.t()
        }
  def reshape_view(name, view, names) do
    expected = Enum.map_join(names, ", ", &Printer.literal(to_string(&1)))

    %{
      name: :"#{name}_reshape",
      up: """
      DO $strangler$
      DECLARE
        oid_ oid := to_regclass(#{Printer.literal(view)});
        installed text[];
        expected text[] := ARRAY[#{expected}];
      BEGIN
        IF oid_ IS NULL OR (SELECT relkind FROM pg_class WHERE oid = oid_) <> 'v' THEN
          RETURN;
        END IF;
        SELECT array_agg(attname::text ORDER BY attnum) INTO installed
          FROM pg_attribute
          WHERE attrelid = oid_ AND attnum > 0 AND NOT attisdropped;
        IF installed IS DISTINCT FROM expected[1:cardinality(installed)] THEN
          EXECUTE #{Printer.literal("DROP VIEW #{view}")};
        END IF;
      END $strangler$;
      """,
      down: "SELECT 1;"
    }
  end
end
