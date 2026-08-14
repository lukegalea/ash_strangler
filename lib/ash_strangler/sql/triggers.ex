# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Triggers do
  @moduledoc """
  Builds the `INSTEAD OF` triggers that carry writes from the compatibility
  view back to the legacy table, for `:dual_write`.

  ## These are a trade, not an addition

  Adding an `INSTEAD OF` trigger to an auto-updatable view **silently removes**
  upsert support (`ON CONFLICT DO UPDATE` errors; `DO NOTHING` is accepted and
  then inert), correct `RETURNING`, and `WITH CHECK OPTION` enforcement. It
  gains governance of every write and somewhere to put a usage counter. Neither
  side is free, which is why `AshStrangler.Info.writes/1` *derives* whether
  triggers are needed rather than always emitting them, and why
  `AshStrangler.Verifiers.VerifyNoUpserts` rejects `upsert?: true` only on the
  resources whose mapping forced one.

  ## Three things the obvious implementation gets wrong

  **`RETURNING` reports what the trigger function returned, not what was
  stored.** The obvious body — insert, then `RETURN NEW` — returns NULL for
  every column the client did not supply, including the primary key, and raises
  nothing. Ash would hold a record with a null id and no error. So every
  generated function re-reads the stored row through the view and returns
  *that*.

  **Returning `NULL` reports `INSERT 0 0` while the row is written.** Ecto reads
  zero affected rows as `Ecto.StaleEntryError`, so a successful write surfaces
  as an error. Postgres sanctions `RETURN NULL` to mean "I modified nothing";
  a generated trigger must never use it.

  **A trigger that writes nothing still reports success.** A no-op `INSTEAD OF
  UPDATE` returns `UPDATE 1`. Silent data loss with a success response is the
  exact failure this package exists to prevent, so attempts to write a
  `writable? false` mapping raise, quoting the mapping's `because:` text.

  ## Writes reverse the read direction exactly

  A `cast: :timestamptz, from_zone: "UTC"` mapping reads as
  `deleted_at AT TIME ZONE 'UTC'`. Writing back has the *same* hazard in
  reverse: assigning a `timestamptz` to a naive `timestamp` column uses an
  assignment cast that reads the session's `TimeZone` again. So the write side
  emits `NEW.archived_at AT TIME ZONE 'UTC'`, which converts an aware value to
  a naive one in the stated zone — the exact inverse, and independent of the
  connection.
  """

  alias AshStrangler.{Constant, Source, Unmapped}
  alias AshStrangler.Map, as: MapEntry

  @doc """
  Builds the `INSTEAD OF` insert/update/delete statements for `resource_or_dsl`.

  Returns a list of `%{name:, up:, down:}` in dependency order, empty when the
  mapping does not require triggers (`AshStrangler.Info.writes/1` returning
  `:auto`).

  ## One SQL command per statement, necessarily

  Each function and each trigger is its own statement, rather than one
  statement per operation carrying both. That is forced, not stylistic: an
  `AshPostgres.Statement` is rendered as a single `execute("...")`, and
  `Ecto.Adapters.SQL.execute_ddl/4` passes that string to `query!/4` — the
  extended protocol, which rejects multiple commands with
  `42601 cannot insert multiple commands into a prepared statement`. So a
  statement containing a `CREATE FUNCTION` *and* a `CREATE TRIGGER` fails at
  `mix ash.migrate` time.

  The `down`s are written to be order-independent, because AshPostgres runs
  every `Remove` before every `Add` and in list order, which is the opposite of
  what teardown needs: functions drop `CASCADE`, and trigger drops are guarded
  by `to_regclass` so they no-op if the view has already gone.
  """
  def build(resource_or_dsl) do
    source = AshStrangler.Info.source(resource_or_dsl)

    if is_nil(source) or AshStrangler.Info.writes(resource_or_dsl) == :auto do
      []
    else
      do_build(resource_or_dsl, source)
    end
  end

  defp do_build(resource_or_dsl, %Source{keys: [key]} = source) do
    table = AshPostgres.DataLayer.Info.table(resource_or_dsl)
    schema = AshPostgres.DataLayer.Info.schema(resource_or_dsl) || "public"
    view = ~s("#{schema}"."#{table}")

    context = %{
      table: table,
      schema: schema,
      view: view,
      relation: source.relation,
      legacy_key: key.from,
      writable: writable_targets(source),
      read_only: read_only_mappings(source)
    }

    Enum.flat_map([:insert, :update, :delete], fn operation ->
      [
        function_statement(context, operation),
        trigger_statement(context, operation)
      ]
    end)
  end

  defp do_build(resource_or_dsl, %Source{keys: keys}) do
    raise ArgumentError,
          "#{inspect(resource_or_dsl)}'s source declares #{length(keys)} keys; exactly one is required to generate triggers"
  end

  # --- what gets written where ------------------------------------------------

  # `{legacy_column, sql_expression_over_NEW}` for every mapping that writes.
  #
  # `constant` and `unmapped` never write: they have no legacy column to write
  # to. A read-only `map` does not write either, but it is NOT silently skipped
  # -- see `read_only_mappings/1`.
  defp writable_targets(%Source{mappings: mappings}) do
    mappings
    |> Enum.flat_map(fn
      %MapEntry{writable?: false} -> []
      %MapEntry{} = entry -> [{target_column(entry), write_expression(entry)}]
      %Constant{} -> []
      %Unmapped{} -> []
    end)
    |> Enum.reject(fn {column, _} -> is_nil(column) end)
  end

  defp read_only_mappings(%Source{mappings: mappings}) do
    Enum.filter(mappings, &match?(%MapEntry{writable?: false}, &1))
  end

  defp target_column(%MapEntry{into: into}) when is_binary(into), do: into
  defp target_column(%MapEntry{column: column}) when is_binary(column), do: column
  defp target_column(%MapEntry{}), do: nil

  # The inverse of the read projection. See the moduledoc on why the timestamp
  # case cannot be left to an implicit assignment cast.
  #
  # `$NEW.x` is how the DSL lets a `to:` expression refer to the incoming row
  # without the author writing plpgsql; here it becomes a real reference.
  defp write_expression(%MapEntry{to: to}) when is_binary(to) do
    String.replace(to, "$NEW.", "NEW.")
  end

  defp write_expression(%MapEntry{cast: :timestamptz, from_zone: zone, attribute: attribute})
       when is_binary(zone) do
    "NEW.#{attribute} AT TIME ZONE '#{zone}'"
  end

  defp write_expression(%MapEntry{attribute: attribute}), do: "NEW.#{attribute}"

  # --- the statements ---------------------------------------------------------

  defp function_statement(ctx, operation) do
    %{
      name: :"strangler_#{ctx.table}_#{operation}_function",
      up: function_body(ctx, operation),
      # CASCADE, because a trigger depends on this function and the `down`s run
      # in list order -- which puts this one before the trigger that uses it.
      down: "DROP FUNCTION IF EXISTS #{function_name(ctx, operation)}() CASCADE;"
    }
  end

  defp trigger_statement(ctx, operation) do
    keyword = operation |> to_string() |> String.upcase()

    up = """
    CREATE OR REPLACE TRIGGER #{trigger_name(ctx, operation)}
      INSTEAD OF #{keyword} ON #{ctx.view}
      FOR EACH ROW EXECUTE FUNCTION #{function_name(ctx, operation)}();
    """

    # `DROP TRIGGER ... ON <view>` raises if the view is already gone, and
    # `IF EXISTS` does not cover that case -- it guards the trigger, not the
    # relation. Since the view's own `down` may well have run first, the drop
    # is wrapped in a `DO` block (one command, so still statement-safe) that
    # checks the relation exists at all.
    down = """
    DO $strangler$
    BEGIN
      IF to_regclass('#{ctx.schema}.#{ctx.table}') IS NOT NULL THEN
        EXECUTE 'DROP TRIGGER IF EXISTS #{trigger_name(ctx, operation)} ON #{ctx.view}';
      END IF;
    END $strangler$;
    """

    %{name: :"strangler_#{ctx.table}_#{operation}_trigger", up: up, down: down}
  end

  defp function_body(ctx, :insert) do
    columns = Enum.map_join(ctx.writable, ", ", fn {column, _} -> column end)
    values = Enum.map_join(ctx.writable, ", ", fn {_, expression} -> expression end)

    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :insert)}() RETURNS trigger AS $strangler$
    DECLARE
      stored #{ctx.relation}%ROWTYPE;
    BEGIN
    #{read_only_guards(ctx, :insert)}  INSERT INTO #{ctx.relation} (#{columns})
      VALUES (#{values})
      RETURNING * INTO stored;

      -- Re-read through the view rather than returning NEW. RETURNING on a view
      -- with an INSTEAD OF trigger reports whatever this function returns, so
      -- returning NEW would report NULL for every derived column -- silently,
      -- including the primary key.
      SELECT * INTO NEW FROM #{ctx.view} WHERE __legacy_id = stored.#{ctx.legacy_key};

      RETURN NEW;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  defp function_body(ctx, :update) do
    assignments =
      Enum.map_join(ctx.writable, ",\n        ", fn {column, expression} ->
        "#{column} = #{expression}"
      end)

    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :update)}() RETURNS trigger AS $strangler$
    DECLARE
      stored #{ctx.relation}%ROWTYPE;
    BEGIN
    #{read_only_guards(ctx, :update)}  -- Keyed off __legacy_id rather than the derived uuid: the derivation is
      -- one-way, and re-deriving it in SQL to compare would be slower and
      -- another place for the two sides to disagree.
      UPDATE #{ctx.relation}
      SET #{assignments}
      WHERE #{ctx.legacy_key} = OLD.__legacy_id
      RETURNING * INTO stored;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'row % no longer exists in #{ctx.relation}', OLD.__legacy_id;
      END IF;

      SELECT * INTO NEW FROM #{ctx.view} WHERE __legacy_id = stored.#{ctx.legacy_key};

      RETURN NEW;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  defp function_body(ctx, :delete) do
    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :delete)}() RETURNS trigger AS $strangler$
    BEGIN
      DELETE FROM #{ctx.relation} WHERE #{ctx.legacy_key} = OLD.__legacy_id;

      -- OLD, not NULL: returning NULL from an INSTEAD OF trigger reports
      -- "0 rows affected" even though the row is gone, which Ecto surfaces as
      -- Ecto.StaleEntryError on a delete that actually succeeded.
      RETURN OLD;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  # Raises when something tries to change a `writable? false` attribute, quoting
  # the mapping's own `because:`. This is what makes that text worth requiring:
  # it is the message a developer sees at 3am, not documentation.
  #
  # On INSERT the guard fires only for a non-NULL value, since every column of
  # the view is present in NEW whether the client mentioned it or not.
  defp read_only_guards(%{read_only: []}, _operation), do: ""

  defp read_only_guards(ctx, operation) do
    ctx.read_only
    |> Enum.map_join("", fn %MapEntry{attribute: attribute, because: because} ->
      condition =
        case operation do
          :insert -> "NEW.#{attribute} IS NOT NULL"
          :update -> "NEW.#{attribute} IS DISTINCT FROM OLD.#{attribute}"
        end

      """
        IF #{condition} THEN
          RAISE EXCEPTION 'cannot write %.%: %', '#{ctx.table}', '#{attribute}', #{quote_literal(because)};
        END IF;

      """
    end)
  end

  defp function_name(ctx, operation),
    do: ~s("#{ctx.schema}"."strangler_#{ctx.table}_#{operation}")

  defp trigger_name(ctx, operation), do: ~s("strangler_#{ctx.table}_#{operation}")

  # Postgres escapes a single quote inside a string literal by doubling it.
  # `because:` is user-supplied prose and routinely contains apostrophes -- the
  # DSL's own documentation example is "'de la Cruz' splits wrong".
  defp quote_literal(nil), do: "'(no reason given)'"
  defp quote_literal(text), do: "'" <> String.replace(text, "'", "''") <> "'"
end
