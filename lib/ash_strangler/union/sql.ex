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

  alias AshStrangler.Sql.{Printer, View}
  alias AshStrangler.Twin
  alias AshStrangler.Union.{Constant, Info, TenantKey, Unmapped}
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
      Enum.flat_map(Info.live_branches(union), &key_index(union, &1)) ++
      [view_statement(union)] ++
      Enum.flat_map([:insert, :update, :delete], &[function(union, &1), trigger(union, &1)])
  end

  # --- tables, indexes, view ----------------------------------------------------

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

  defp key_index(union, branch) do
    [%{strategy: strategy} = key] = branch.keys

    if strategy == :identity do
      []
    else
      relation = Twin.relation(branch.twin)
      name = "strangler_#{Info.view(union)}_#{branch.name}_key_idx"
      expression = View.key_sql(key, relation, Printer.bare_frame(branch.twin))

      [
        %{
          name: :"#{name}",
          up: "CREATE INDEX IF NOT EXISTS #{name} ON #{relation} (#{expression});",
          down: "DROP INDEX IF EXISTS #{qualify(relation, name)};"
        }
      ]
    end
  end

  defp qualify(relation, name) do
    case String.split(relation, ".", parts: 2) do
      [schema, _table] -> "#{schema}.#{name}"
      [_table] -> name
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

    "SELECT #{q(Info.key(union))}, #{Printer.literal(to_string(Info.owned(union).name))}::text AS \"__branch\", #{columns}\n" <>
      "FROM #{Info.owned_table(union)}"
  end

  defp legacy_select(union, branch) do
    frame = Printer.bare_frame(branch.twin)
    [key] = branch.keys
    key_sql = View.key_sql(key, Twin.relation(branch.twin), frame)

    columns =
      Enum.map_join(Info.columns(union), ",\n  ", fn c ->
        "CAST(#{read_sql(branch, c.name, frame)} AS #{pg(c)}) AS #{q(c.name)}"
      end)

    "SELECT #{key_sql} AS #{q(Info.key(union))},\n  #{Printer.literal(to_string(branch.name))}::text AS \"__branch\",\n  #{columns}\n" <>
      "FROM #{Twin.relation(branch.twin)}"
  end

  defp read_sql(branch, column, frame) do
    Enum.find_value(branch.mappings, "NULL", fn
      %MapEntry{attribute: ^column, from: from} when is_atom(from) -> frame.({[], from})
      %MapEntry{attribute: ^column, from: from} -> Printer.to_sql(from, ref: frame)
      %Constant{attribute: ^column, value: value} -> Printer.literal(value)
      %TenantKey{attribute: ^column} = key -> tenant_sql(key, frame)
      %Unmapped{attributes: attributes} -> if column in attributes, do: "NULL"
      _ -> nil
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
      LANGUAGE plpgsql AS $strangler$
      #{body(union, op)}
      $strangler$;
      """,
      down: "DROP FUNCTION IF EXISTS #{function_name(union, op)}() CASCADE;"
    }
  end

  defp body(union, :insert) do
    key = q(Info.key(union))
    columns = Info.columns(union)
    names = Enum.map_join([Info.key(union) | Enum.map(columns, & &1.name)], ", ", &q/1)
    values = Enum.map_join(columns, ", ", &"NEW.#{q(&1.name)}")
    owned = Info.owned(union).name

    refusals =
      Enum.map_join(Info.branches(union), "", fn b ->
        reason =
          if b.phase == :read_from_legacy,
            do: b.refused_because,
            else: "inserts land in the owned branch"

        "  IF NEW.\"__branch\" = #{Printer.literal(to_string(b.name))} THEN\n    #{refusal(b, :insert, reason)}\n  END IF;\n"
      end)

    """
    DECLARE
      new_id uuid;
    BEGIN
    #{refusals}  IF NEW."__branch" IS NOT NULL AND NEW."__branch" <> #{Printer.literal(to_string(owned))} THEN
        RAISE EXCEPTION 'strangler: unknown branch %', NEW."__branch";
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

  defp update_branch(_union, %{phase: :read_from_legacy} = b),
    do: "    #{refusal(b, :update, b.refused_because)}\n"

  defp update_branch(union, %{phase: :dual_write} = b) do
    frame = Printer.bare_frame(b.twin)
    kinds = Info.lens_kinds(union, b.name)

    key_sources = Enum.flat_map(b.keys, &List.wrap(&1.from))

    {writable, read_only} =
      union
      |> Info.columns()
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
            &"#{frame.({[], source_attr(b, &1.name)})} = CAST(NEW.#{q(&1.name)} AS #{legacy_type(b, &1.name)})"
          )

        "    UPDATE #{Twin.relation(b.twin)} SET #{sets} WHERE #{legacy_match(union, b)};\n" <>
          "    IF NOT FOUND THEN RAISE EXCEPTION 'row % no longer exists in #{Twin.relation(b.twin)}', OLD.#{q(Info.key(union))}; END IF;\n"
      end

    guards <> write
  end

  defp delete_branch(_union, %{phase: :read_from_legacy} = b),
    do: "    #{refusal(b, :delete, b.refused_because)}\n"

  defp delete_branch(union, %{phase: :dual_write} = b) do
    "    DELETE FROM #{Twin.relation(b.twin)} WHERE #{legacy_match(union, b)};\n" <>
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
