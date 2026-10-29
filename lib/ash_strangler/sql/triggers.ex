# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Triggers do
  @moduledoc """
  Builds the `INSTEAD OF` triggers that carry writes from the compatibility
  view back to the legacy table.

  ## These are a trade, and now a rarer one

  Adding an `INSTEAD OF` trigger to an auto-updatable view **silently removes**
  upsert support (`ON CONFLICT DO UPDATE` errors; `DO NOTHING` is accepted and
  then inert), correct `RETURNING`, and `WITH CHECK OPTION` enforcement. It gains
  governance of every write — nothing can reach the base table by a path the
  mapping did not describe, which `MERGE` otherwise can.

  0.1 paid that price whenever *any* computed mapping was writable.
  `AshStrangler.Mechanism` narrowed it: PostgreSQL's `CREATE VIEW` rule is per
  **column**, so a view may hold a mix of plain and computed columns and stay
  auto-updatable. Triggers are now emitted only when at least one mapping writes
  across relations or writes more than one legacy column — which is the case
  nothing weaker can carry.

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
  exact failure this package exists to prevent, so attempts to write a read-only
  mapping raise, quoting the mapping's `because:` text.

  ## Writes reverse the read direction exactly, and now by construction

  In 0.1 the write side was `String.replace(to, "$NEW.", "NEW.")` over a *separately
  hand-written* SQL string, and nothing compared it to the forward direction — which
  is how a wrong inverse shipped and rewrote three of five lifecycle states on an
  update that only assigned an email.

  Now the write expression is `AshStrangler.Lens.writes/1`, built from the same
  combinator as the forward one, and rendered by the same printer through a
  different reference frame: `AshStrangler.Sql.Printer.new_frame/0` spells a
  reference to an attribute as `NEW.<attribute>`. The `$NEW.` sigil authors used to
  type is gone, because an expression over attributes already says what it means.
  """

  alias AshStrangler.{Info, Lens, Sql}
  alias AshStrangler.Sql.Printer

  # Captured at compile time because a guard cannot call a remote function. There is
  # still exactly one definition of the name -- `AshStrangler.Backfill.flag_column/0`
  # -- and this reads it rather than repeating the string.
  @flag_column AshStrangler.Backfill.flag_column()
  @quoted_flag_column ~s("#{@flag_column}")

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
    if Info.strangled?(resource_or_dsl) and Info.writes(resource_or_dsl) == :triggers do
      do_build(resource_or_dsl)
    else
      []
    end
  end

  defp do_build(resource_or_dsl) do
    key =
      Info.key(resource_or_dsl) ||
        raise ArgumentError,
              "#{inspect(resource_or_dsl)}'s source declares no `key`; exactly one is required to generate triggers"

    table = AshPostgres.DataLayer.Info.table(resource_or_dsl)
    schema = AshPostgres.DataLayer.Info.schema(resource_or_dsl) || "public"
    view = ~s("#{schema}"."#{table}")
    lenses = resource_or_dsl |> Lens.for_resource() |> Enum.reject(&(&1.combinator == :key))

    context = %{
      table: table,
      schema: schema,
      view: view,
      relation: Info.relation(resource_or_dsl),
      legacy_key: key.from,
      key: key,
      on_update: Info.on_update(resource_or_dsl),
      backfill_interlock?: Info.backfill_interlock?(resource_or_dsl),
      lenses: lenses,
      read_only: Enum.filter(lenses, &(&1.type == :masked)),
      # The extension table's own write path. Extension columns never appear in
      # the legacy assignments (their lenses have no legacy `writes`); they are
      # written to this relation in the same statement sequence, inside the
      # same transaction the legacy write runs in -- which is what makes a
      # command touching shared and extension data roll back atomically.
      extension_relation:
        extension_relation?(resource_or_dsl) && Sql.Extension.relation(resource_or_dsl),
      extension_pk: extension_relation?(resource_or_dsl) && key.attribute,
      # Rendered through `Sql.View.key_expression/3` against a `stored.`
      # frame, so the row the trigger writes is keyed by the same expression
      # the view's id column carries -- one spelling, not two.
      extension_pk_expr:
        extension_relation?(resource_or_dsl) &&
          Sql.View.key_expression(
            resource_or_dsl,
            key,
            fn {_path, _attribute} -> "stored.#{key.from}" end
          ),
      extension_attrs: Info.extension_attrs(resource_or_dsl),
      # Implicit extension-state columns: `{column, rendered CASE}` from every
      # collapse with `{:extension, _}` states. The CASE is over the collapse
      # attribute in the NEW frame, so an unrelated update of a row sitting in
      # an extension state re-writes what it reads, and a transition out of
      # one NULLs the column.
      extension_state_values: extension_state_values(resource_or_dsl),
      # `{:refuse, _}` and `derived:` states RAISE before anything is written:
      # the transition aborts the transaction, with the declared reason (or
      # the structural one) quoted in the message.
      refuse_states: refuse_states(resource_or_dsl)
    }

    Enum.flat_map([:insert, :update, :delete], fn operation ->
      [
        function_statement(context, operation),
        trigger_statement(context, operation)
      ]
    end)
  end

  defp extension_state_values(resource_or_dsl) do
    resource_or_dsl
    |> Lens.for_resource()
    |> Enum.filter(&(&1.combinator == :collapse))
    |> Enum.flat_map(fn lens ->
      column = Lens.extension_state_columns(lens.entry) |> List.first()
      case_expr = Lens.extension_state_write(lens.entry)

      if column && case_expr do
        [{column, Printer.to_sql(case_expr, ref: Printer.new_frame())}]
      else
        []
      end
    end)
  end

  # Every state a write cannot store, with the message it is refused in.
  # `{:refuse, reason}` declares its own; a `derived:` state refuses
  # structurally -- it is a function of the data, so a stored value could
  # never agree with the reads, and the machine layer refuses the transition
  # before this guard is ever the one to fire.
  defp refuse_states(resource_or_dsl) do
    resource_or_dsl
    |> Lens.for_resource()
    |> Enum.filter(&(&1.combinator == :collapse))
    |> Enum.flat_map(fn lens ->
      Enum.flat_map(lens.entry.states, fn
        %{representation: {:refuse, reason}} = state ->
          [{lens.attribute, state.value, reason}]

        %{derived: true, representation: nil} = state ->
          reason = "a derived state is a function of the legacy data, never a value to store"
          [{lens.attribute, state.value, reason}]

        _state ->
          []
      end)
    end)
  end

  # --- what gets written where ------------------------------------------------

  # `{legacy_column, sql_expression_over_NEW}` for every column that writes,
  # ordered by legacy column name so the generated SQL is stable across runs.
  #
  # `constant` and `unmapped` never write: they have no legacy column to write to.
  # A read-only mapping does not write either, but it is NOT silently skipped --
  # see `read_only_guards/2`.
  defp writable_targets(ctx, operation) do
    touch = touch_mode(operation)

    targets =
      ctx.lenses
      |> Enum.flat_map(fn lens ->
        Enum.map(Lens.writes(lens), fn {column, expression} ->
          {column, Printer.to_sql(expression, ref: Printer.new_frame(), touch: touch)}
        end)
      end)
      |> Enum.uniq_by(fn {column, _sql} -> column end)

    targets
    |> identity_key_target(ctx, operation)
    |> Enum.sort_by(fn {column, _sql} -> to_string(column) end)
    |> interlock(ctx)
  end

  # An `:identity` key is the legacy key itself, so a host-created row mints
  # the canonical id and the INSERT must pass `NEW.<pk>` into the legacy key
  # column -- the sequence (or default) that allocates keys for a `:uuid_v5`
  # mapping must not run here, or the legacy row would carry a key the host's
  # id does not name, and the id the client asked for would be silently
  # replaced by the view's projection of a row it did not create.
  #
  # UPDATE and DELETE need nothing: both key off `__legacy_id`, which the
  # insert stored.
  defp identity_key_target(targets, %{key: %{strategy: :identity} = key}, :insert) do
    [{key.from, "NEW.#{key.attribute}"} | targets]
    |> Enum.uniq_by(fn {column, _sql} -> column end)
  end

  defp identity_key_target(targets, _ctx, _operation), do: targets

  # pgroll's interlock: the writer declares the row done, so a backfill running
  # concurrently never re-derives a row this trigger already handled.
  #
  # `AshStrangler.Backfill` cannot close this from its own side. Its batch
  # statement already selects `WHERE flag` under `FOR NO KEY UPDATE`, and
  # PostgreSQL re-evaluates a locking query's qualification against the updated
  # row version -- so a row this trigger cleared is dropped from the batch
  # automatically. The entire missing half is the `false` nothing was assigning.
  #
  # Appended after the sort rather than sorted with the rest, so the flag reads as
  # what it is: bookkeeping, not part of the mapping.
  #
  # The column is the QUOTED identifier, so the `SET` fragment this produces is
  # byte-identical to `AshStrangler.Backfill.interlock_assignment/0`. That is not
  # cosmetic: a trigger clearing `_strangler_needs_backfill` while the batch
  # statement reads a differently-spelled column is a no-op that reports success, and
  # the only symptom is a backfill that correctly redoes every row forever.
  defp interlock(targets, %{backfill_interlock?: false}), do: targets

  defp interlock(targets, %{backfill_interlock?: true}) do
    targets ++ [{~s("#{@flag_column}"), "false"}]
  end

  # An INSERT has no prior row, so a `touch()` is unconditionally `now()`. An
  # UPDATE compares the old view row against the new one and preserves otherwise;
  # `OLD.<attribute>` is how the prior value is reachable, and the stored legacy
  # value is the bare column name on the right of `SET`.
  defp touch_mode(:update), do: {:preserve, fn {_path, attribute} -> "OLD.#{attribute}" end}
  defp touch_mode(_operation), do: :now

  # --- the statements ---------------------------------------------------------

  defp extension_relation?(resource_or_dsl), do: Info.extension_attrs(resource_or_dsl) != []

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
    writable = writable_targets(ctx, :insert)
    columns = Enum.map_join(writable, ", ", fn {column, _} -> to_string(column) end)
    values = Enum.map_join(writable, ", ", fn {_, expression} -> expression end)

    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :insert)}() RETURNS trigger AS $strangler$
    DECLARE
      stored #{ctx.relation}%ROWTYPE;
    BEGIN
    #{refuse_guards(ctx, :insert)}#{read_only_guards(ctx, :insert)}  INSERT INTO #{ctx.relation} (#{columns})
      VALUES (#{values})
      RETURNING * INTO stored;

      -- The extension write runs BEFORE the re-select, on purpose: the
      -- re-select replaces NEW with the stored row as the view projects it --
      -- the view that COALESCEs the extension's own columns -- so extension
      -- values read out of NEW afterwards would be the defaults, not what the
      -- command supplied. The key is taken from `stored` (the legacy row this
      -- function just wrote) and rendered through the same key expression the
      -- view's id column is, so the two cannot disagree.
    #{extension_insert(ctx)}
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
      ctx
      |> writable_targets(:update)
      |> Enum.map_join(",\n        ", fn {column, expression} ->
        "#{column} = #{assignment(ctx, column, expression)}"
      end)

    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :update)}() RETURNS trigger AS $strangler$
    DECLARE
      stored #{ctx.relation}%ROWTYPE;
    BEGIN
    #{refuse_guards(ctx, :update)}#{read_only_guards(ctx, :update)}  -- Keyed off __legacy_id rather than the derived uuid: the derivation is
      -- one-way, and re-deriving it in SQL to compare would be slower and
      -- another place for the two sides to disagree.
      UPDATE #{ctx.relation}
      SET #{assignments}
      WHERE #{ctx.legacy_key} = OLD.__legacy_id
      RETURNING * INTO stored;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'row % no longer exists in #{ctx.relation}', OLD.__legacy_id;
      END IF;

      -- Same order as the INSERT: extension write first, off `stored` and the
      -- command's NEW, re-select after. The upsert also covers the row whose
      -- first update this is: a legacy row predating the extension table has
      -- no extension row until this statement inserts it.
    #{extension_upsert(ctx)}
      SELECT * INTO NEW FROM #{ctx.view} WHERE __legacy_id = stored.#{ctx.legacy_key};

      RETURN NEW;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  defp function_body(ctx, :delete) do
    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :delete)}() RETURNS trigger AS $strangler$
    BEGIN
    #{extension_delete(ctx)}  DELETE FROM #{ctx.relation} WHERE #{ctx.legacy_key} = OLD.__legacy_id;

      -- OLD, not NULL: returning NULL from an INSTEAD OF trigger reports
      -- "0 rows affected" even though the row is gone, which Ecto surfaces as
      -- Ecto.StaleEntryError on a delete that actually succeeded.
      RETURN OLD;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  # --- the extension table's own write path ------------------------------------
  #
  # INSERT always writes the extension row -- written values, NULL where the
  # command did not supply one. "No extension row" means only one thing, and it
  # is history: a legacy row that predates the resource. Letting an INSERT
  # create a row without an extension row would silently add a second meaning.
  #
  # UPDATE upserts for the same reason: the row being updated may predate the
  # extension table, so the first update of a legacy row is an INSERT into the
  # extension and every later one is an UPDATE. `ON CONFLICT DO UPDATE` covers
  # both inside the same transaction as the legacy write.
  #
  # DELETE removes the extension row first, then the legacy row: the extension
  # table has no foreign key to the legacy relation (adding one would make the
  # legacy application's own DELETE fail on a row it cannot see), so the order
  # is what keeps a partially-deleted row from being visible: if the legacy
  # delete fails, the whole transaction rolls back, extension row included.

  defp extension_insert(%{extension_attrs: [], extension_state_values: []}), do: ""

  defp extension_insert(ctx) do
    columns = extension_columns(ctx)
    values = extension_values(ctx)

    """
        INSERT INTO #{ctx.extension_relation} (#{columns})
        VALUES (#{Enum.join(values, ", ")});

    """
  end

  defp extension_upsert(%{extension_attrs: [], extension_state_values: []}), do: ""

  defp extension_upsert(ctx) do
    columns = extension_columns(ctx)
    values = extension_values(ctx)

    # The CASE references NEW.<attr>, which is in scope inside
    # DO UPDATE SET too -- the same spelling works in both positions.
    sets =
      (Enum.map(ctx.extension_attrs, fn attribute ->
         ~s("#{attribute}" = NEW.#{attribute})
       end) ++
         Enum.map(ctx.extension_state_values, fn {column, case_sql} ->
           ~s("#{column}" = #{case_sql})
         end))
      |> Enum.join(", ")

    """
        INSERT INTO #{ctx.extension_relation} (#{columns})
        VALUES (#{Enum.join(values, ", ")})
        ON CONFLICT ("#{ctx.extension_pk}") DO UPDATE SET #{sets};

    """
  end

  defp extension_delete(%{extension_attrs: [], extension_state_values: []}), do: ""

  defp extension_delete(ctx) do
    """
        DELETE FROM #{ctx.extension_relation} WHERE "#{ctx.extension_pk}" = OLD.#{ctx.extension_pk};

    """
  end

  defp extension_columns(%{
         extension_pk: pk,
         extension_attrs: attrs,
         extension_state_values: state_values
       }) do
    Enum.map_join([pk | attrs] ++ Enum.map(state_values, &elem(&1, 0)), ", ", &~s("#{&1}"))
  end

  defp extension_values(%{
         extension_pk_expr: pk_expr,
         extension_attrs: attrs,
         extension_state_values: state_values
       }) do
    [pk_expr] ++
      Enum.map(attrs, &"NEW.#{&1}") ++
      Enum.map(state_values, fn {_column, case_sql} -> case_sql end)
  end

  # Raises when a write carries a state the legacy schema cannot store,
  # quoting the declaration's own reason. The transition aborts the
  # transaction -- "refused while legacy is authoritative" is enforced here,
  # in the same transaction the write would have committed in, not in a
  # validator that only runs on days somebody remembers to run it.
  #
  # On INSERT the guard fires only for a non-NULL value, since every column of
  # the view is present in NEW whether the client mentioned it or not; on
  # UPDATE the value itself is refusal enough -- re-writing the state a row
  # already holds cannot be refused, and no row legitimately holds one of
  # these values anyway, because nothing was ever allowed to store it.
  defp refuse_guards(%{refuse_states: []}, _operation), do: ""

  defp refuse_guards(ctx, :insert) do
    ctx.refuse_states
    |> Enum.map_join("", fn {attribute, value, reason} ->
      """
        IF NEW.#{attribute} IS NOT NULL AND NEW.#{attribute} = #{Printer.literal(value)} THEN
          RAISE EXCEPTION 'strangler: state #{state_label(value)} is unrepresentable in legacy: %', #{quote_literal(reason)} USING ERRCODE = 'P0001';
        END IF;

      """
    end)
  end

  defp refuse_guards(ctx, :update) do
    ctx.refuse_states
    |> Enum.map_join("", fn {attribute, value, reason} ->
      """
        IF NEW.#{attribute} = #{Printer.literal(value)} THEN
          RAISE EXCEPTION 'strangler: state #{state_label(value)} is unrepresentable in legacy: %', #{quote_literal(reason)} USING ERRCODE = 'P0001';
        END IF;

      """
    end)
  end

  defp state_label(value) when is_atom(value), do: ":#{value}"
  defp state_label(value), do: inspect(value)

  # `on_update: :changed_columns` wraps each assignment so a column whose value did
  # not change keeps the value it had. See the `on_update` option for why this is a
  # documented choice with no right answer: PostgreSQL cannot tell "absent from the
  # SET clause" from "set to its current value", so `:full_row` bumps a legacy
  # `updated_at` for columns nobody touched, and `:changed_columns` fails to fire a
  # legacy trigger for a column deliberately re-assigned its own value.
  # The interlock flag is bookkeeping rather than a mapped column, so it is assigned
  # directly. Passing a bare `false` through the `:changed_columns` guard below would
  # be correct and would read as though the flag were something the mapping projects.
  #
  # Matched on the column name rather than on the value, because a mapping could
  # legitimately write the literal `false` to a boolean column and that one *does*
  # belong in the guard.
  defp assignment(_ctx, column, expression) when column == @quoted_flag_column,
    do: expression

  defp assignment(%{on_update: :full_row}, _column, expression), do: expression

  defp assignment(%{on_update: :changed_columns}, column, expression) do
    "(CASE WHEN #{expression} IS DISTINCT FROM #{column} THEN #{expression} ELSE #{column} END)"
  end

  # Raises when something tries to change a read-only attribute, quoting the
  # mapping's own `because:`. This is what makes that text worth requiring: it is
  # the message a developer sees at 3am, not documentation.
  #
  # On INSERT the guard fires only for a non-NULL value, since every column of
  # the view is present in NEW whether the client mentioned it or not.
  defp read_only_guards(%{read_only: []}, _operation), do: ""

  defp read_only_guards(ctx, operation) do
    ctx.read_only
    |> Enum.map_join("", fn %Lens{attribute: attribute, because: because} ->
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

  # `because:` is user-supplied prose and routinely contains apostrophes -- the
  # DSL's own documentation example is "'de la Cruz' splits wrong". Rendered by the
  # one function that owns literal escaping, rather than by a second copy of the
  # doubling rule.
  defp quote_literal(nil), do: "'(no reason given)'"
  defp quote_literal(text), do: Printer.literal(text)
end
