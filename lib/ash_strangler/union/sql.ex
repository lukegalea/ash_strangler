# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Union.Sql do
  @moduledoc """
  The SQL of an `AshStrangler.Union`: the owned table, a key index per legacy
  branch, the `UNION ALL` view and the `INSTEAD OF` triggers.

  Statements are `%{name:, up:, down:}`, one SQL command each, in dependency
  order (see `AshStrangler.Migration`). Everything a branch reads goes through
  `AshStrangler.Sql.Printer`; nothing is concatenated from user strings except
  through its `literal/1`.

  The view's columns are the key, `__branch` (the name of the row's branch),
  then the declared columns in order. Every branch casts every column to the
  declared type, so branches of different legacy types still union.

  **Writes.** Each trigger function re-reads the stored row through the view
  and returns it, so `RETURNING` carries what was stored. A refusal is raised
  as `ash_error: <json>`, which AshPostgres turns into
  `AshStrangler.Error.BranchWriteRefused`.
  """

  alias AshStrangler.Sql.{Additive, Extension, Printer, View}
  alias AshStrangler.Twin
  alias AshStrangler.Union.{Constant, Info, InsertThrough, TenantKey, Unmapped}
  alias AshStrangler.Union.Extension, as: ExtensionEntry
  alias AshStrangler.Union.Map, as: MapEntry

  @error "Elixir.AshStrangler.Error.BranchWriteRefused"

  @doc "Every statement for `union`, in dependency order."
  @spec statements(module() | Spark.Dsl.t()) :: [
          %{name: atom(), up: String.t(), down: String.t()}
        ]
  def statements(union) do
    schema =
      case Info.schema(union) do
        "public" -> []
        schema -> [View.schema_statement_for(schema)]
      end

    schema ++
      [owned_table(union)] ++
      owned_columns(union) ++
      extension_table(union) ++
      extension_columns(union) ++
      Enum.flat_map(Info.live_branches(union), &key_index(union, &1)) ++
      [reshape(union), view_statement(union)] ++
      Enum.flat_map([:insert, :update, :delete], &[function(union, &1), trigger(union, &1)])
  end

  @doc """
  The statements that move an already-installed union to its current declaration: the extension
  table (`IF NOT EXISTS`), a guard on the installed view's column list, `CREATE OR REPLACE VIEW`
  and `CREATE OR REPLACE FUNCTION`. No owned table and no trigger: both exist already, and a
  trigger keeps pointing at the replaced function.
  """
  @spec move_statements(module() | Spark.Dsl.t()) :: [
          %{name: atom(), up: String.t(), down: String.t()}
        ]
  def move_statements(union) do
    extension_table(union) ++
      extension_columns(union) ++
      [view_guard(union), view_statement(union)] ++
      Enum.map([:insert, :update, :delete], &function(union, &1))
  end

  # Postgres allows `CREATE OR REPLACE VIEW` to append columns only. A rename, removal or reorder
  # is refused here with a pointer to the procedure, rather than by the bare Postgres error.
  defp view_guard(union) do
    view = Info.view_name(union)

    expected = Enum.map_join(view_columns(union), ", ", &Printer.literal(to_string(&1)))

    message =
      "the column list of #{view} changed: renaming, removing or reordering a view column needs a written " <>
        "DROP VIEW and CREATE VIEW, see documentation/topics/phases.md, \"Changing a view's shape, in any phase\""

    %{
      name: :"strangler_#{Info.view(union)}_view_guard",
      up: """
      DO $strangler$
      DECLARE
        installed text[];
        expected text[] := ARRAY[#{expected}];
      BEGIN
        IF to_regclass(#{Printer.literal(view)}) IS NULL THEN
          RAISE EXCEPTION '%', #{Printer.literal("#{view} is not installed: a move replaces an installed union, render the full migration instead")};
        END IF;
        SELECT array_agg(attname::text ORDER BY attnum) INTO installed
          FROM pg_attribute
          WHERE attrelid = to_regclass(#{Printer.literal(view)}) AND attnum > 0 AND NOT attisdropped;
        IF installed IS DISTINCT FROM expected[1:cardinality(installed)] THEN
          RAISE EXCEPTION '%', #{Printer.literal(message)};
        END IF;
      END $strangler$;
      """,
      down: "SELECT 1;"
    }
  end

  # The view's column names, in view order.
  defp view_columns(union),
    do:
      [Info.key(union), "__branch"] ++
        Enum.map(Info.columns(union), & &1.name) ++ Info.tenant_part_columns(union)

  defp reshape(union),
    do:
      Additive.reshape_view(
        :"strangler_#{Info.view(union)}_view",
        Info.view_name(union),
        view_columns(union)
      )

  # --- tables, indexes, view ----------------------------------------------------

  # `ADD COLUMN IF NOT EXISTS` for every declared column, so a column declared after the table was
  # created reaches it.
  defp owned_columns(union) do
    Additive.add_columns(
      :"strangler_#{Info.view(union)}_owned_table",
      Info.owned_table(union),
      Enum.map(Info.columns(union), fn c ->
        %{
          name: to_string(c.name),
          definition: "#{q(c.name)} #{pg(c)}#{if c.null?, do: "", else: " NOT NULL"}",
          not_null_no_default?: not c.null?
        }
      end)
    )
  end

  defp extension_columns(union) do
    if Info.extension?(union) do
      Additive.add_columns(
        :"strangler_#{Info.view(union)}_extension_table",
        Info.extension_table(union),
        union
        |> Info.live_branches()
        |> Enum.flat_map(&Info.extension_columns/1)
        |> Enum.uniq()
        |> Enum.map(fn name ->
          column = Enum.find(Info.columns(union), &(&1.name == name))

          %{
            name: to_string(name),
            definition: Extension.column_definition(name, column.type),
            not_null_no_default?: false
          }
        end)
      )
    else
      []
    end
  end

  defp owned_table(union) do
    table = Info.owned_table(union)
    key = q(Info.key(union))

    columns =
      Enum.map_join(Info.columns(union), ",\n", fn c ->
        "  #{q(c.name)} #{pg(c)}#{if c.null?, do: "", else: " NOT NULL"}"
      end)

    %{
      name: :"strangler_#{Info.view(union)}_owned_table",
      up: """
      CREATE TABLE IF NOT EXISTS #{table} (
        #{key} uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      #{columns}
      );
      """,
      # Never drop native rows: the table goes only when it is empty.
      down: """
      DO $strangler$
      BEGIN
        IF to_regclass(#{Printer.literal(table)}) IS NOT NULL THEN
          IF NOT EXISTS (SELECT 1 FROM #{table}) THEN
            EXECUTE #{Printer.literal("DROP TABLE #{table}")};
          END IF;
        END IF;
      END $strangler$;
      """
    }
  end

  @doc false
  # The extension table of a union whose live branches keep columns in it, or `[]`.
  def extension_table(union) do
    if Info.extension?(union) do
      columns =
        union
        |> Info.live_branches()
        |> Enum.flat_map(&Info.extension_columns/1)
        |> Enum.uniq()
        |> Enum.map(fn name ->
          column = Enum.find(Info.columns(union), &(&1.name == name))
          Extension.column_definition(name, column.type)
        end)

      table = Info.extension_table(union)

      [
        %{
          name: :"strangler_#{Info.view(union)}_extension_table",
          up: """
          CREATE TABLE IF NOT EXISTS #{table} (
            #{q(Info.key(union))} uuid PRIMARY KEY,
            #{Enum.join(columns, ",\n  ")}
          );
          """,
          down: "DROP TABLE IF EXISTS #{table};"
        }
      ]
    else
      []
    end
  end

  defp key_index(union, branch) do
    [%{strategy: strategy} = key] = branch.keys

    if strategy == :identity do
      []
    else
      relation = Twin.sql_relation(branch.twin)
      name = "strangler_#{Info.view(union)}_#{branch.name}_key_idx"
      expression = View.key_sql(key, Twin.relation(branch.twin), Printer.bare_frame(branch.twin))

      [
        %{
          name: :"#{name}",
          up: "CREATE INDEX IF NOT EXISTS #{name} ON #{relation} (#{expression});",
          down: "DROP INDEX IF EXISTS #{qualify(branch.twin, name)};"
        }
      ]
    end
  end

  # The index lives in the schema of the relation it indexes. The schema comes
  # from the twin rather than from splitting the spelled relation: a quoted
  # schema or table may itself contain a dot (`"odd.schema"."t"`), and a string
  # split cannot tell that dot from the separator's.
  defp qualify(twin, name) do
    case AshPostgres.DataLayer.Info.schema(twin) do
      nil -> name
      schema -> "#{Printer.identifier(schema)}.#{name}"
    end
  end

  defp view_statement(union) do
    selects =
      Enum.map(Info.live_branches(union), &legacy_select(union, &1)) ++ [owned_select(union)]

    view = Info.view_name(union)

    %{
      name: :"strangler_#{Info.view(union)}_view",
      up: "CREATE OR REPLACE VIEW #{view} AS\n" <> Enum.join(selects, "\nUNION ALL\n") <> ";\n",
      down: "DROP VIEW IF EXISTS #{view};"
    }
  end

  defp owned_select(union) do
    columns = Enum.map_join(Info.columns(union), ", ", &q(&1.name))

    # Untyped NULLs: the union takes each part's type from the legacy branches, so no branch is cast.
    hidden = Enum.map(Info.tenant_part_columns(union), &", NULL AS #{q(&1)}")

    "SELECT #{q(Info.key(union))}, #{Printer.literal(to_string(Info.owned(union).name))}::text AS \"__branch\", #{columns}#{hidden}\n" <>
      "FROM #{Info.owned_table(union)}"
  end

  defp legacy_select(union, branch) do
    extended? = Info.extension_columns(branch) != []

    # A joined extension table has a key column of its own: qualify the twin's columns.
    frame =
      if extended?,
        do: Printer.qualified_frame(branch.twin, "strangler_src"),
        else: Printer.bare_frame(branch.twin)

    [key] = branch.keys
    key_sql = View.key_sql(key, Twin.relation(branch.twin), frame)

    columns =
      Enum.map_join(Info.columns(union), ",\n  ", fn c ->
        "CAST(#{read_sql(branch, c.name, frame)} AS #{pg(c)}) AS #{q(c.name)}"
      end)

    join =
      if extended?,
        do:
          " AS strangler_src\nLEFT JOIN #{Info.extension_table(union)} AS strangler_ext ON strangler_ext.#{q(Info.key(union))} = #{key_sql}",
        else: ""

    "SELECT #{key_sql} AS #{q(Info.key(union))},\n  #{Printer.literal(to_string(branch.name))}::text AS \"__branch\",\n  #{columns}#{tenant_parts(union, branch, frame)}\n" <>
      "FROM #{Twin.sql_relation(branch.twin)}#{join}#{where(branch, frame)}"
  end

  defp where(%{filter: nil}, _frame), do: ""
  defp where(%{filter: filter}, frame), do: "\nWHERE " <> Printer.to_sql(filter, ref: frame)

  # The tenant key's integer parts as the legacy columns themselves, uncast: a predicate on them pushes
  # into the branch and meets the legacy table's own index (see `AshStrangler.Inversion`).
  defp tenant_parts(union, branch, frame) do
    key = Info.tenant_key(branch, Info.tenant(union))

    Enum.map(Enum.with_index(Info.tenant_part_columns(union)), fn {name, index} ->
      column = key && Enum.at(TenantKey.columns(key), index)
      ",\n  #{if column, do: frame.({[], column}), else: "NULL"} AS #{q(name)}"
    end)
  end

  defp read_sql(branch, column, frame) do
    Enum.find_value(branch.mappings, "NULL", fn
      %MapEntry{attribute: ^column, from: from} when is_atom(from) ->
        frame.({[], from})

      %MapEntry{attribute: ^column, from: from} ->
        Printer.to_sql(from, ref: frame)

      %Constant{attribute: ^column, value: value} ->
        Printer.literal(value)

      %TenantKey{attribute: ^column} = key ->
        tenant_sql(key, frame)

      %ExtensionEntry{attributes: attributes} ->
        if column in attributes, do: "strangler_ext.#{q(column)}"

      %Unmapped{attributes: attributes} ->
        if column in attributes, do: "NULL"

      _ ->
        nil
    end)
  end

  @doc false
  # The packed key of the tenant column, over the branch's twin columns.
  def tenant_sql(%TenantKey{kind: {registry, kind}} = key, frame),
    do:
      AshStrangler.KeyKinds.to_sql(
        registry,
        kind,
        Enum.map(TenantKey.columns(key), &frame.({[], &1}))
      )

  # --- triggers -----------------------------------------------------------------

  defp function_name(union, op),
    do: ~s("#{Info.schema(union)}"."strangler_#{Info.view(union)}_#{op}")

  defp trigger_name(union, op), do: "strangler_#{Info.view(union)}_#{op}"

  defp trigger(union, op) do
    view = Info.view_name(union)
    name = trigger_name(union, op)

    %{
      name: :"#{name}_trigger",
      up: """
      CREATE OR REPLACE TRIGGER #{name} INSTEAD OF #{String.upcase(to_string(op))} ON #{view}
        FOR EACH ROW EXECUTE FUNCTION #{function_name(union, op)}();
      """,
      down: "DROP TRIGGER IF EXISTS #{name} ON #{view};"
    }
  end

  defp function(union, op) do
    %{
      name: :"#{trigger_name(union, op)}_function",
      up: """
      CREATE OR REPLACE FUNCTION #{function_name(union, op)}() RETURNS trigger
      LANGUAGE plpgsql#{definer(union)} AS $strangler$
      #{qualify_functions(union, body(union, op))}
      $strangler$;
      """,
      down: "DROP FUNCTION IF EXISTS #{function_name(union, op)}() CASCADE;"
    }
  end

  # `SET search_path = pg_catalog` leaves no schema to resolve `uuid_generate_v5` in.
  defp definer(union),
    do:
      if(Info.security_definer?(union),
        do: " SECURITY DEFINER SET search_path = pg_catalog",
        else: ""
      )

  defp qualify_functions(union, body) do
    if Info.security_definer?(union) do
      schema = Spark.Dsl.Extension.get_opt(union, [:union], :functions_schema, "public")
      String.replace(body, "uuid_generate_v5(", ~s|"#{schema}".uuid_generate_v5(|)
    else
      body
    end
  end

  defp body(union, :insert) do
    key = q(Info.key(union))
    columns = Info.columns(union)
    names = Enum.map_join([Info.key(union) | Enum.map(columns, & &1.name)], ", ", &q/1)
    values = Enum.map_join(columns, ", ", &"NEW.#{q(&1.name)}")
    owned = Info.owned(union).name

    {declares, refusals} =
      Enum.map_reduce(Info.branches(union), "", fn b, arms ->
        case Info.insert_through(b) do
          %InsertThrough{} = it when b.phase == :dual_write ->
            {[declare_key_vars(b)], arms <> insert_route(union, b, it)}

          _ ->
            reason =
              if b.phase == :read_from_legacy,
                do: b.refused_because,
                else: "inserts land in the owned branch"

            {[], arms <> branch_refusal(b, reason)}
        end
      end)

    """
    DECLARE
      new_id uuid;
    #{Enum.join(declares)}BEGIN
    #{refusals}  IF NEW."__branch" IS NOT NULL AND NEW."__branch" <> #{Printer.literal(to_string(owned))} THEN
        RAISE EXCEPTION 'strangler: unknown branch %', NEW."__branch";
      END IF;
      IF NEW.#{key} IS NOT NULL AND EXISTS (SELECT 1 FROM #{Info.view_name(union)} WHERE #{key} = NEW.#{key}) THEN
        RAISE EXCEPTION 'strangler: key % already exists in #{Info.view(union)}', NEW.#{key} USING ERRCODE = 'unique_violation';
      END IF;
      new_id := coalesce(NEW.#{key}, gen_random_uuid());
      INSERT INTO #{Info.owned_table(union)} (#{names}) VALUES (new_id#{if values == "", do: "", else: ", " <> values});
      SELECT * INTO NEW FROM #{Info.view_name(union)} WHERE #{key} = new_id;
      RETURN NEW;
    END;
    """
  end

  defp body(union, :update) do
    key = q(Info.key(union))
    columns = Info.columns(union)
    owned = Info.owned(union)
    sets = Enum.map_join(columns, ", ", &"#{q(&1.name)} = NEW.#{q(&1.name)}")

    owned_branch =
      "  IF OLD.\"__branch\" = #{Printer.literal(to_string(owned.name))} THEN\n" <>
        if(sets == "",
          do: "    NULL;\n",
          else: "    UPDATE #{Info.owned_table(union)} SET #{sets} WHERE #{key} = OLD.#{key};\n"
        ) <>
        "    IF NOT FOUND THEN RAISE EXCEPTION 'row % no longer exists in #{Info.view(union)}', OLD.#{key}; END IF;\n"

    branches =
      Enum.map_join(Info.live_branches(union), "", fn b ->
        "  ELSIF OLD.\"__branch\" = #{Printer.literal(to_string(b.name))} THEN\n#{update_branch(union, b)}"
      end)

    """
    BEGIN
      IF NEW.#{key} IS DISTINCT FROM OLD.#{key} THEN
        RAISE EXCEPTION 'strangler: the key of a % row cannot change', OLD."__branch";
      END IF;
    #{owned_branch}#{branches}  ELSE
        RAISE EXCEPTION 'strangler: unknown branch %', OLD."__branch";
      END IF;
      SELECT * INTO NEW FROM #{Info.view_name(union)} WHERE #{key} = OLD.#{key};
      IF NOT FOUND THEN RAISE EXCEPTION 'row % is no longer in #{Info.view(union)} after the update', OLD.#{key}; END IF;
      RETURN NEW;
    END;
    """
  end

  defp body(union, :delete) do
    key = q(Info.key(union))
    owned = Info.owned(union)

    branches =
      Enum.map_join(Info.live_branches(union), "", fn b ->
        "  ELSIF OLD.\"__branch\" = #{Printer.literal(to_string(b.name))} THEN\n#{delete_branch(union, b)}"
      end)

    """
    BEGIN
      IF OLD."__branch" = #{Printer.literal(to_string(owned.name))} THEN
        DELETE FROM #{Info.owned_table(union)} WHERE #{key} = OLD.#{key};
        IF NOT FOUND THEN RAISE EXCEPTION 'row % no longer exists in #{Info.view(union)}', OLD.#{key}; END IF;
    #{branches}  ELSE
        RAISE EXCEPTION 'strangler: unknown branch %', OLD."__branch";
      END IF;
      RETURN OLD;
    END;
    """
  end

  # --- the insert route through a legacy branch ---------------------------------

  defp branch_refusal(branch, reason) do
    "  IF NEW.\"__branch\" = #{Printer.literal(to_string(branch.name))} THEN\n    #{refusal(branch, :insert, reason)}\n  END IF;\n"
  end

  # The branch arm that carries an insert into the legacy table. The legacy
  # table allocates its own key, so the trigger inserts the legacy row, reads
  # the allocated key columns back, upserts the extension columns under the
  # key they derive, and re-reads the view row of that key: RETURNING carries
  # the key and every default, with `__branch` naming this branch.
  defp insert_route(union, b, it) do
    frame = Printer.bare_frame(b.twin)
    kinds = Info.lens_kinds(union, b.name)
    [branch_key] = b.keys
    key_columns = AshStrangler.Key.columns(branch_key)
    key_sources = Enum.flat_map(b.keys, &List.wrap(&1.from))
    set_columns = Keyword.keys(it.set)
    extension = Info.extension_columns(b)
    skipped = Info.not_written_back(b)
    canonical_key = Info.key(union)

    # The key expression over the allocated key columns, as the branch's select
    # spells it: identical bytes except that each column is the RETURNING
    # variable that now holds it.
    key_sql =
      View.key_sql(branch_key, Twin.relation(b.twin), fn {[], column} -> key_var(b, column) end)

    writable =
      union
      |> Info.columns()
      |> Enum.reject(&(&1.name in skipped or &1.name in extension))
      |> Enum.filter(fn c ->
        kinds[c.name] == :column and simple?(b, c.name) and
          source_attr(b, c.name) not in key_sources and
          source_attr(b, c.name) not in set_columns and
          (it.columns == [] or c.name in it.columns)
      end)

    writable_names = Enum.map(writable, & &1.name)

    guards =
      "    IF NEW.#{q(canonical_key)} IS NOT NULL THEN\n      " <>
        refusal(b, :insert, "the key column #{canonical_key} is allocated by the legacy table") <>
        "\n    END IF;\n" <>
        Enum.map_join(Info.columns(union), "", fn c ->
          if c.name in extension or c.name in writable_names,
            do: "",
            else: insert_guard(b, c, kinds, skipped, key_sources, set_columns)
        end)

    insert_columns =
      Enum.map(writable, &frame.({[], source_attr(b, &1.name)})) ++
        Enum.map(it.set, fn {column, _} -> frame.({[], column}) end)

    insert_values =
      Enum.map(writable, &"CAST(NEW.#{q(&1.name)} AS #{legacy_type(b, &1.name)})") ++
        Enum.map(it.set, fn {_, value} -> Printer.literal(value) end)

    insert =
      if insert_columns == [] do
        "INSERT INTO #{Twin.relation(b.twin)} DEFAULT VALUES"
      else
        "INSERT INTO #{Twin.relation(b.twin)} (#{Enum.join(insert_columns, ", ")})\nVALUES (#{Enum.join(insert_values, ", ")})"
      end

    returning =
      "RETURNING #{Enum.map_join(key_columns, ", ", &frame.({[], &1}))} " <>
        "INTO #{Enum.map_join(key_columns, ", ", &key_var(b, &1))};\n"

    "  IF NEW.\"__branch\" = #{Printer.literal(to_string(b.name))} THEN\n" <>
      guards <>
      "    #{insert} #{returning}" <>
      extension_upsert_on_insert(union, extension, key_sql) <>
      "    SELECT * INTO NEW FROM #{Info.view_name(union)} WHERE #{q(canonical_key)} = #{key_sql};\n" <>
      "    IF NOT FOUND THEN RAISE EXCEPTION 'row % is not in #{Info.view(union)} after the insert', #{key_sql}; END IF;\n" <>
      "    RETURN NEW;\n" <>
      "  END IF;\n"
  end

  defp insert_guard(b, c, kinds, skipped, key_sources, set_columns) do
    reason =
      cond do
        c.name in skipped ->
          "column #{c.name} is not written back on insert"

        kinds[c.name] == :column and source_attr(b, c.name) in set_columns ->
          "column #{c.name} is set to a constant on this branch's inserts"

        kinds[c.name] == :column and source_attr(b, c.name) in key_sources ->
          "column #{c.name} is read from a legacy column that forms the row's key"

        true ->
          "column #{c.name} has no legacy column to write on this branch"
      end

    "    IF NEW.#{q(c.name)} IS NOT NULL THEN\n      #{refusal(b, :insert, reason)}\n    END IF;\n"
  end

  # A supplied extension column lands in the extension table under the new key;
  # nothing supplied, no row.
  defp extension_upsert_on_insert(_union, [], _key_sql), do: ""

  defp extension_upsert_on_insert(union, extension, key_sql) do
    key = q(Info.key(union))
    supplied = Enum.map_join(extension, " OR ", &"NEW.#{q(&1)} IS NOT NULL")
    names = Enum.map_join(extension, ", ", &q/1)
    values = Enum.map_join(extension, ", ", &"NEW.#{q(&1)}")
    sets = Enum.map_join(extension, ", ", &"#{q(&1)} = EXCLUDED.#{q(&1)}")

    "    IF #{supplied} THEN\n" <>
      "      INSERT INTO #{Info.extension_table(union)} (#{key}, #{names}) VALUES (#{key_sql}, #{values})\n" <>
      "        ON CONFLICT (#{key}) DO UPDATE SET #{sets};\n    END IF;\n"
  end

  # The plpgsql variables an insert route reads the allocated key columns into,
  # one per column the branch's key derives from, typed as the twin types them.
  defp declare_key_vars(b) do
    [branch_key] = b.keys

    branch_key
    |> AshStrangler.Key.columns()
    |> Enum.map_join("", fn column ->
      "  #{key_var(b, column)} #{Printer.pg_type!(Twin.type!(b.twin, column))};\n"
    end)
  end

  defp key_var(b, column) do
    [branch_key] = b.keys
    index = Enum.find_index(AshStrangler.Key.columns(branch_key), &(&1 == column))
    "strangler_#{b.name}_key_#{index}"
  end

  defp update_branch(_union, %{phase: :read_from_legacy} = b),
    do: "    #{refusal(b, :update, b.refused_because)}\n"

  defp update_branch(union, %{phase: :dual_write} = b) do
    frame = Printer.bare_frame(b.twin)
    kinds = Info.lens_kinds(union, b.name)

    key_sources = Enum.flat_map(b.keys, &List.wrap(&1.from))

    skipped = Info.not_written_back(b)
    extension = Info.extension_columns(b)

    {writable, read_only} =
      union
      |> Info.columns()
      |> Enum.reject(&(&1.name in skipped or &1.name in extension))
      |> Enum.split_with(fn c ->
        kinds[c.name] == :column and simple?(b, c.name) and
          source_attr(b, c.name) not in key_sources
      end)

    guards =
      Enum.map_join(read_only, "", fn c ->
        reason =
          if kinds[c.name] == :column and source_attr(b, c.name) in key_sources,
            do: "column #{c.name} is read from a legacy column that forms the row's key",
            else: "column #{c.name} has no legacy column to write on this branch"

        "    IF NEW.#{q(c.name)} IS DISTINCT FROM OLD.#{q(c.name)} THEN\n      " <>
          refusal(b, :update, reason) <> "\n    END IF;\n"
      end)

    write =
      if writable == [] do
        ""
      else
        sets =
          Enum.map_join(
            writable,
            ", ",
            fn c ->
              column = frame.({[], source_attr(b, c.name)})

              # Only a column this write changed is assigned. The trigger's NEW and OLD are both
              # the view scan, so a column the statement left alone carries a value that may
              # predate a concurrent commit to the legacy row; assigning it back would revert
              # that commit.
              "#{column} = CASE WHEN NEW.#{q(c.name)} IS DISTINCT FROM OLD.#{q(c.name)} " <>
                "THEN CAST(NEW.#{q(c.name)} AS #{legacy_type(b, c.name)}) ELSE #{column} END"
            end
          )

        "    UPDATE #{Twin.sql_relation(b.twin)} SET #{sets} WHERE #{legacy_match(union, b)};\n" <>
          "    IF NOT FOUND THEN RAISE EXCEPTION 'row % no longer exists in #{Twin.relation(b.twin)}', OLD.#{q(Info.key(union))}; END IF;\n"
      end

    guards <> write <> extension_upsert(union, b, extension)
  end

  # Changed extension columns are upserted; the legacy table is not written for them.
  defp extension_upsert(_union, _b, []), do: ""

  defp extension_upsert(union, _b, extension) do
    key = q(Info.key(union))
    names = Enum.map_join(extension, ", ", &q/1)
    values = Enum.map_join(extension, ", ", &"NEW.#{q(&1)}")
    # Likewise only a changed extension column is overwritten, so two writers of different
    # extension columns do not revert each other.
    sets =
      Enum.map_join(
        extension,
        ", ",
        &"#{q(&1)} = CASE WHEN NEW.#{q(&1)} IS DISTINCT FROM OLD.#{q(&1)} THEN EXCLUDED.#{q(&1)} ELSE #{Info.extension_table(union)}.#{q(&1)} END"
      )

    changed = Enum.map_join(extension, " OR ", &"NEW.#{q(&1)} IS DISTINCT FROM OLD.#{q(&1)}")

    "    IF #{changed} THEN\n" <>
      "      INSERT INTO #{Info.extension_table(union)} (#{key}, #{names}) VALUES (OLD.#{key}, #{values})\n" <>
      "        ON CONFLICT (#{key}) DO UPDATE SET #{sets};\n    END IF;\n"
  end

  defp delete_branch(_union, %{phase: :read_from_legacy} = b),
    do: "    #{refusal(b, :delete, b.refused_because)}\n"

  defp delete_branch(union, %{phase: :dual_write} = b) do
    case Info.refuse_delete(b) do
      nil -> delete_legacy_row(union, b)
      because -> "    #{refusal(b, :delete, because)}\n"
    end
  end

  defp delete_legacy_row(union, b) do
    "    DELETE FROM #{Twin.sql_relation(b.twin)} WHERE #{legacy_match(union, b)};\n" <>
      "    IF NOT FOUND THEN RAISE EXCEPTION 'row % no longer exists in #{Twin.relation(b.twin)}', OLD.#{q(Info.key(union))}; END IF;\n"
  end

  defp legacy_match(union, b) do
    [key] = b.keys

    "#{View.key_sql(key, Twin.relation(b.twin), Printer.bare_frame(b.twin))} = OLD.#{q(Info.key(union))}"
  end

  # The legacy column's own type, so the write needs no assignment cast from the declared type.
  defp legacy_type(b, column), do: Printer.pg_type!(Twin.type!(b.twin, source_attr(b, column)))

  # A `map from: :column` is writable; `from: expr(...)` that is a bare reference is too.
  defp simple?(b, column), do: source_attr(b, column) != nil

  defp source_attr(b, column) do
    Enum.find_value(b.mappings, fn
      %MapEntry{attribute: ^column, from: from} when is_atom(from) ->
        from

      %MapEntry{attribute: ^column, from: from} ->
        case AshStrangler.Expr.simple_reference(from) do
          {:ok, attribute} -> attribute
          :error -> nil
        end

      _ ->
        nil
    end)
  end

  defp refusal(branch, operation, reason) do
    json =
      Jason.encode!(%{
        exception: @error,
        input: %{
          branch: to_string(branch.name),
          phase: to_string(branch.phase),
          operation: to_string(operation),
          reason: reason
        }
      })

    "RAISE EXCEPTION 'ash_error: %', #{Printer.literal(json)};"
  end

  defp pg(%{type: type}), do: Printer.pg_type!(type)
  defp q(name), do: ~s("#{name}")
end
