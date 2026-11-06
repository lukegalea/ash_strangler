# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Derived.Sql do
  @moduledoc """
  The SQL of an `AshStrangler.Derived`: one `UNION ALL` view, read-only.

  The view's columns are the key, `__source` (the name of the row's source),
  then the declared columns in order.
  """

  alias AshStrangler.Derived.{Info, Source}
  alias AshStrangler.KeyKinds
  alias AshStrangler.Sql.{Printer, View}
  alias AshStrangler.Twin

  @int_min -2_147_483_648
  @int_max 2_147_483_647

  @doc "Every statement for `derived`, in dependency order."
  @spec statements(module() | Spark.Dsl.t()) :: [
          %{name: atom(), up: String.t(), down: String.t()}
        ]
  def statements(derived) do
    schema =
      case Info.schema(derived) do
        "public" -> []
        schema -> [View.schema_statement_for(schema)]
      end

    view = Info.view_name(derived)
    selects = Enum.map(Info.sources(derived), &select(derived, &1))

    schema ++
      [
        %{
          name: :"strangler_#{Info.view(derived)}_view",
          up:
            "CREATE OR REPLACE VIEW #{view} AS\n" <> Enum.join(selects, "\nUNION ALL\n") <> ";\n",
          down: "DROP VIEW IF EXISTS #{view};"
        }
      ]
  end

  @doc """
  The census of an `element` source over the live rows: how many elements the
  guard refuses and how many there are. One row, two `bigint` columns
  (`refused`, `total`).

  A value present at the path that is not an array (a number, a string, an
  object) yields no element, so the view drops it: each such value counts as
  one refused element and one in the total. A missing path or a JSON null is
  an empty list, not a refusal.
  """
  @spec element_census_sql(module() | Spark.Dsl.t(), Source.t()) :: String.t()
  def element_census_sql(derived, %Source{kind: :element} = source) do
    twin = Info.twin(derived)
    frame = Printer.bare_frame(twin)
    scalar = ~s[jsonb_typeof(#{array(source, frame)}) NOT IN ('array', 'null')]

    """
    WITH "e" AS (
      SELECT count(*) FILTER (WHERE "__e"."__v" IS NULL) AS "refused", count(*) AS "total"
      FROM #{Twin.relation(twin)}
      CROSS JOIN LATERAL #{lateral(source, frame)}
      #{where(derived, source, frame, [])}
    ), "s" AS (
      SELECT count(*) AS "n" FROM #{Twin.relation(twin)}
      #{where(derived, source, frame, [scalar])}
    )
    SELECT ("e"."refused" + "s"."n")::bigint AS refused, ("e"."total" + "s"."n")::bigint AS total
    FROM "e", "s"
    """
  end

  # --- selects -----------------------------------------------------------------

  defp select(derived, %Source{kind: :element} = source) do
    twin = Info.twin(derived)
    frame = Printer.bare_frame(twin)
    key = key_sql(derived, source, frame)

    "(SELECT DISTINCT ON (#{key}) #{head(derived, source, key)},\n  #{columns(derived, source, frame)}\n" <>
      "FROM #{Twin.relation(twin)}\nCROSS JOIN LATERAL #{lateral(source, frame)}\n" <>
      "#{where(derived, source, frame, [~s("__e"."__v" IS NOT NULL)])}\nORDER BY #{key}, \"__e\".\"__o\")"
  end

  defp select(derived, %Source{} = source) do
    twin = Info.twin(derived)
    frame = Printer.bare_frame(twin)
    key = key_sql(derived, source, frame)

    "SELECT #{head(derived, source, key)},\n  #{columns(derived, source, frame)}\n" <>
      "FROM #{Twin.relation(twin)}\n#{where(derived, source, frame, [])}"
  end

  defp head(derived, source, key),
    do:
      "#{key} AS #{q(Info.key(derived))}, #{Printer.literal(to_string(source.name))}::text AS \"__source\""

  defp columns(derived, source, frame) do
    Enum.map_join(Info.columns(derived), ",\n  ", fn c ->
      "CAST(#{read(source, c.name, frame)} AS #{Printer.pg_type!(c.type)}) AS #{q(c.name)}"
    end)
  end

  defp read(%Source{kind: :element} = source, column, frame) do
    cond do
      column == source.value -> ~s("__e"."__v")
      column == source.ordinal -> ~s("__e"."__o")
      true -> mapped(source, column, frame)
    end
  end

  defp read(source, column, frame), do: mapped(source, column, frame)

  defp mapped(source, column, frame) do
    Enum.find_value(source.mappings, "NULL", fn
      %AshStrangler.Union.Map{attribute: ^column, from: from} when is_atom(from) ->
        frame.({[], from})

      %AshStrangler.Union.Map{attribute: ^column, from: from} ->
        Printer.to_sql(from, ref: frame)

      %AshStrangler.Union.Constant{attribute: ^column, value: value} ->
        Printer.literal(value)

      %AshStrangler.Union.TenantKey{attribute: ^column} = key ->
        AshStrangler.Union.Sql.tenant_sql(key, frame)

      %AshStrangler.Union.Unmapped{attributes: attributes} ->
        if column in attributes, do: "NULL"

      _ ->
        nil
    end)
  end

  defp where(derived, source, frame, extra) do
    conditions =
      Enum.map(
        Enum.reject([Info.filter(derived), source.filter], &is_nil/1),
        &"(#{Printer.to_sql(&1, ref: frame)})"
      ) ++ extra ++ not_null(derived, frame)

    case conditions do
      [] -> ""
      _ -> "WHERE " <> Enum.join(conditions, " AND ")
    end
  end

  # A legacy row with a NULL identifying column has no derivable key.
  defp not_null(derived, frame),
    do: for(column <- Info.from(derived), do: "#{frame.({[], column})} IS NOT NULL")

  # --- keys --------------------------------------------------------------------

  defp key_sql(derived, source, frame) do
    from = Enum.map(Info.from(derived), &frame.({[], &1}))
    own = [Printer.literal(to_string(source.name))]
    element = if source.kind == :element, do: [~s("__e"."__v")], else: []

    KeyKinds.logical_sql(Info.registry(derived), Info.kind(derived), from ++ own ++ element)
  end

  # --- elements ----------------------------------------------------------------

  # The elements the guard refuses read NULL in `__v`; the select drops them.
  defp lateral(source, frame) do
    array = array(source, frame)

    ~s[(SELECT #{value(source)} AS "__v", "__j"."__o" FROM jsonb_array_elements(] <>
      "CASE WHEN jsonb_typeof(#{array}) = 'array' THEN #{array} ELSE '[]'::jsonb END) " <>
      ~s[WITH ORDINALITY AS "__j"("__x", "__o")) AS "__e"]
  end

  defp array(%Source{from: from, path: []}, frame), do: "(#{frame.({[], from})})::jsonb"

  defp array(%Source{from: from, path: path}, frame),
    do: "((#{frame.({[], from})})::jsonb #> #{Printer.literal(text_array(path))}::text[])"

  defp text_array(path),
    do:
      "{" <>
        Enum.map_join(path, ",", &~s("#{String.replace(&1, ~w(\\ "), fn c -> "\\" <> c end)}")) <>
        "}"

  # CASE, never AND: PostgreSQL does not promise to stop at the first false
  # operand, and the cast raises for a value that is not a number.
  defp value(%Source{type: :integer}) do
    x = ~s("__j"."__x")

    "CASE WHEN jsonb_typeof(#{x}) = 'number' THEN " <>
      "CASE WHEN (#{x})::numeric = trunc((#{x})::numeric) AND (#{x})::numeric BETWEEN #{@int_min} AND #{@int_max} " <>
      "THEN ((#{x})::numeric)::integer END END"
  end

  defp value(%Source{type: :text}),
    do: ~s[CASE WHEN jsonb_typeof("__j"."__x") = 'string' THEN "__j"."__x" #>> '{}' END]

  defp q(name), do: ~s("#{name}")
end
