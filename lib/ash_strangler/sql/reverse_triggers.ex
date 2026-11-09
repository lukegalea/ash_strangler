# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.ReverseTriggers do
  @moduledoc """
  Builds the `INSTEAD OF` triggers that carry the **old application's** writes
  from the `:read_from_new` reverse view into the Ash-owned table.

  The reverse view (`AshStrangler.Sql.ReverseView`) lets the old application keep
  reading. Without these it could not keep writing: `INSERT INTO users ...` against
  a view whose key is `legacy_id AS id` and whose columns are `decode`s, casts and
  time-zone conversions is refused by PostgreSQL, and the owned table's key is a
  function of the legacy key that nothing would compute. The docs promise the old
  application is "still unchanged" in this phase, so the write path is generated.

  This is `AshStrangler.Sql.Triggers` run the other way, and it is built the same
  way: from the lenses, not from a second description of the mapping.

  ## One declaration, the other direction

  The reverse view renders `AshStrangler.Lens.writes/1` over the owned table. These
  triggers render each lens's **forward** expression, the one the compatibility view
  of `:read_from_legacy` and `:dual_write` and the backfill project, with a frame
  that spells a twin attribute `NEW.<legacy column>`. So a row the old application
  writes is stored as a backfill would have stored it. The owned key is computed
  with the same expression the forward view uses (`AshStrangler.Sql.View.key_expression/3`),
  and the legacy key is stored as `legacy_id`.

  An attribute with no legacy source (an `unmapped` or a `constant`) is not
  assigned. On `INSERT` the owned table's own defaults apply; on `UPDATE` the stored
  value survives. The old application cannot see those columns, so it cannot be the
  one to change them.

  A trigger cannot tell a column the statement left out from one set to `NULL`, so
  a mapped column an `INSERT` leaves out is stored as `NULL`. A legacy `DEFAULT` the
  old application relied on belongs on the view, in the cutover migration
  (`ALTER VIEW ... ALTER COLUMN ... SET DEFAULT`), where PostgreSQL applies it
  before the trigger runs.

  ## When these are emitted, and when they are not

  An `INSTEAD OF` trigger is a trade (`AshStrangler.Mechanism`): on an
  auto-updatable view it costs the old application `ON CONFLICT` and
  `WITH CHECK OPTION`. So they are emitted only when a plain view cannot carry the
  write. The rule is PostgreSQL's:

    * **A view column is updatable only if it is a simple reference** to a column of
      the base table. A column that is a `decode`, a cast, a `zone:` or a `collapse`
      is computed; assigning to it errors. Any such column needs the trigger.
    * **The owned key is derived.** The view exposes `legacy_id AS id`, and the
      owned table's key is `uuid_generate_v5(...)` or a packed key over it. A plain
      `INSERT` would store `legacy_id` and leave the key unset, and a plain `UPDATE`
      of `id` would leave the two disagreeing. Any derived key needs the trigger.

    * **A legacy column more than one attribute reads** would reach only the one
      the view column refers to, leaving the other stale.

  The one shape that needs none of these is an `:identity` key on a resource with
  no `legacy_id`, whose view exposes the owned key itself, with every other column a
  plain rename (`AshStrangler.Mechanism.classify/1` is `:plain`) of a legacy column
  nothing else reads. Then the view is auto-updatable, nothing is emitted, and
  `ON CONFLICT` keeps working. `needed?/1` is that decision.

  A `retired` column (`AshStrangler.Retired`) does not force the trigger by itself:
  it is a NULL constant, which only errors if something assigns to it. With the
  trigger present a write that assigns one is *refused*, never dropped.

  ## The three traps of `AshStrangler.Sql.Triggers`, honoured here

  **`RETURNING` reports what the function returned.** Each `INSERT` and `UPDATE`
  re-reads the stored row through the view and returns that, so the old application
  sees its own key and the values as it will read them.

  **Never `RETURN NULL` for a row that was written.** `INSERT 0 0` is the old
  application's `StaleEntryError`. `RETURN NULL` appears in one place only, a
  `DELETE` that found no row to delete, where `DELETE 0` is the truth.

  **A write that cannot be carried raises.** Changing the key, assigning a retired
  column, a `decode`d value the table has no counterpart for, an `UPDATE` of a row
  that is gone, and an `INSERT` with no key that nothing can allocate all raise
  with the reason, rather than report success.

  ## Allocating a key for an `INSERT` that supplies none

  The old application's `INSERT` may leave `id` out and rely on the sequence that
  lived on the legacy table. `AshStrangler.Verifiers.VerifyKeyAllocation` puts that
  allocation with the legacy side for a derived key. After cutover the legacy table
  is retired, so the allocator that can continue is the one on the owned table's
  `legacy_id` column: the trigger asks PostgreSQL for the sequence that column owns
  (`pg_get_serial_sequence`, which finds a `serial`, `bigserial` or `GENERATED ... AS
  IDENTITY` column) and takes `nextval` from it. A `legacy_id` with no such sequence,
  and an `:identity` key (which the host mints), raise a clear error. The trigger
  never stores a NULL key. Carrying the legacy sequence across, with its current
  value, is part of the cutover migration you write.

  ## `DELETE`

  A `DELETE` through the view deletes the owned row, exactly as the dual-write
  `INSTEAD OF DELETE` deletes the legacy row. Archival is honoured the way it is
  there: `AshArchival` archives with an `UPDATE` of the archive attribute, the
  attribute is mapped (`AshStrangler.Verifiers.VerifyArchival`), and that mapping
  is a column of the reverse view, so an archive reads as the old application's
  `deleted_at` and a legacy `UPDATE` of `deleted_at` archives. A legacy `DELETE`
  is a request to delete, and is not rewritten into an archive.

  ## An `UPDATE` assigns only what the statement changed

  `NEW` holds every column of the view, so a statement that touched one column
  looks like an assignment of all of them. Re-deriving the rest would run each
  stored value through the mapping's round trip, and a value the legacy shape
  cannot express (a state the `decode` table does not list, written by the new
  application) reads as NULL through the view and would be stored back as NULL
  while the old application is told `UPDATE 1`. So each column is assigned only when
  a legacy column it reads differs between `NEW` and `OLD`. This does not depend on
  `on_update`, whose reasons are about the legacy table's own triggers.

  ## One SQL command per statement, and order-independent downs

  As in `AshStrangler.Sql.Triggers`: each function and each trigger is its own
  statement, because a migration's `execute/1` runs on the extended protocol and
  rejects multiple commands. Functions drop `CASCADE` and trigger drops are guarded
  by `to_regclass`, because `down` runs in list order.
  """

  alias AshStrangler.{Expr, Info, Key, Lens, Mechanism, Twin}
  alias AshStrangler.Sql.{Printer, ReverseView, View}

  # The alias of the owned table in a generated `UPDATE`, so a column's stored value
  # is never read by a bare name a PL/pgSQL variable could shadow.
  @target "strangler_target"

  @doc """
  Whether the old application's writes need `INSTEAD OF` triggers, per the rule in
  the moduledoc.
  """
  @spec needed?(Ash.Resource.t()) :: boolean()
  def needed?(resource) do
    case ReverseView.key_exposure(resource) do
      {:legacy_id, _column} ->
        true

      {:key, _column} ->
        lenses = view_lenses(resource)

        Enum.any?(lenses, &(Mechanism.classify(&1) not in [:none, :plain])) or
          shared_legacy_column?(resource, lenses)
    end
  end

  @doc """
  The `INSTEAD OF` insert/update/delete statements for `resource`, or `[]` outside
  `:read_from_new` and where a plain view carries every write.

  `%{name:, up:, down:}`, function then trigger for each operation.
  """
  @spec build(Ash.Resource.t()) :: [%{name: atom(), up: String.t(), down: String.t()}]
  def build(resource) do
    with true <- Info.strangled?(resource),
         :read_from_new <- Info.strangler_phase!(resource),
         true <- needed?(resource) do
      ctx = context(resource)

      Enum.flat_map([:insert, :update, :delete], fn operation ->
        [function_statement(ctx, operation), trigger_statement(ctx, operation)]
      end)
    else
      _ -> []
    end
  end

  # A view column is a reference to one owned column. When two attributes read the
  # same legacy column, or a mapping reads the key's, a plain view would carry the
  # write to one of them and leave the other stale.
  defp shared_legacy_column?(resource, lenses) do
    written = Enum.flat_map(lenses, fn lens -> Enum.map(Lens.writes(lens), &elem(&1, 0)) end)
    columns = written ++ Key.columns(Info.key(resource))

    length(Enum.uniq(columns)) != length(columns)
  end

  defp view_lenses(resource) do
    resource
    |> Lens.for_resource()
    |> Enum.reject(&(&1.combinator in [:key, :tenant]))
  end

  # --- context ----------------------------------------------------------------

  defp context(resource) do
    twin = Info.twin(resource)
    key = Info.key(resource)
    table = AshPostgres.DataLayer.Info.table(resource)
    schema = AshPostgres.DataLayer.Info.schema(resource) || "public"
    {exposure, stored_key_column} = ReverseView.key_exposure(resource)
    nw = fn attribute -> "NEW." <> ReverseView.legacy_column(twin, attribute) end

    %{
      resource: resource,
      twin: twin,
      key: key,
      table: table,
      schema: schema,
      owned: ReverseView.owned_relation(resource),
      view: Info.relation(resource),
      view_literal: Printer.literal(Info.relation(resource)),
      exposure: exposure,
      stored_key_column: stored_key_column,
      owned_key_column: ReverseView.owned_column(resource, key.attribute),
      view_key_column: ReverseView.legacy_column(twin, key.from),
      new_key: nw.(key.from),
      key_expression: View.key_expression(resource, key, fn {_path, from} -> nw.(from) end),
      assignments: assignments(resource, twin, key, exposure),
      decode_guards: decode_guards(resource),
      retired: retired(resource, twin)
    }
  end

  # `{owned_column, expression_over_NEW, changed_condition}` for every attribute with
  # a legacy source, in the lenses' declaration order. The key and `legacy_id` columns
  # are the trigger's own and are never assigned from a mapping.
  defp assignments(resource, twin, key, exposure) do
    frame = forward_frame(twin)

    reserved =
      [ReverseView.owned_column(resource, key.attribute)] ++
        if exposure == :legacy_id, do: [ReverseView.owned_column(resource, :legacy_id)], else: []

    resource
    |> view_lenses()
    |> Enum.filter(&(&1.writes != [] and not is_nil(&1.forward)))
    |> Enum.map(
      &{ReverseView.owned_column(resource, &1.attribute), Printer.to_sql(&1.forward, ref: frame),
       changed_condition(&1, twin)}
    )
    |> Enum.reject(fn {column, _expression, _changed} -> column in reserved end)
    |> Enum.uniq_by(fn {column, _expression, _changed} -> column end)
  end

  # Whether the statement changed a legacy column this mapping reads.
  defp changed_condition(lens, twin) do
    lens.forward
    |> Expr.refs()
    |> Enum.map(fn {_path, attribute} -> ReverseView.legacy_column(twin, attribute) end)
    |> Enum.uniq()
    |> Enum.map_join(" OR ", &"NEW.#{&1} IS DISTINCT FROM OLD.#{&1}")
  end

  # The frame the forward expressions are read in: a twin attribute is the column
  # of the incoming view row, `NEW.<legacy column>`.
  defp forward_frame(twin) do
    fn
      {[], attribute} ->
        "NEW." <> ReverseView.legacy_column(twin, attribute)

      {path, attribute} ->
        raise ArgumentError,
              "a mapping reads #{inspect(attribute)} through #{inspect(path)}; " <>
                "`VerifyReverseMappable` refuses joins in :read_from_new, so this is unreachable"
    end
  end

  # A `decode` table has no counterpart for a legacy value it does not list, and the
  # forward expression answers NULL for it. Storing that NULL would lose what the
  # old application wrote and report success, so the write is refused. The test is
  # whether the table lists the value, because a listed value may decode to NULL.
  defp decode_guards(resource) do
    twin = Info.twin(resource)

    resource
    |> view_lenses()
    |> Enum.filter(&(&1.combinator == :decode))
    |> Enum.map(fn lens ->
      listed =
        lens.entry.values
        |> Enum.map(fn {legacy, _modern} -> legacy end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join(", ", &Printer.literal/1)

      %{
        legacy: "NEW." <> ReverseView.legacy_column(twin, lens.entry.from),
        label: Twin.column!(twin, lens.entry.from),
        listed: listed
      }
    end)
  end

  defp retired(resource, twin) do
    reasons =
      resource
      |> Info.source()
      |> Map.fetch!(:retirements)
      |> Enum.flat_map(fn entry -> Enum.map(entry.columns, &{&1, entry.because}) end)

    for {column, because} <- reasons do
      %{
        new: "NEW." <> ReverseView.legacy_column(twin, column),
        old: "OLD." <> ReverseView.legacy_column(twin, column),
        label: Twin.column!(twin, column),
        because: because
      }
    end
  end

  # --- statements -------------------------------------------------------------

  defp function_name(ctx, operation),
    do: ~s("#{ctx.schema}"."strangler_#{ctx.table}_reverse_#{operation}")

  defp trigger_name(ctx, operation), do: ~s("strangler_#{ctx.table}_reverse_#{operation}")

  defp function_statement(ctx, operation) do
    %{
      name: :"strangler_#{ctx.table}_reverse_#{operation}_function",
      up: function_body(ctx, operation),
      # CASCADE: a trigger depends on its function, and `down` runs in list order.
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

    # `DROP TRIGGER ... ON <view>` raises when the view is already gone, and
    # `IF EXISTS` guards the trigger rather than the relation. The view's own
    # `down` may well have run first, so the drop checks the relation exists.
    down = """
    DO $strangler$
    BEGIN
      IF to_regclass(#{ctx.view_literal}) IS NOT NULL THEN
        EXECUTE 'DROP TRIGGER IF EXISTS #{trigger_name(ctx, operation)} ON #{ctx.view}';
      END IF;
    END $strangler$;
    """

    %{name: :"strangler_#{ctx.table}_reverse_#{operation}_trigger", up: up, down: down}
  end

  defp function_body(ctx, :insert) do
    {columns, values} = Enum.unzip(insert_targets(ctx))

    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :insert)}() RETURNS trigger AS $strangler$
    DECLARE
      stored #{ctx.owned}%ROWTYPE;
      key_sequence text;
    BEGIN
    #{retired_guards(ctx, :insert)}#{decode_guards_sql(ctx)}#{allocation(ctx)}  INSERT INTO #{ctx.owned} (#{Enum.join(columns, ", ")})
      VALUES (#{Enum.join(values, ", ")})
      RETURNING * INTO stored;

      -- Re-read through the view rather than returning NEW. RETURNING on a view
      -- with an INSTEAD OF trigger reports whatever this function returns, so
      -- returning NEW would report NULL for every column the old application did
      -- not supply, including its own key.
      SELECT * INTO NEW FROM #{ctx.view} WHERE #{ctx.view_key_column} = stored.#{ctx.stored_key_column};

      RETURN NEW;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  defp function_body(ctx, :update) do
    assignments =
      case ctx.assignments do
        # Nothing the old application can write, still a row that must exist: the
        # statement is a no-op that fails when the row is gone.
        [] ->
          "#{ctx.stored_key_column} = #{@target}.#{ctx.stored_key_column}"

        assignments ->
          Enum.map_join(assignments, ",\n        ", fn {column, expression, changed} ->
            "#{column} = CASE WHEN #{changed} THEN #{expression} ELSE #{@target}.#{column} END"
          end)
      end

    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :update)}() RETURNS trigger AS $strangler$
    DECLARE
      stored #{ctx.owned}%ROWTYPE;
    BEGIN
    #{retired_guards(ctx, :update)}#{decode_guards_sql(ctx)}  -- The owned key is a function of the legacy key. Changing the legacy key would
      -- leave the two disagreeing, and nothing here could say which row the old
      -- application meant, so it is refused rather than ignored.
      IF NEW.#{ctx.view_key_column} IS DISTINCT FROM OLD.#{ctx.view_key_column} THEN
        RAISE EXCEPTION 'cannot change the key of %: % -> %', #{ctx.view_literal}, OLD.#{ctx.view_key_column}, NEW.#{ctx.view_key_column};
      END IF;

      UPDATE #{ctx.owned} AS #{@target}
      SET #{assignments}
      WHERE #{ctx.stored_key_column} = OLD.#{ctx.view_key_column}
      RETURNING * INTO stored;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'row % no longer exists in %', OLD.#{ctx.view_key_column}, #{ctx.view_literal};
      END IF;

      SELECT * INTO NEW FROM #{ctx.view} WHERE #{ctx.view_key_column} = stored.#{ctx.stored_key_column};

      RETURN NEW;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  defp function_body(ctx, :delete) do
    """
    CREATE OR REPLACE FUNCTION #{function_name(ctx, :delete)}() RETURNS trigger AS $strangler$
    BEGIN
      DELETE FROM #{ctx.owned} WHERE #{ctx.stored_key_column} = OLD.#{ctx.view_key_column};

      -- A row that is already gone was not deleted by this statement, and
      -- `DELETE 0` says so. This is the only place a generated trigger returns NULL.
      IF NOT FOUND THEN
        RETURN NULL;
      END IF;

      -- OLD, not NULL: NULL would report zero rows for a row that was deleted.
      RETURN OLD;
    END $strangler$ LANGUAGE plpgsql;
    """
  end

  # `{owned_column, expression}`: the owned key, then `legacy_id` when the view
  # exposes one, then every attribute with a legacy source.
  defp insert_targets(ctx) do
    legacy_id =
      case ctx.exposure do
        :legacy_id -> [{ctx.stored_key_column, ctx.new_key}]
        :key -> []
      end

    mapped =
      Enum.map(ctx.assignments, fn {column, expression, _changed} -> {column, expression} end)

    [{ctx.owned_key_column, ctx.key_expression}] ++ legacy_id ++ mapped
  end

  # --- guards -----------------------------------------------------------------

  defp retired_guards(%{retired: []}, _operation), do: ""

  defp retired_guards(ctx, operation) do
    Enum.map_join(ctx.retired, "", fn retired ->
      condition =
        case operation do
          :insert -> "#{retired.new} IS NOT NULL"
          :update -> "#{retired.new} IS DISTINCT FROM #{retired.old}"
        end

      """
        IF #{condition} THEN
          RAISE EXCEPTION 'cannot write %.%: retired: %', #{ctx.view_literal}, #{Printer.literal(retired.label)}, #{Printer.literal(retired.because)};
        END IF;

      """
    end)
  end

  defp decode_guards_sql(%{decode_guards: []}), do: ""

  defp decode_guards_sql(ctx) do
    Enum.map_join(ctx.decode_guards, "", fn guard ->
      """
        IF #{guard.legacy} IS NOT NULL AND #{guard.legacy} NOT IN (#{guard.listed}) THEN
          RAISE EXCEPTION 'cannot write %.%: the value % has no counterpart in the new model', #{ctx.view_literal}, #{Printer.literal(guard.label)}, #{guard.legacy};
        END IF;

      """
    end)
  end

  # An INSERT that leaves the key out. See "Allocating a key" in the moduledoc.
  defp allocation(%{key: %{strategy: :identity}} = ctx) do
    """
      IF #{ctx.new_key} IS NULL THEN
        RAISE EXCEPTION 'cannot insert into %: no %, and nothing allocates it (the key is the legacy key itself, which the host mints)', #{ctx.view_literal}, #{Printer.literal(ctx.view_key_column)};
      END IF;

    """
  end

  defp allocation(ctx) do
    owned_literal = Printer.literal(ctx.owned)
    column_literal = Printer.literal(ReverseView.owned_column_name(ctx.resource, :legacy_id))

    """
      IF #{ctx.new_key} IS NULL THEN
        key_sequence := pg_get_serial_sequence(#{owned_literal}, #{column_literal});

        IF key_sequence IS NULL THEN
          RAISE EXCEPTION 'cannot insert into %: no % supplied, and % of % has no sequence to allocate one from', #{ctx.view_literal}, #{Printer.literal(ctx.view_key_column)}, #{column_literal}, #{owned_literal};
        END IF;

        #{ctx.new_key} := nextval(key_sequence);
      END IF;

    """
  end
end
