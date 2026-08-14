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
  | Projection uses | `from:` (forward) | `to:` (backward) |

  Because it projects *backwards*, this view can only be built from mappings
  that declared an inverse. A `writable? false` mapping is precisely a
  declaration that no inverse exists, so the legacy columns behind it cannot be
  reconstructed — `full_name` cannot yield back `first_name` and `last_name`.
  `AshStrangler.Verifiers.VerifyReverseMappable` refuses the phase rather than
  emitting a view that quietly returns nulls for columns the old application
  still reads.

  ## What this does NOT emit, deliberately

  The **retirement of the old table**. Turning `legacy.users` into a view
  requires that `legacy.users` stop being a table first, which means renaming or
  dropping real data. That is a one-way, downtime-shaped operation whose timing
  depends on facts no generator has — whether the backfill finished, whether the
  reconciler is clean, whether anyone is still writing. `mix
  ash_strangler.gen.migration` emits the view and a commented-out rename beside
  it, so the dangerous half is a deliberate edit rather than something that ran
  because a phase word changed.
  """

  alias AshStrangler.{Constant, Source, Unmapped}
  alias AshStrangler.Map, as: MapEntry

  @doc """
  Builds the reverse view for `resource`, plus the commented-out retirement
  statement that must precede it.

  Returns `[]` unless the resource is in `:read_from_new`.
  """
  def build(resource) do
    with true <- AshStrangler.Info.strangled?(resource),
         :read_from_new <- AshStrangler.Info.strangler_phase!(resource),
         %Source{} = source <- AshStrangler.Info.source(resource) do
      do_build(resource, source)
    else
      _ -> []
    end
  end

  defp do_build(resource, source) do
    table = AshPostgres.DataLayer.Info.table(resource)
    schema = AshPostgres.DataLayer.Info.schema(resource) || "public"
    new_relation = ~s("#{schema}"."#{table}")

    columns = reverse_columns!(resource, source)

    up = """
    CREATE OR REPLACE VIEW #{source.relation} AS
    SELECT
    #{Enum.map_join(columns, ",\n", fn {expr, name} -> "  #{expr} AS #{name}" end)}
    FROM #{new_relation};
    """

    [
      %{
        name: :"strangler_#{table}_reverse_view",
        up: up,
        down: "DROP VIEW IF EXISTS #{source.relation};"
      }
    ]
  end

  # `{expression_over_the_new_table, legacy_column_name}` for every legacy
  # column the mapping can reconstruct.
  defp reverse_columns!(resource, %Source{mappings: mappings, keys: keys}) do
    key_column =
      case keys do
        [key] -> [{legacy_id_column!(resource), key.from}]
        _ -> []
      end

    key_column ++ Enum.flat_map(mappings, &reverse_column/1)
  end

  defp reverse_column(%MapEntry{writable?: false}), do: []

  defp reverse_column(%MapEntry{to: to, into: into})
       when is_binary(to) and is_binary(into) do
    # `$NEW.x` referred to the incoming row inside a trigger; here the same
    # expression is evaluated over the stored table, so the prefix goes away
    # entirely rather than becoming `NEW.`.
    [{String.replace(to, "$NEW.", ""), into}]
  end

  defp reverse_column(%MapEntry{column: column, cast: :timestamptz, from_zone: zone} = entry)
       when is_binary(column) and is_binary(zone) do
    # The inverse of the forward `AT TIME ZONE`: an aware value converted back
    # to the naive form the legacy column holds, in the stated zone.
    [{"#{entry.attribute} AT TIME ZONE '#{zone}'", column}]
  end

  defp reverse_column(%MapEntry{column: column, attribute: attribute}) when is_binary(column) do
    [{to_string(attribute), column}]
  end

  defp reverse_column(%MapEntry{}), do: []
  defp reverse_column(%Constant{}), do: []
  defp reverse_column(%Unmapped{}), do: []

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
