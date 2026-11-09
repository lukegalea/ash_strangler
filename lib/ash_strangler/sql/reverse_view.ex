# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.ReverseView do
  @moduledoc """
  Builds the `:read_from_new` view: the **legacy** name, defined over the
  Ash-owned table, so the old application keeps working without changing a line
  of its SQL.

  This is the payoff of the whole phase model. The old application still says
  `SELECT * FROM users`; `users` is simply no longer a table. Cutover becomes a
  migration rather than a coordinated deploy of two systems.

  ## The direction flips, and so does everything about it

  | | `:read_from_legacy` / `:dual_write` | `:read_from_new` |
  |---|---|---|
  | Source of truth | legacy tables | the Ash-owned table |
  | View is named for | the modern shape | the **legacy** shape |
  | View reads from | legacy tables | the Ash-owned table |
  | `migrate?` | `false` — the table is a view | `true` — Ash owns a real table |
  | Projection uses | `AshStrangler.Lens`'s forward | the same lens's `writes/1` |

  That last row is the change from 0.1. The reverse projection used to be
  `String.replace(to, "$NEW.", "")` over a separately hand-written SQL string — a
  third representation of one transform, and one that nothing related to the other
  two. It is now the *same* `Lens.writes/1` the trigger uses, rendered through a
  different reference frame: an attribute reference is spelled as the **owned
  attribute's own column** (its `source:` when it has one, quoted when it is not a
  plain lowercase identifier), where the trigger's `new_frame/0` spells it
  `NEW.<attribute>`.

  Because it projects *backwards*, this view can only be built from mappings whose
  reverse exists. A read-only mapping is precisely a declaration that it does not —
  `full_name` cannot yield back `first_name` and `last_name` —
  and `AshStrangler.Verifiers.VerifyReverseMappable` refuses the phase rather than
  emitting a view that quietly returns nulls for columns the old application still
  reads.

  ## Every legacy column is produced, in the twin's order

  The view has one column for **every attribute of the twin**, in the order the
  twin declares them, named by the legacy column (`AshStrangler.Twin.column!/2`,
  quoted by the printer's identifier rule, so a `"GadgetId"` or a key renamed with
  `source:` is spelled as the legacy schema spells it). Order matters: a legacy
  `SELECT *` and a positional `INSERT INTO t VALUES (...)` both depend on it.

  A column is one of three things, and there is no fourth:

    * the **key**, exposed from the stored `legacy_id` (or, for an `:identity` key
      on a resource with no `legacy_id`, from the owned key itself);
    * a column a mapping **writes back** (`AshStrangler.Lens.writes/1`);
    * a column declared `retired`, rendered as `NULL` cast to its PostgreSQL type.

  A twin column that is none of them used to vanish from the view silently, and
  `AshStrangler.Verifiers.VerifyReverseMappable` now refuses the phase for it at
  compile time, naming the columns. `retired [:a, :b], because: "..."` is the
  written way to say the old application no longer reads them. Secret columns are
  not twin attributes, so they are not produced either; see that verifier.

  ## The old application's writes

  This module is the read half. The write half, the `INSTEAD OF` triggers that
  carry the old application's `INSERT`, `UPDATE` and `DELETE` into the owned table,
  is `AshStrangler.Sql.ReverseTriggers`, emitted wherever a plain auto-updatable
  view cannot carry the write.

  ## What this does NOT emit, deliberately

  The **retirement of the old table**. Turning `legacy.users` into a view
  requires that `legacy.users` stop being a table first, which means renaming or
  dropping real data. That is a one-way, downtime-shaped operation whose timing
  depends on facts no generator has — whether the backfill finished, whether the
  reconciler is clean, whether anyone is still writing. So the generator emits the
  view and **nothing else**: retiring the old table is a step you write yourself,
  deliberately, rather than something that ran because a phase word changed.
  """

  alias AshStrangler.{Info, Lens, Twin}
  alias AshStrangler.Sql.Printer

  @doc """
  Builds the reverse view for `resource`.

  Returns `[]` unless the resource is in `:read_from_new`. Does **not** emit the
  retirement of the old table -- see the moduledoc.
  """
  def build(resource) do
    with true <- Info.strangled?(resource),
         :read_from_new <- Info.strangler_phase!(resource) do
      do_build(resource)
    else
      _ -> []
    end
  end

  defp do_build(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    new_relation = owned_relation(resource)
    relation = Info.relation(resource)

    columns = reverse_columns!(resource)

    up = """
    CREATE OR REPLACE VIEW #{relation} AS
    SELECT
    #{Enum.map_join(columns, ",\n", fn {expr, name} -> "  #{expr} AS #{name}" end)}
    FROM #{new_relation};
    """

    [
      %{
        name: :"strangler_#{table}_reverse_view",
        up: up,
        down: "DROP VIEW IF EXISTS #{relation};"
      }
    ]
  end

  @doc false
  # The owned table, schema-qualified and quoted.
  def owned_relation(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    schema = AshPostgres.DataLayer.Info.schema(resource) || "public"
    ~s("#{schema}"."#{table}")
  end

  @doc false
  # The quoted column the owned table stores `attribute` in: the attribute's own
  # `source:` when it has one, its name otherwise. The twin's column names and the
  # owned table's are two namespaces, and only this function and `legacy_column/2`
  # may cross into them.
  def owned_column(resource, attribute),
    do: resource |> owned_column_name(attribute) |> identifier()

  @doc false
  # The same column, unquoted: for the places PostgreSQL takes a column name as a
  # string rather than as an identifier.
  def owned_column_name(resource, attribute) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      %{source: source} when not is_nil(source) -> to_string(source)
      _ -> to_string(attribute)
    end
  end

  @doc false
  # The quoted column the legacy relation calls a twin attribute.
  def legacy_column(twin, attribute), do: twin |> Twin.column!(attribute) |> identifier()

  @doc false
  # A legacy column is whatever the legacy schema named it, and PostgreSQL folds an
  # unquoted identifier to lowercase. The same rule `Printer` applies to the
  # columns it prints, copied rather than reached into: lowercase names stay bare,
  # anything else is quoted.
  def identifier(name) do
    column = to_string(name)

    if column =~ ~r/^[a-z_][a-z0-9_$]*$/,
      do: column,
      else: ~s("#{String.replace(column, ~s("), ~s(""))}")
  end

  @doc false
  # How the view exposes the legacy key.
  #
  #   * `{:legacy_id, owned_column}` -- the stored `legacy_id`. The uuid derivation
  #     runs one way, so the legacy key cannot be recovered from the modern id and
  #     has to have been carried across and stored.
  #   * `{:key, owned_column}` -- the owned key itself, for an `:identity` key on a
  #     resource with no `legacy_id`. There the modern id IS the legacy key, so
  #     there is nothing to carry and the view column is a simple reference.
  def key_exposure(resource) do
    key = Info.key(resource)

    cond do
      Ash.Resource.Info.attribute(resource, :legacy_id) ->
        {:legacy_id, owned_column(resource, :legacy_id)}

      match?(%{strategy: :identity}, key) ->
        {:key, owned_column(resource, key.attribute)}

      true ->
        raise ArgumentError, """
        #{inspect(resource)} is in `:read_from_new` but has no `legacy_id` attribute.

        The reverse view has to expose the legacy primary key, because the old
        application still queries by it. The uuid derivation only runs one way, so
        the legacy key cannot be recovered from the modern id -- it has to have
        been carried across during the backfill and stored:

            attribute :legacy_id, :integer, allow_nil?: false
        """
    end
  end

  @doc false
  # `{twin_attribute, expression_over_the_owned_table}` for every twin column the
  # mappings write back, in the order the lenses declare them. The expressions are
  # `AshStrangler.Lens.writes/1` rendered with the owned attribute's own column
  # name. The key column is not among them: `reverse_columns!/1` places it.
  def written_columns(resource) do
    frame = fn {_path, attribute} -> owned_column(resource, attribute) end

    # `touch: :now` is unreachable here -- a `collapse` carrying `touch()` is
    # `invertible: :semi`, and `VerifyReverseMappable` refuses the phase before this
    # runs. Passed explicitly so a future relaxation of that verifier fails loudly
    # rather than silently freezing an instant into a view definition.
    resource
    |> Lens.for_resource()
    |> Enum.reject(&(&1.combinator == :key))
    |> Enum.flat_map(fn lens ->
      Enum.map(Lens.writes(lens), fn {column, expression} ->
        {column, Printer.to_sql(expression, ref: frame, touch: :now)}
      end)
    end)
    |> Enum.uniq_by(fn {column, _expression} -> column end)
  end

  # `{expression_over_the_owned_table, legacy_column_name}` for EVERY column the
  # twin declares, in the twin's declared order.
  #
  # Every column is produced or declared `retired`; there is no third outcome. A
  # column that silently vanished would narrow the old application's `SELECT *`,
  # and one it named would fail outright. `VerifyReverseMappable` refuses that at
  # compile time, and this raises for a caller that got here without the verifier.
  #
  # The order is the twin's, not alphabetical: a legacy `SELECT *` and a positional
  # `INSERT INTO t VALUES (...)` both depend on it.
  defp reverse_columns!(resource) do
    twin = Info.twin(resource)
    key = Info.key(resource)
    retired = MapSet.new(Info.retired(resource))
    written = Map.new(written_columns(resource))
    {_how, key_column} = key_exposure(resource)

    twin_columns = Twin.columns(twin)
    stale = Map.keys(written) -- twin_columns

    if stale != [] do
      raise ArgumentError,
            "#{inspect(resource)} writes #{inspect(stale)}, which #{inspect(twin)} does not declare. " <>
              "Regenerate the twin: mix ash_strangler.gen.twin #{inspect(twin)}"
    end

    {columns, missing} =
      Enum.reduce(twin_columns, {[], []}, fn column, {columns, missing} ->
        name = legacy_column(twin, column)

        cond do
          column == key.from ->
            {[{key_column, name} | columns], missing}

          Map.has_key?(written, column) ->
            {[{Map.fetch!(written, column), name} | columns], missing}

          MapSet.member?(retired, column) ->
            {[{retired_null(twin, column), name} | columns], missing}

          true ->
            {columns, [column | missing]}
        end
      end)

    if missing != [] do
      raise ArgumentError, """
      #{inspect(resource)} cannot build the reverse view: no mapping writes these \
      columns of #{inspect(twin)}, and none is declared `retired`:

        #{Enum.map_join(Enum.reverse(missing), "\n  ", &inspect/1)}

      The old application would lose them from `SELECT *`.
      """
    end

    Enum.reverse(columns)
  end

  # A retired column is NULL, cast to the type the legacy column has so the view
  # keeps the shape of `SELECT *`. A bare `NULL` in a view is `text`; a type the
  # printer's table does not name keeps the bare `NULL`, as an unmapped column does.
  defp retired_null(twin, column) do
    case Printer.known_pg_type(Twin.type!(twin, column)) do
      {:ok, pg_type} -> "NULL::#{pg_type}"
      :error -> "NULL"
    end
  end
end
