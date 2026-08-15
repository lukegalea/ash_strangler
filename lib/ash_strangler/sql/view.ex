# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.View do
  @moduledoc """
  Builds the compatibility view SQL for a strangler-mapped resource.

  This is the `:read_from_legacy` shape only: a view named for the resource's
  own `postgres do table/schema end`, reading from `source.relation`, with an
  expression index when the key strategy needs one. `:dual_write` uses the same
  view (see the phase table in the plan/README); `INSTEAD OF` triggers and the
  reversed `:read_from_new` view are later steps and not built here.

  Pure functions over DSL/entity data — no database access, no dependency on
  the resource having compiled all the way. Works against either a fully
  compiled resource module or the mid-transform `dsl_state` map, exactly like
  `AshStrangler.Info`.
  """

  alias AshStrangler.{Constant, Join, Key, Source, Unmapped}
  alias AshStrangler.Map, as: MapEntry

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
      AshStrangler.Info.source(resource_or_dsl) ||
        raise ArgumentError, "no strangler `source` on #{inspect(resource_or_dsl)}"

    key = single_key!(source, resource_or_dsl)
    table = table!(resource_or_dsl)
    schema = AshPostgres.DataLayer.Info.schema(resource_or_dsl) || "public"

    attributes = Ash.Resource.Info.attributes(resource_or_dsl)
    columns = select_columns!(resource_or_dsl, source, key, attributes)

    %{
      view: view_statement(table, schema, source, columns),
      key_index: key_index_statement(table, source, key)
    }
  end

  defp table!(resource_or_dsl) do
    AshPostgres.DataLayer.Info.table(resource_or_dsl) ||
      raise ArgumentError,
            "#{inspect(resource_or_dsl)} has no `postgres do table \"...\" end` -- a strangler view needs somewhere to live"
  end

  defp single_key!(%Source{keys: [key]}, _resource_or_dsl), do: key

  defp single_key!(%Source{keys: []}, resource_or_dsl) do
    raise ArgumentError, "#{inspect(resource_or_dsl)}'s source declares no `key`"
  end

  defp single_key!(%Source{keys: keys}, resource_or_dsl) do
    raise ArgumentError,
          "#{inspect(resource_or_dsl)}'s source declares #{length(keys)} keys; only one is supported"
  end

  # --- the view -------------------------------------------------------------

  defp view_statement(table, schema, source, columns) do
    view_name = ~s("#{schema}"."#{table}")

    column_lines =
      Enum.map_join(columns, ",\n", fn {expr, attribute} -> "  #{expr} AS #{attribute}" end)

    up = """
    CREATE OR REPLACE VIEW #{view_name} AS
    SELECT
    #{column_lines}
    FROM #{from_clause(source)};
    """

    %{name: :"strangler_#{table}_view", up: up, down: "DROP VIEW IF EXISTS #{view_name};"}
  end

  # One `{sql_expression, attribute_name}` pair per resource attribute, in
  # attribute declaration order, plus a trailing `__legacy_id` column carrying
  # the raw legacy key -- unused for now (this phase is read-only), but every
  # later phase's `INSTEAD OF` triggers key off it rather than the derived
  # uuid, so it costs nothing to expose from the first version of the view.
  defp select_columns!(resource_or_dsl, source, key, attributes) do
    by_attribute = mapping_index(source)

    {rest, missing} =
      attributes
      |> Enum.reject(&(&1.name == key.attribute))
      |> Enum.reduce({[], []}, fn attribute, {columns, missing} ->
        case Map.fetch(by_attribute, attribute.name) do
          {:ok, entry} -> {[{mapped_expression(entry), attribute.name} | columns], missing}
          :error -> {columns, [attribute.name | missing]}
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

    # Qualified only when a join makes a bare column name ambiguous. The
    # expression index on the base table stays UNqualified -- Postgres resolves
    # the alias at parse time, so both forms reference the same column and the
    # index still matches. Asserted by an EXPLAIN test rather than assumed,
    # because a mismatch here degrades silently to a sequential scan.
    qualifier = if source.joins == [], do: nil, else: primary_alias(source)

    key_column = {key_expression(key, source.relation, qualifier), key.attribute}
    legacy_id_column = {qualify(legacy_id_expression(key), qualifier), :__legacy_id}

    [key_column, legacy_id_column | Enum.reverse(rest)]
  end

  defp mapping_index(%Source{mappings: mappings}) do
    Enum.reduce(mappings, %{}, fn
      %MapEntry{attribute: a} = m, acc -> Map.put(acc, a, m)
      %Constant{attribute: a} = c, acc -> Map.put(acc, a, c)
      %Unmapped{attributes: as} = u, acc -> Enum.reduce(as, acc, &Map.put(&2, &1, u))
    end)
  end

  defp mapped_expression(%MapEntry{column: column} = entry) when is_binary(column) do
    with_cast(column, entry)
  end

  defp mapped_expression(%MapEntry{from: from} = entry) when is_binary(from) do
    with_cast(from, entry)
  end

  defp mapped_expression(%Constant{expression: expression}), do: expression

  defp mapped_expression(%Unmapped{as: :null}), do: "NULL"

  defp mapped_expression(%Unmapped{as: :default, attributes: attributes}) do
    raise ArgumentError, """
    unmapped #{inspect(attributes)}, as: :default is not yet implemented.

    Only `as: :null` generates SQL today. Translating an Ash attribute default
    into a SQL literal for every supported Ash type is real work this version
    does not attempt -- rather than guess, it refuses. Use `as: :null`, or map
    the attribute to a `constant` with the literal spelled out explicitly.
    """
  end

  # `AT TIME ZONE` rather than `::timestamptz`, and the difference is the whole
  # of §10.12: casting a naive `timestamp` reads it as wall-clock time in the
  # SESSION's TimeZone, so the instant depends on a per-connection setting the
  # view cannot control. `AT TIME ZONE '<zone>'` states the zone in the view
  # itself and is therefore the same on every connection.
  #
  # The result is already `timestamptz`, so no further cast is applied -- adding
  # one would be a no-op at best, and `AT TIME ZONE` applied twice reverses
  # itself.
  defp with_cast(expr, %MapEntry{cast: :timestamptz, from_zone: zone}) when is_binary(zone) do
    "(#{expr} AT TIME ZONE '#{zone}')"
  end

  defp with_cast(expr, %MapEntry{cast: nil}), do: expr
  defp with_cast(expr, %MapEntry{cast: cast}), do: "(#{expr})::#{cast}"

  @doc false
  # The `FROM` clause, aliased only when there is something to disambiguate.
  #
  # With no joins the relation stands alone and unqualified column names are
  # unambiguous, so no alias is emitted -- which keeps the generated SQL for the
  # common case exactly as it was before joins existed.
  def from_clause(%Source{joins: []} = source), do: source.relation

  def from_clause(%Source{joins: joins} = source) do
    primary = "#{source.relation} AS #{primary_alias(source)}"

    Enum.reduce(joins, primary, fn %Join{} = join, acc ->
      keyword = if join.type == :inner, do: "INNER JOIN", else: "LEFT JOIN"

      "#{acc}\n  #{keyword} #{join.relation} AS #{alias_for(join)} ON #{join.on}"
    end)
  end

  @doc false
  def primary_alias(%Source{as: as}) when is_binary(as), do: as
  def primary_alias(%Source{relation: relation}), do: table_name(relation)

  @doc false
  def alias_for(%Join{as: as}) when is_binary(as), do: as
  def alias_for(%Join{relation: relation}), do: table_name(relation)

  defp table_name(relation) do
    relation |> String.split(".") |> List.last() |> String.trim(~s("))
  end

  # --- the key ---------------------------------------------------------------

  defp key_expression(key, relation), do: key_expression(key, relation, nil)

  defp key_expression(
         %Key{from: from, strategy: {:uuid_v5, namespace: namespace}},
         relation,
         qualifier
       ) do
    # The name prefix comes from `AshStrangler.KeyDerivation` rather than being
    # spelled out here, so the Elixir and SQL sides cannot disagree about it.
    # They must produce byte-identical uuids -- see that module.
    prefix = AshStrangler.KeyDerivation.name_prefix(relation)

    "uuid_generate_v5('#{namespace}'::uuid, '#{prefix}' || #{qualify(from, qualifier)}::text)"
  end

  defp key_expression(%Key{from: from, strategy: :identity}, _relation, qualifier) do
    "#{qualify(from, qualifier)}::uuid"
  end

  defp key_expression(%Key{strategy: other}, _relation, _qualifier),
    do: unsupported_strategy!(other)

  # Once a join exists, a bare `id` is ambiguous across relations, so the
  # primary key column has to say which table it came from.
  defp qualify(column, nil), do: column
  defp qualify(column, qualifier), do: "#{qualifier}.#{column}"

  defp legacy_id_expression(%Key{from: from}), do: from

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
  defp key_index_statement(_table, _source, %Key{strategy: :identity}), do: nil

  defp key_index_statement(table, source, %Key{strategy: {:uuid_v5, namespace: _}} = key) do
    name = "strangler_#{table}_key_idx"

    # Built from `key_expression/2` rather than restated. The index only serves
    # a lookup if its expression matches the view's *exactly* -- a difference as
    # small as whitespace makes Postgres decline to use it, silently, and the
    # only symptom is a sequential scan at production data volumes.
    up = """
    CREATE INDEX IF NOT EXISTS #{name} ON #{source.relation}
      (#{key_expression(key, source.relation)});
    """

    down = "DROP INDEX IF EXISTS #{qualify_index(source.relation, name)};"

    %{name: :"strangler_#{table}_key_index", up: up, down: down}
  end

  # Schema-qualifies the index by borrowing the schema prefix off the source
  # relation (§6.1: down statements must schema-qualify themselves too, same as
  # up). A relation with no schema prefix leaves the index unqualified, relying
  # on search_path for the drop -- exactly as much as the user's own
  # `source "users"` (no schema) already does.
  defp qualify_index(relation, name) do
    case String.split(relation, ".", parts: 2) do
      [schema, _table] -> "#{schema}.#{name}"
      [_table] -> name
    end
  end
end
