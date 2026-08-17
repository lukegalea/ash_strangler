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
  different reference frame: `Printer.bare_frame/1` spells an attribute reference
  as a bare column of the stored table, where the trigger's `new_frame/0` spells it
  `NEW.<attribute>`.

  Because it projects *backwards*, this view can only be built from mappings whose
  reverse exists. A read-only mapping is precisely a declaration that it does not —
  `full_name` cannot yield back `first_name` and `last_name` —
  and `AshStrangler.Verifiers.VerifyReverseMappable` refuses the phase rather than
  emitting a view that quietly returns nulls for columns the old application still
  reads.

  ## What this does NOT emit, deliberately

  The **retirement of the old table**. Turning `legacy.users` into a view
  requires that `legacy.users` stop being a table first, which means renaming or
  dropping real data. That is a one-way, downtime-shaped operation whose timing
  depends on facts no generator has — whether the backfill finished, whether the
  reconciler is clean, whether anyone is still writing. So the generator emits the
  view and **nothing else**: retiring the old table is a step you write yourself,
  deliberately, rather than something that ran because a phase word changed.
  """

  alias AshStrangler.{Info, Lens}
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
    schema = AshPostgres.DataLayer.Info.schema(resource) || "public"
    new_relation = ~s("#{schema}"."#{table}")
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

  # `{expression_over_the_new_table, legacy_column_name}` for every legacy column
  # the mapping can reconstruct, ordered by legacy column so the SQL is stable.
  defp reverse_columns!(resource) do
    key = Info.key(resource)

    key_column =
      case key do
        nil -> []
        key -> [{legacy_id_column!(resource), key.from}]
      end

    # `touch: :now` is unreachable here -- a `collapse` carrying `touch()` is
    # `invertible: :semi`, and `VerifyReverseMappable` refuses the phase before this
    # runs. Passed explicitly so a future relaxation of that verifier fails loudly
    # rather than silently freezing an instant into a view definition.
    mapped =
      resource
      |> Lens.for_resource()
      |> Enum.reject(&(&1.combinator == :key))
      |> Enum.flat_map(fn lens ->
        Enum.map(Lens.writes(lens), fn {column, expression} ->
          {Printer.to_sql(expression, ref: Printer.bare_frame(), touch: :now), column}
        end)
      end)
      |> Enum.uniq_by(fn {_expression, column} -> column end)
      |> Enum.sort_by(fn {_expression, column} -> to_string(column) end)

    key_column ++ mapped
  end

  # The legacy key has to survive into the new table, or the old application's
  # integer ids stop resolving the moment the view goes live. There is nothing
  # to derive it from in this direction -- the uuid derivation is one-way -- so
  # it must be a real stored column.
  defp legacy_id_column!(resource) do
    if Ash.Resource.Info.attribute(resource, :legacy_id) do
      "legacy_id"
    else
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
end
