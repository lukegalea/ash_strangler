# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Snapshot.Catalog do
  @moduledoc """
  The catalog facts a strangle verifies against, read from `pg_catalog` and
  written as canonical JSON.

  A catalog is a plain map with string keys, so the value introspected from a
  database and the value decoded from `catalog.json` are the same term:

      %{
        "format" => "ash_strangler.catalog/1",
        "schemas" => ["shop"],
        "extensions" => %{"citext" => "shop"},
        "enums" => %{"shop.order_state" => ["open", "paid"]},
        "domains" => %{"shop.sku" => %{"type" => "text", "udt" => "pg_catalog.text", ...}},
        "relations" => %{"shop.orders" => %{"kind" => "table", "columns" => [...], ...}}
      }

  See the "Snapshot" guide for every field.

  ## What is read, and what is deliberately not

  Relations (tables, partitioned and foreign tables, views, materialized views)
  with their columns in declaration order; primary keys, unique constraints and
  unique indexes (with their predicates), foreign keys (with actions and
  validity), `CHECK` constraints (with the `IN` list when there is one) and
  user triggers; enums; domains; and which schema each extension lives in.

  Objects that belong to an extension (`postgis`'s `spatial_ref_sys`, say) are
  left out: they come with the extension, and the extension's placement is what
  the catalog records. Sequences, functions and non-unique indexes are not read.
  None of them is something a twin, a mapping or a drift gate decides anything
  on.

  A `NOT NULL` constraint added `NOT VALID` (PostgreSQL 18) leaves the column's
  `not_null` false and is recorded among the relation's `checks`, with
  `validated: false`: it does not promise that no row holds a NULL, so a twin
  must not read the column as non-null.

  ### What drift cannot see

  `diff/2` compares only what is recorded, so a change confined to something
  not recorded passes it. Today that includes: a column's collation; `NULLS
  NOT DISTINCT` on a unique constraint or index (its columns are recorded, its
  options are not); a foreign key's `MATCH` and `DEFERRABLE` options; exclusion
  constraints; the fields of a composite type; partition bounds; whether a
  generated column is `STORED` or `VIRTUAL`; and row-level security and its
  policies. Several of these change which rows a table admits or how keys
  compare, so a schema that uses them needs its own review on every capture
  until they are read.

  ## Deterministic by construction

  Every name list is sorted in Elixir (binary order), never by `ORDER BY`,
  whose order is the database collation's. Column order is declaration order,
  which survives a dump and reload; `attnum` itself does not (a dropped column
  leaves a gap), so it is not recorded. Types are printed with an empty
  `search_path`, so every non-`pg_catalog` type is schema-qualified the same
  way on every machine.
  """

  @format "ash_strangler.catalog/1"

  @doc "The catalog format this version reads and writes."
  @spec format() :: String.t()
  def format, do: @format

  # Relations in the requested schemas, minus extension members. `$1` is the
  # schema list in every query below.
  @relations """
  SELECT c.oid, n.nspname, c.relname, c.relkind,
         CASE WHEN c.relkind IN ('v', 'm') THEN pg_get_viewdef(c.oid) END
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = ANY($1)
     AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_class'::regclass
                        AND d.objid = c.oid AND d.deptype = 'e')
  """

  @columns """
  SELECT a.attrelid, a.attname,
         format_type(a.atttypid, a.atttypmod),
         COALESCE(en.nspname || '.' || e.typname, tn.nspname || '.' || t.typname),
         e.oid IS NOT NULL,
         a.attnotnull
           AND NOT EXISTS (SELECT 1 FROM pg_constraint nn
                            WHERE nn.conrelid = a.attrelid AND nn.contype = 'n'
                              AND NOT nn.convalidated AND nn.conkey[1] = a.attnum),
         pg_get_expr(d.adbin, d.adrelid),
         a.attidentity::text,
         a.attgenerated::text
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_type t ON t.oid = a.atttypid
    JOIN pg_namespace tn ON tn.oid = t.typnamespace
    LEFT JOIN pg_type e ON t.typcategory = 'A' AND e.oid = t.typelem
    LEFT JOIN pg_namespace en ON en.oid = e.typnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE n.nspname = ANY($1)
     AND a.attnum > 0
     AND NOT a.attisdropped
   ORDER BY a.attrelid, a.attnum
  """

  # `WITH ORDINALITY`, because a composite key's column order is part of it.
  @constraints """
  SELECT con.conrelid, con.conname, con.contype::text,
         ARRAY(SELECT a.attname
                 FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                 JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
                ORDER BY k.ord),
         pg_get_constraintdef(con.oid),
         con.convalidated,
         fn.nspname || '.' || fc.relname,
         ARRAY(SELECT a.attname
                 FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                 JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum
                ORDER BY k.ord),
         con.confupdtype::text,
         con.confdeltype::text
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_class fc ON fc.oid = con.confrelid
    LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
   WHERE n.nspname = ANY($1)
     AND (con.contype IN ('p', 'u', 'f', 'c') OR (con.contype = 'n' AND NOT con.convalidated))
  """

  # Unique indexes that no constraint owns: `CREATE UNIQUE INDEX`, partial or
  # not. Only key columns (`indnkeyatts`), never `INCLUDE` ones; an expression
  # key is printed as its expression.
  @unique_indexes """
  SELECT x.indrelid, i.relname,
         ARRAY(SELECT CASE WHEN k.attnum = 0
                           THEN pg_get_indexdef(x.indexrelid, k.ord::int, false)
                           ELSE a.attname END
                 FROM unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
                 LEFT JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum
                WHERE k.ord <= x.indnkeyatts
                ORDER BY k.ord),
         pg_get_expr(x.indpred, x.indrelid)
    FROM pg_index x
    JOIN pg_class i ON i.oid = x.indexrelid
    JOIN pg_class c ON c.oid = x.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = ANY($1)
     AND x.indisunique
     AND NOT EXISTS (SELECT 1 FROM pg_constraint con
                      WHERE con.conindid = x.indexrelid AND con.conrelid = x.indrelid)
  """

  @triggers """
  SELECT t.tgrelid, t.tgname, pg_get_triggerdef(t.oid)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = ANY($1) AND NOT t.tgisinternal
  """

  @enums """
  SELECT n.nspname || '.' || t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder)
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_enum e ON e.enumtypid = t.oid
   WHERE n.nspname = ANY($1)
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_type'::regclass
                        AND d.objid = t.oid AND d.deptype = 'e')
   GROUP BY 1
  """

  @domains """
  SELECT t.oid, n.nspname || '.' || t.typname,
         format_type(t.typbasetype, t.typtypmod),
         bn.nspname || '.' || b.typname,
         t.typnotnull, t.typdefault
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_type b ON b.oid = t.typbasetype
    JOIN pg_namespace bn ON bn.oid = b.typnamespace
   WHERE t.typtype = 'd' AND n.nspname = ANY($1)
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_type'::regclass
                        AND d.objid = t.oid AND d.deptype = 'e')
  """

  @domain_checks """
  SELECT con.contypid, con.conname, pg_get_constraintdef(con.oid)
    FROM pg_constraint con
    JOIN pg_type t ON t.oid = con.contypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE n.nspname = ANY($1) AND con.contype = 'c'
  """

  @extensions """
  SELECT e.extname, n.nspname
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE n.nspname = ANY($1)
  """

  @kinds %{
    "r" => "table",
    "p" => "partitioned_table",
    "f" => "foreign_table",
    "v" => "view",
    "m" => "materialized_view"
  }

  @actions %{
    "a" => "no_action",
    "r" => "restrict",
    "c" => "cascade",
    "n" => "set_null",
    "d" => "set_default"
  }

  @doc """
  Reads the catalog of `schemas` through `conn`, a `Postgrex` connection.

  Runs in one read-only transaction with an empty `search_path`, so every type
  outside `pg_catalog` prints schema-qualified.
  """
  @spec introspect(DBConnection.conn(), [String.t()]) :: map()
  def introspect(conn, schemas) do
    schemas = schemas |> Enum.uniq() |> Enum.sort()

    {:ok, catalog} =
      Postgrex.transaction(conn, fn conn ->
        Postgrex.query!(conn, "SET TRANSACTION READ ONLY", [])
        Postgrex.query!(conn, "SELECT set_config('search_path', '', true)", [])
        query = &Postgrex.query!(conn, &1, [schemas]).rows
        read(query, schemas)
      end)

    catalog
  end

  @doc """
  Reads the catalog of `schemas` through `query`, a function from one of the
  catalog's SQL statements to its rows. The statement takes the schema list as
  `$1`, so `query` is expected to bind it.

  `introspect/2` is this over a `Postgrex` connection inside a read-only
  transaction with an empty `search_path`. A caller that cannot open that
  transaction (`mix ash_strangler.check` reads inside the repo's own connection,
  which may be a test's sandbox) passes its own `query`, and has to set the empty
  `search_path` itself. A `CHECK` definition prints a type or operator outside the
  path with its schema, and the value-set parse only reads one of those printings,
  so the same column types differently under a different `search_path`.
  """
  @spec read((String.t() -> [list()]), [String.t()]) :: map()
  def read(query, schemas) do
    relations = query.(@relations)
    names = Map.new(relations, fn [oid, schema, name | _] -> {oid, "#{schema}.#{name}"} end)
    by_relation = &group(query.(&1), names)

    columns = by_relation.(@columns)
    constraints = by_relation.(@constraints)
    unique_indexes = by_relation.(@unique_indexes)
    triggers = by_relation.(@triggers)

    %{
      "format" => @format,
      "schemas" => schemas,
      "extensions" => Map.new(query.(@extensions), fn [name, schema] -> {name, schema} end),
      "enums" => Map.new(query.(@enums), fn [name, labels] -> {name, labels} end),
      "domains" => domains(query.(@domains), query.(@domain_checks)),
      "relations" =>
        Map.new(relations, fn [oid, _schema, _name, kind, definition] ->
          key = names[oid]
          relation_constraints = Map.get(constraints, key, [])
          relation_columns = Enum.map(Map.get(columns, key, []), &column/1)

          {key,
           %{
             "kind" => Map.fetch!(@kinds, kind),
             "definition" => definition,
             "columns" => relation_columns,
             "primary_key" => primary_key(relation_constraints),
             "unique" => unique(relation_constraints, Map.get(unique_indexes, key, [])),
             "foreign_keys" => foreign_keys(relation_constraints),
             "checks" => checks(relation_constraints),
             "triggers" =>
               triggers
               |> Map.get(key, [])
               |> Enum.map(fn [name, definition] ->
                 %{"name" => name, "definition" => definition}
               end)
               |> by_name()
           }}
        end)
    }
  end

  # Rows whose first field is a relation oid, grouped by relation name with the
  # oid dropped. Rows for relations outside the catalog (an extension member's
  # columns, say) are discarded here.
  defp group(rows, names) do
    rows
    |> Enum.filter(fn [oid | _] -> Map.has_key?(names, oid) end)
    |> Enum.group_by(fn [oid | _] -> names[oid] end, fn [_oid | rest] -> rest end)
  end

  defp column([name, type, udt, array?, not_null, default, identity, generated]) do
    generated? = generated not in [nil, ""]

    %{
      "name" => name,
      "type" => type,
      "udt" => udt,
      "array" => array?,
      "not_null" => not_null,
      "default" => if(generated?, do: nil, else: default),
      "generated" => if(generated?, do: default),
      "identity" =>
        case identity do
          "a" -> "always"
          "d" -> "by_default"
          _ -> nil
        end
    }
  end

  defp primary_key(constraints) do
    Enum.find_value(constraints, fn
      [name, "p", columns | _] -> %{"name" => name, "columns" => columns}
      _ -> nil
    end)
  end

  defp unique(constraints, indexes) do
    from_constraints =
      for [name, "u", columns | _] <- constraints,
          do: %{"name" => name, "columns" => columns, "predicate" => nil}

    from_indexes =
      for [name, columns, predicate] <- indexes,
          do: %{"name" => name, "columns" => columns, "predicate" => predicate}

    by_name(from_constraints ++ from_indexes)
  end

  defp foreign_keys(constraints) do
    for [name, "f", columns, _definition, validated, target, target_columns, on_update, on_delete] <-
          constraints do
      %{
        "name" => name,
        "columns" => columns,
        "references" => %{"relation" => target, "columns" => target_columns},
        "on_update" => Map.fetch!(@actions, on_update),
        "on_delete" => Map.fetch!(@actions, on_delete),
        "validated" => validated
      }
    end
    |> by_name()
  end

  # A NOT NULL that is NOT VALID (PostgreSQL 18) is recorded here, beside the
  # CHECKs, and its column as nullable: it refuses new NULLs but does not
  # promise the rows hold none. A validated one is the column's `not_null`.
  defp checks(constraints) do
    for [name, type, columns, definition, validated | _] <- constraints, type in ["c", "n"] do
      values =
        case columns do
          [column] ->
            case AshStrangler.Snapshot.Types.check_values(definition, column) do
              {:ok, values} -> values
              :error -> nil
            end

          _ ->
            nil
        end

      %{
        "name" => name,
        "columns" => columns,
        "definition" => definition,
        "values" => values,
        "validated" => validated
      }
    end
    |> by_name()
  end

  defp domains(rows, check_rows) do
    checks =
      Enum.group_by(check_rows, &hd/1, fn [_oid, name, definition] ->
        %{"name" => name, "definition" => definition}
      end)

    Map.new(rows, fn [oid, name, type, udt, not_null, default] ->
      {name,
       %{
         "type" => type,
         "udt" => udt,
         "not_null" => not_null,
         "default" => default,
         "checks" => checks |> Map.get(oid, []) |> by_name()
       }}
    end)
  end

  defp by_name(entries), do: Enum.sort_by(entries, & &1["name"])

  # --- canonical JSON ----------------------------------------------------

  @doc """
  Canonical JSON: object keys sorted, two-space indentation, a trailing
  newline. The same catalog always encodes to the same bytes, which is what
  lets a lock pin it by hash.
  """
  @spec encode(term()) :: String.t()
  def encode(term), do: IO.iodata_to_binary([encode(term, 0), "\n"])

  defp encode(map, _depth) when map_size(map) == 0, do: "{}"

  defp encode(map, depth) when is_map(map) do
    inner = indent(depth + 1)

    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        [inner, Jason.encode!(to_string(key)), ": ", encode(value, depth + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", entries, "\n", indent(depth), "}"]
  end

  defp encode([], _depth), do: "[]"

  defp encode(list, depth) when is_list(list) do
    inner = indent(depth + 1)

    entries =
      list
      |> Enum.map(&[inner, encode(&1, depth + 1)])
      |> Enum.intersperse(",\n")

    ["[\n", entries, "\n", indent(depth), "]"]
  end

  defp encode(scalar, _depth), do: Jason.encode!(scalar)

  defp indent(depth), do: String.duplicate("  ", depth)

  @doc "Decodes `catalog.json`, refusing a format this version does not read."
  @spec decode(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode(json) do
    case Jason.decode(json) do
      {:ok, %{"format" => @format} = catalog} ->
        {:ok, catalog}

      {:ok, %{"format" => other}} ->
        {:error, "catalog format #{inspect(other)} is not #{inspect(@format)}"}

      {:ok, _other} ->
        {:error, "not a catalog: no \"format\" key"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  # --- diff --------------------------------------------------------------

  @typedoc """
  One difference between a locked catalog and a live one.

  `id` names the object as `"<kind> <path>"` (`"column shop.orders.total"`),
  which is what an allow-list pattern matches.
  """
  @type difference :: %{
          id: String.t(),
          change: :added | :removed | :changed,
          locked: term(),
          live: term()
        }

  @doc """
  Every difference between `locked` and `live`, in a stable order.

  Columns compare on type, nullability, default, identity and generation;
  constraints, indexes and triggers compare whole; relations on kind and view
  definition. Triggers whose name starts `strangler_` are skipped on both
  sides: this package names every trigger it installs that way, and they are
  the strangle's own, not drift, whichever database was captured.
  """
  @spec diff(map(), map()) :: [difference()]
  def diff(locked, live) do
    keyed("extension", locked["extensions"], live["extensions"]) ++
      keyed("enum", locked["enums"], live["enums"]) ++
      keyed("domain", locked["domains"], live["domains"]) ++
      relations(locked["relations"] || %{}, live["relations"] || %{})
  end

  defp relations(locked, live) do
    keyed("relation", Map.new(locked, &shell/1), Map.new(live, &shell/1)) ++
      Enum.flat_map(Enum.sort(Map.keys(locked)), fn key ->
        case live do
          %{^key => live_relation} -> relation_parts(key, locked[key], live_relation)
          _ -> []
        end
      end)
  end

  # The relation itself compares on what is not broken out below.
  defp shell({key, relation}), do: {key, Map.take(relation, ["kind", "definition"])}

  defp relation_parts(key, locked, live) do
    named = fn field -> Map.new(locked[field] || [], &{&1["name"], &1}) end
    live_named = fn field -> Map.new(live[field] || [], &{&1["name"], &1}) end

    ours? = fn {name, _trigger} -> String.starts_with?(name, "strangler_") end
    triggers = Map.reject(named.("triggers"), ours?)
    live_triggers = Map.reject(live_named.("triggers"), ours?)

    keyed("column #{key}.", named.("columns"), live_named.("columns"), "") ++
      keyed("primary_key", %{key => locked["primary_key"]}, %{key => live["primary_key"]}) ++
      keyed("unique #{key}.", named.("unique"), live_named.("unique"), "") ++
      keyed("foreign_key #{key}.", named.("foreign_keys"), live_named.("foreign_keys"), "") ++
      Enum.reject(
        keyed("check #{key}.", named.("checks"), live_named.("checks"), ""),
        &same_value_set?/1
      ) ++
      keyed("trigger #{key}.", triggers, live_triggers, "")
  end

  # A CHECK that is exactly `column IN (...)` compares on its value set, not
  # its text. The locked side has been through a dump and reload and a live
  # database has not, and pg_dump does not round-trip every IN list's text: a
  # varchar list stored as `(ARRAY['a'::character varying])::text[]` reloads as
  # `ARRAY[('a'::character varying)::text]`. Same columns, values and validity
  # admit the same rows.
  defp same_value_set?(%{change: :changed, locked: %{"values" => [_ | _]} = locked, live: live}),
    do: Map.delete(locked, "definition") == Map.delete(live, "definition")

  defp same_value_set?(_difference), do: false

  defp keyed(kind, locked, live, separator \\ " ") do
    locked = locked || %{}
    live = live || %{}

    (Map.keys(locked) ++ Map.keys(live))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      id = kind <> separator <> key

      case {Map.fetch(locked, key), Map.fetch(live, key)} do
        {{:ok, same}, {:ok, same}} -> []
        {{:ok, nil}, {:ok, nil}} -> []
        {{:ok, old}, :error} -> [%{id: id, change: :removed, locked: old, live: nil}]
        {:error, {:ok, new}} -> [%{id: id, change: :added, locked: nil, live: new}]
        {{:ok, old}, {:ok, new}} -> [%{id: id, change: :changed, locked: old, live: new}]
      end
    end)
  end
end
