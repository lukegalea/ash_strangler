# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyReverseMappable do
  @moduledoc """
  `:read_from_new` requires every legacy column to be reconstructible.

  ## The one-way door

  In `:read_from_new` the legacy name becomes a *view over the new table*, so
  the old application's `SELECT * FROM users` keeps working. That view has to
  produce every column the old application reads — and it produces them by
  running each mapping **backwards**.

  A mapping `AshStrangler.Lens` classifies `invertible: :no` has no backward
  direction. `full_name` cannot yield back `first_name` and `last_name`; that is why
  such a mapping has to carry a `because:` in the first place. So the legacy columns
  behind it cannot appear in the reverse view, and the old application would read
  `NULL` for them — silently, at the exact moment the cutover made the new table the
  source of truth, which is the least recoverable moment in the entire migration.

  `invertible: :semi` is refused here too, and that is a tightening over 0.1. A
  `coalesce`, a `concat` or a `collapse` carrying `touch()` reverses *modulo*
  something — a default that may also be a legal value, a separator that may occur
  inside an operand, an instant that cannot be recovered. Modulo-something is fine
  for a dual-write trigger, where the legacy row still exists to be compared against.
  It is not fine for the phase in which the legacy table stops existing.

  §7 of the plan calls `:read_from_new` the one-way door. This is the lock on
  it.

  ## What to do about it

  Not "delete the verifier". The mapping is telling you the truth: that data was
  consumed one-way and the old application still wants it. The options are to
  carry the original columns across unchanged as well (map them, even if nothing
  modern reads them), to confirm the old application no longer reads them and
  then map them to a constant or a best-effort expression, or to stop the old
  application first.

  ## A twin column no mapping writes

  The same promise has a second half. The view produces a column by running a
  mapping backwards, so a twin column that **no mapping writes** has nothing to
  produce it from. Left alone it would silently vanish: `SELECT *` narrows, and
  `SELECT that_column` errors. This verifier refuses the phase for it, naming
  the columns, and gives two ways out:

    * map the column (carry it across, even if nothing modern reads it);
    * declare it `retired`, with a required `because:`, when the old application
      no longer reads it. The reverse view then renders it as `NULL` cast to its
      PostgreSQL type, in the twin's own column position. It is a written
      decision, never a silent NULL, and a legacy write that assigns it is
      refused by the `INSTEAD OF` triggers instead of being dropped.

  `retired` is also refused when it contradicts the mapping: a column that is
  retired and also written, a column that is not on the twin, an empty
  `because:`.

  **Secret columns** are not twin attributes (`AshStrangler.Verifiers.VerifySecrets`
  keeps them out), so they are neither checked nor produced here. That is the
  estate carry rule's position too (`AshStrangler.Estate.Phases`): a secret
  column is the twin's to carry. The reverse view cannot show the old application
  a column the twin never held, so the step that retires the old table has to
  keep it, or the old application loses it.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    with true <- AshStrangler.Info.strangled?(dsl),
         :read_from_new <- AshStrangler.Info.strangler_phase!(dsl) do
      cond do
        AshStrangler.Info.joins(dsl) != [] -> {:error, join_error(dsl)}
        (offenders = irreversible(dsl)) != [] -> {:error, error(dsl, offenders)}
        (problems = retired_problems(dsl)) != [] -> {:error, retired_error(dsl, problems)}
        (uncovered = uncovered_columns(dsl)) != [] -> {:error, uncovered_error(dsl, uncovered)}
        true -> :ok
      end
    else
      _ -> :ok
    end
  end

  # A forward view gathers several legacy relations into one shape. Reversing
  # that means scattering one table back across several -- deciding which of
  # them each column belongs to, and what to do when a row exists on one side
  # and not the other. The mapping does not say, and guessing would write real
  # data into the wrong table.
  defp join_error(dsl) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :phase],
      message: """
      This source reads through #{length(AshStrangler.Info.joins(dsl))} relationship(s) on the twin, and phase
      :read_from_new has to run the mapping backwards -- which would mean
      scattering one table back across several legacy tables.

      Nothing in the mapping says which joined relation each column belongs to
      on the way back, or what to do when a row exists on one side and not the
      other, so there is no reversal to generate.

      Before cutting over, split the gathered relations into their own resources
      so each one reverses into exactly one table.
      """
    )
  end

  defp irreversible(dsl) do
    dsl
    |> AshStrangler.Lens.for_resource()
    |> Enum.reject(&(&1.combinator in [:key, :constant, :unmapped, :default]))
    |> Enum.filter(&(&1.invertible in [:no, :semi]))
  end

  defp error(dsl, offenders) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :phase],
      message: """
      Phase :read_from_new makes the legacy name a view over the new table, so
      every legacy column has to be reconstructible. These mappings declared
      that they cannot be:

      #{Enum.map_join(offenders, "\n", &describe/1)}

      The legacy columns behind them would read NULL for the old application,
      starting the moment the cutover ran -- which is the point of no return.

      Either carry those legacy columns across unchanged as well, or confirm
      nothing still reads them and map them explicitly.
      """
    )
  end

  # --- twin columns nothing produces -----------------------------------------

  # The legacy columns the reverse view can produce: the key's, and every one a
  # mapping writes back.
  defp produced_columns(dsl) do
    key_columns =
      dsl |> AshStrangler.Info.key() |> List.wrap() |> Enum.flat_map(&AshStrangler.Key.columns/1)

    written =
      dsl
      |> AshStrangler.Lens.for_resource()
      |> Enum.flat_map(fn lens -> Enum.map(AshStrangler.Lens.writes(lens), &elem(&1, 0)) end)

    MapSet.new(key_columns ++ written)
  end

  defp twin_columns(dsl) do
    case AshStrangler.Info.twin(dsl) do
      nil -> []
      twin -> AshStrangler.Twin.columns(twin)
    end
  end

  defp uncovered_columns(dsl) do
    produced = produced_columns(dsl)
    retired = MapSet.new(AshStrangler.Info.retired(dsl))

    Enum.reject(twin_columns(dsl), &(MapSet.member?(produced, &1) or MapSet.member?(retired, &1)))
  end

  defp retired_problems(dsl) do
    produced = produced_columns(dsl)
    columns = MapSet.new(twin_columns(dsl))

    source = AshStrangler.Info.source(dsl)

    for entry <- source.retirements,
        problem <- retirement_problems(entry, produced, columns),
        do: problem
  end

  defp retirement_problems(entry, produced, columns) do
    blank =
      if String.trim(entry.because || "") == "",
        do: ["  retired #{inspect(entry.columns)} has an empty `because:`"],
        else: []

    unknown =
      for column <- entry.columns,
          not MapSet.member?(columns, column),
          do: "  #{inspect(column)} is retired but is not a column of the twin"

    written =
      for column <- entry.columns,
          MapSet.member?(produced, column),
          do:
            "  #{inspect(column)} is retired but a mapping writes it (or it is the key); drop one of the two"

    blank ++ unknown ++ written
  end

  defp retired_error(dsl, problems) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :retired],
      message: """
      Phase :read_from_new found a `retired` declaration that does not hold:

      #{Enum.join(problems, "\n")}

      `retired` says the old application no longer reads a column that no mapping
      writes. It cannot also be mapped, it has to name a column of the twin, and
      it has to say why.
      """
    )
  end

  defp uncovered_error(dsl, uncovered) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source],
      message: """
      Phase :read_from_new makes the legacy name a view over the new table, and
      no mapping writes these columns of #{inspect(AshStrangler.Info.twin(dsl))}:

      #{Enum.map_join(uncovered, "\n", &"  #{inspect(&1)}")}

      The view cannot produce them. `SELECT *` would silently lose them from the
      old application's results and `SELECT <column>` would fail, starting the
      moment the cutover ran.

      Either carry them across, by mapping each one (even if nothing modern reads
      it):

          map :attribute, from: #{inspect(hd(uncovered))}

      or, if the old application no longer reads them, say so:

          retired #{inspect(uncovered)}, because: "Nothing reads these any more."

      A retired column is rendered as NULL cast to its PostgreSQL type, in its own
      position, so the shape of `SELECT *` is kept. It is a written decision, never
      a silent one.
      """
    )
  end

  defp describe(lens) do
    reason =
      case lens.invertible do
        :no -> lens.because || "(no reason given)"
        :semi -> "reverses only modulo a declared default, separator or `touch()`"
      end

    "  #{inspect(lens.attribute)} -- #{lens.combinator}, invertible: #{lens.invertible} -- #{reason}"
  end
end
