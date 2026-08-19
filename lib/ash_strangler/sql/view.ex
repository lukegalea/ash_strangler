# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.View do
  @moduledoc """
  Builds the compatibility view SQL for a strangler-mapped resource.

  A view named for the resource's own `postgres do table/schema end`, reading from
  the twin's relation, with an expression index when the key strategy needs one.
  `:read_from_legacy` and `:dual_write` share it; `:read_from_new` reverses the
  direction and lives in `AshStrangler.Sql.ReverseView`.

  Every column expression comes from `AshStrangler.Lens` and is rendered by
  `AshStrangler.Sql.Printer`. Nothing here assembles SQL from strings, and the
  `with_cast/2` helper that used to hard-code `AT TIME ZONE` and `::type` is gone —
  it was one of four copies of the same rule.

  Pure functions over DSL/entity data — no database access, no dependency on the
  resource having compiled all the way. Works against either a fully compiled
  resource module or the mid-transform `dsl_state`, exactly like
  `AshStrangler.Info`.
  """

  alias AshStrangler.{Info, Key, Lens, Twin}
  alias AshStrangler.Sql.Printer

  @doc """
  The `CREATE SCHEMA` statement for the schema the view is declared in, or `nil`
  when it lives in `public` (which always exists).

  Separate from `build/1` because it is a property of the *schema* rather than
  of any one resource: several strangler-mapped resources normally share one,
  and `AshStrangler.Migration.render/2` collapses the duplicates.

  Nothing created this schema before. Every test in this repository creates it
  by hand in its setup (`test/support/legacy_schema.ex`), so the suite never
  exercised a generated migration against a database that did not already have
  it — and a first migration on a fresh database failed with
  `ERROR 3F000 (invalid_schema_name)`.

  The `down` drops the schema **only once it is empty**, checked rather than
  asserted. `DROP SCHEMA ... RESTRICT` raises on a non-empty schema instead of
  declining, and `CASCADE` would take another resource's view with it. Since
  `render/2` reverses the statement order, by the time this runs the view and
  the notify function this migration created are already gone; anything still
  in there belongs to somebody else and is left alone.
  """
  @spec schema_statement(Ash.Resource.t() | Spark.Dsl.t()) ::
          %{name: atom(), up: String.t(), down: String.t()} | nil
  def schema_statement(resource_or_dsl) do
    case AshPostgres.DataLayer.Info.schema(resource_or_dsl) do
      nil -> nil
      "public" -> nil
      schema -> schema_statement_for(schema)
    end
  end

  defp schema_statement_for(schema) do
    %{
      name: :"strangler_#{schema}_schema",
      up: ~s(CREATE SCHEMA IF NOT EXISTS "#{schema}";),
      down: """
      DO $strangler$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = '#{schema}'
        ) AND NOT EXISTS (
          SELECT 1
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = '#{schema}'
        ) THEN
          EXECUTE 'DROP SCHEMA IF EXISTS "#{schema}"';
        END IF;
      END $strangler$;
      """
    }
  end

  @doc """
  Builds the view (and, where the key strategy needs one, the expression index)
  for `resource_or_dsl`.

  Returns `%{view: %{name:, up:, down:}, key_index: %{name:, up:, down:} | nil}`.

  Raises `ArgumentError` if the resource has no strangler mapping, no key, or
  an attribute with no mapped source -- the last one deliberately stricter than
  `AshStrangler.Verifiers.VerifyCompleteMapping`, which exempts private
  attributes. A view's `SELECT` list must supply every column regardless of
  whether it is public, so this is the actual completeness requirement.
  """
  def build(resource_or_dsl) do
    source =
      Info.source(resource_or_dsl) ||
        raise ArgumentError, "no strangler `source` on #{inspect(resource_or_dsl)}"

    key = key!(resource_or_dsl)
    table = table!(resource_or_dsl)
    schema = AshPostgres.DataLayer.Info.schema(resource_or_dsl) || "public"

    attributes = Ash.Resource.Info.attributes(resource_or_dsl)
    columns = select_columns!(resource_or_dsl, source, key, attributes)

    %{
      view: view_statement(table, schema, resource_or_dsl, columns),
      key_index: key_index_statement(table, resource_or_dsl, key)
    }
  end

  defp table!(resource_or_dsl) do
    AshPostgres.DataLayer.Info.table(resource_or_dsl) ||
      raise ArgumentError,
            "#{inspect(resource_or_dsl)} has no `postgres do table \"...\" end` -- a strangler view needs somewhere to live"
  end

  defp key!(resource_or_dsl) do
    Info.key(resource_or_dsl) ||
      raise ArgumentError, "#{inspect(resource_or_dsl)}'s source declares no `key`"
  end

  # --- the view -------------------------------------------------------------

  defp view_statement(table, schema, resource_or_dsl, columns) do
    view_name = ~s("#{schema}"."#{table}")

    column_lines =
      Enum.map_join(columns, ",\n", fn {expr, attribute} -> "  #{expr} AS #{attribute}" end)

    up = """
    CREATE OR REPLACE VIEW #{view_name} AS
    SELECT
    #{column_lines}
    FROM #{from_clause(resource_or_dsl)};
    """

    %{name: :"strangler_#{table}_view", up: up, down: "DROP VIEW IF EXISTS #{view_name};"}
  end

  # One `{sql_expression, attribute_name}` pair per resource attribute, in
  # attribute declaration order, plus a trailing `__legacy_id` column carrying
  # the raw legacy key -- every write phase's triggers key off it rather than the
  # derived uuid, because the derivation is one-way.
  defp select_columns!(resource_or_dsl, _source, key, attributes) do
    lenses = Lens.by_attribute(resource_or_dsl)
    frame = read_frame(resource_or_dsl)

    {rest, missing} =
      attributes
      |> Enum.reject(&(&1.name == key.attribute))
      |> Enum.reduce({[], []}, fn attribute, {columns, missing} ->
        case Map.fetch(lenses, attribute.name) do
          {:ok, lens} ->
            {[{forward_sql(lens, frame), attribute.name} | columns], missing}

          :error ->
            {columns, [attribute.name | missing]}
        end
      end)

    if missing != [] do
      raise ArgumentError, """
      #{inspect(resource_or_dsl)} cannot generate a view: these attributes have \
      no legacy source at all (not mapped, constant, or unmapped):

        #{Enum.map_join(Enum.reverse(missing), "\n  ", &inspect/1)}

      A view's SELECT list must supply every column. Map each one, or declare
      it `unmapped [...], as: :null, because: "..."` if there is genuinely no
      source for it.
      """
    end

    key_column = {key_expression(resource_or_dsl, key, frame), key.attribute}
    legacy_id_column = {frame.({[], key.from}), :__legacy_id}

    [key_column, legacy_id_column | Enum.reverse(rest)]
  end

  # An `unmapped ..., as: :null` lens has no forward expression at all, which is
  # exactly what it means.
  defp forward_sql(%Lens{forward: nil}, _frame), do: "NULL"
  defp forward_sql(%Lens{forward: forward}, frame), do: Printer.to_sql(forward, ref: frame)

  @doc false
  # The frame the forward direction is read in. Qualified only when a join makes a
  # bare column name ambiguous -- which keeps the generated SQL for the common case
  # exactly as it was before joins existed.
  #
  # The expression index on the base table stays UNqualified: Postgres resolves the
  # alias at parse time, so both forms reference the same column and the index still
  # matches. Asserted by an EXPLAIN test rather than assumed, because a mismatch
  # here degrades silently to a sequential scan.
  def read_frame(resource_or_dsl) do
    twin = Info.twin(resource_or_dsl)

    if Info.joins(resource_or_dsl) == [] do
      Printer.bare_frame(twin)
    else
      Printer.qualified_frame(twin, Twin.table!(twin))
    end
  end

  @doc false
  # The `FROM` clause, aliased only when there is something to disambiguate.
  #
  # Joins are DISCOVERED from the relationship paths the mappings read through --
  # see `AshStrangler.Info.joins/1`. They are always `LEFT`, and that is now
  # structural rather than a default: an `INNER JOIN` removes rows, so a legacy row
  # with no match would disappear from the view and the new application would see
  # fewer records than the old one with nothing reporting it.
  def from_clause(resource_or_dsl) do
    twin = Info.twin(resource_or_dsl)
    relation = Twin.relation(twin)

    case Info.joins(resource_or_dsl) do
      [] ->
        relation

      joins ->
        Enum.reduce(joins, "#{relation} AS #{Twin.table!(twin)}", fn join, acc ->
          "#{acc}\n  LEFT JOIN #{join.relation} AS #{join.alias} ON #{join.on}"
        end)
    end
  end

  # --- the key ---------------------------------------------------------------

  @doc false
  def key_expression(resource_or_dsl, key, frame) do
    do_key_expression(key, Info.relation(resource_or_dsl), frame)
  end

  defp do_key_expression(
         %Key{from: from, strategy: {:uuid_v5, namespace: namespace}},
         relation,
         frame
       ) do
    # The name prefix comes from `AshStrangler.KeyDerivation` rather than being
    # spelled out here, so the Elixir and SQL sides cannot disagree about it.
    # They must produce byte-identical uuids -- see that module.
    prefix = AshStrangler.KeyDerivation.name_prefix(relation)

    "uuid_generate_v5(#{Printer.literal(namespace)}::uuid, #{Printer.literal(prefix)} || #{frame.({[], from})}::text)"
  end

  defp do_key_expression(%Key{from: from, strategy: :identity}, _relation, frame) do
    "#{frame.({[], from})}::uuid"
  end

  defp do_key_expression(%Key{strategy: other}, _relation, _frame),
    do: unsupported_strategy!(other)

  defp unsupported_strategy!(strategy) do
    raise ArgumentError, """
    key strategy #{inspect(strategy)} is not yet implemented.

    Only `{:uuid_v5, namespace: "..."}` and `:identity` generate SQL today.
    """
  end

  # --- the expression index ---------------------------------------------------

  # `:identity` needs no derived-expression index: the legacy column is used
  # unchanged, so whatever index already exists on it (there had better be one)
  # already serves `Ash.get`.
  defp key_index_statement(_table, _resource_or_dsl, %Key{strategy: :identity}), do: nil

  defp key_index_statement(table, resource_or_dsl, %Key{strategy: {:uuid_v5, namespace: _}} = key) do
    name = "strangler_#{table}_key_idx"
    relation = Info.relation(resource_or_dsl)
    twin = Info.twin(resource_or_dsl)

    # Built from `key_expression/3` rather than restated. The index only serves a
    # lookup if its expression matches the view's *exactly* -- a difference as
    # small as whitespace makes Postgres decline to use it, silently, and the only
    # symptom is a sequential scan at production data volumes. One printer is what
    # generalises that protection to every mapping.
    up = """
    CREATE INDEX IF NOT EXISTS #{name} ON #{relation}
      (#{key_expression(resource_or_dsl, key, Printer.bare_frame(twin))});
    """

    down = "DROP INDEX IF EXISTS #{qualify_index(relation, name)};"

    %{name: :"strangler_#{table}_key_index", up: up, down: down}
  end

  # Schema-qualifies the index by borrowing the schema prefix off the source
  # relation: down statements must schema-qualify themselves too, same as up. A
  # relation with no schema prefix leaves the index unqualified, relying on
  # search_path for the drop -- exactly as much as a twin with no `schema` already
  # does.
  defp qualify_index(relation, name) do
    case String.split(relation, ".", parts: 2) do
      [schema, _table] -> "#{schema}.#{name}"
      [_table] -> name
    end
  end
end
