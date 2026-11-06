# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Phases do
  @moduledoc """
  Check E8: the phase lattice and the carry rule, over an evaluated estate.

  Each strangled resource contributes one entry (its twin's relation and its
  phase), and each legacy branch of an `AshStrangler.Union` one more (its own
  twin and its own phase). The phases are ordered
  `:read_from_legacy < :dual_write < :read_from_new < :decommissioned`.

  **The carry rule.** An entry at `:read_from_new` or later has moved its
  relation's data into storage the new system owns, and the legacy application
  must keep working against the reverse of it, so no column of the relation may
  be lost. Every column of the entry's relation must therefore be mapped by that
  entry's own resource or union, or declared `carried` or `dead`. A column
  left `deferred` or `legacy_only` (whether by itself or through a declaration
  of the whole relation) blocks the move, and the problem names it. Until then
  `deferred` and `legacy_only` mean "not needed yet", and a resource below
  `:read_from_new` is not held to the rule. A secret column is the twin's to
  carry and is not checked here.

  **The lattice rule.** A relation whose entry is `:decommissioned` no longer
  exists. No other resource or union may still read it.

  Problems carry `check: :phase`.
  """

  alias AshStrangler.Estate.Report
  alias AshStrangler.{Info, Migration, Twin}
  alias AshStrangler.Union.Info, as: UnionInfo

  @moved [:read_from_new, :decommissioned]

  @typedoc "One phase-bearing relation of one module."
  @type entry :: %{module: module(), relation: String.t(), phase: atom(), unit: String.t()}

  @doc "The phase entries of `modules`."
  @spec entries([module()]) :: [entry()]
  def entries(modules), do: Enum.flat_map(modules, &module_entries/1)

  defp module_entries(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        []

      Migration.union?(module) ->
        for branch <- UnionInfo.branches(module) do
          %{
            module: module,
            relation: relation(branch.twin),
            phase: branch.phase,
            unit: "#{inspect(module)} branch #{inspect(branch.name)}"
          }
        end

      function_exported?(module, :spark_dsl_config, 0) and Info.strangled?(module) ->
        [
          %{
            module: module,
            relation: relation(Info.twin(module)),
            phase: Info.strangler_phase!(module),
            unit: inspect(module)
          }
        ]

      true ->
        []
    end
  end

  @doc "The E8 problems of `report` given its `entries`."
  @spec problems(Report.t(), [entry()]) :: [Report.problem()]
  def problems(%Report{} = report, entries) do
    for entry <- entries,
        entry.phase in @moved,
        problem <- carry(report, entry) ++ lattice(report, entry),
        do: problem
  end

  defp carry(report, %{relation: relation} = entry) do
    case report.relations do
      %{^relation => %{declared: %{kind: kind} = declared}}
      when kind in [:deferred, :legacy_only] ->
        [
          problem(
            entry,
            relation,
            "#{relation} is declared #{kind} (#{declared.because}) as a whole"
          )
        ]

      %{^relation => %{columns: columns}} ->
        for {column, info} <- Enum.sort(columns), blocked?(info, entry) do
          problem(
            entry,
            "#{relation}.#{column}",
            "#{relation}.#{column} is declared #{info.declared.kind} (#{info.declared.because})"
          )
        end

      _ ->
        []
    end
    |> Enum.map(&Map.update!(&1, :message, fn m -> carry_message(entry, m) end))
  end

  defp blocked?(%{declared: %{kind: kind}}, _entry) when kind in [:deferred, :legacy_only],
    do: true

  defp blocked?(_info, _entry), do: false

  defp carry_message(entry, message),
    do:
      "#{entry.unit} is #{entry.phase}, but #{message}. Declare it `carried` or `dead`, or map it, " <>
        "before the data moves: the legacy application would lose it."

  defp lattice(report, %{phase: :decommissioned, relation: relation} = entry) do
    readers =
      for {column, info} <- Map.get(report.relations, relation, %{columns: %{}}).columns,
          claim <- info.claims,
          claim.kind == :mapped,
          claim.by != entry.module,
          uniq: true,
          do: {claim.by, column}

    for {by, columns} <- Enum.group_by(readers, &elem(&1, 0), &elem(&1, 1)) do
      problem(
        entry,
        relation,
        "#{inspect(by)} still reads #{Enum.join(Enum.sort(columns), ", ")} of #{relation}, which #{entry.unit} " <>
          "has decommissioned"
      )
    end
  end

  defp lattice(_report, _entry), do: []

  defp problem(_entry, subject, message), do: %{check: :phase, subject: subject, message: message}

  defp relation(twin),
    do: "#{AshPostgres.DataLayer.Info.schema(twin) || "public"}.#{Twin.table!(twin)}"
end
