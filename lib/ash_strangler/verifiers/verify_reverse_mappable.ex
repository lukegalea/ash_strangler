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

  A `writable? false` mapping is a written declaration that no backward
  direction exists. `full_name` cannot yield back `first_name` and `last_name`;
  that is why the mapping had to carry a `because:` in the first place. So the
  legacy columns behind such a mapping cannot appear in the reverse view, and
  the old application would read `NULL` for them — silently, at the exact moment
  the cutover made the new table the source of truth, which is the least
  recoverable moment in the entire migration.

  §7 of the plan calls `:read_from_new` the one-way door. This is the lock on
  it.

  ## What to do about it

  Not "delete the verifier". The mapping is telling you the truth: that data was
  consumed one-way and the old application still wants it. The options are to
  carry the original columns across unchanged as well (map them, even if nothing
  modern reads them), to confirm the old application no longer reads them and
  then map them to a constant or a best-effort expression, or to stop the old
  application first.
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
      This source gathers #{length(AshStrangler.Info.joins(dsl))} joined relation(s), and phase
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
    |> AshStrangler.Info.mappings()
    |> Enum.filter(&(&1.writable? == false))
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

  defp describe(mapping) do
    "  #{inspect(mapping.attribute)} -- #{mapping.because || "(no reason given)"}"
  end
end
