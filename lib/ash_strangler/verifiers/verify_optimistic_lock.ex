# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyOptimisticLock do
  @moduledoc """
  An optimistic lock may not name an attribute the resource projects as a `constant`
  while a view stands in for its table.

  ## Why

  Ash's `optimistic_lock/1` change does two things on every write it is attached to:
  it adds `attribute = <the value the caller read>` to the write's filter, and it
  increments the attribute. A `constant` has no legacy column behind it (it is
  "read-only by construction", see the DSL), so the view answers the same value for
  every row. The filter then always passes, which means the lock refuses nothing,
  and the increment is a write to a column the view cannot carry, so the first
  update fails at runtime or stores nothing.

  Neither failure is visible at compile time without this check. A host that puts
  the lock on every update from its base resource (a common way to make a
  `version_number` column mean what it says) meets it on the first strangled read
  model that projects that column as `constant :version_number, expr(1)`.

  ## What it covers

  Every action that writes the row with the lock attached:

    * update actions, with the change in the action or in the resource's top-level
      `changes` block with `:update` in its `on:`;
    * soft destroy actions, with the change in the action or in `changes` with
      `:destroy` in its `on:`. A soft destroy is an update underneath.

  A hard destroy is not covered. It only filters on the attribute, and a filter on a
  constant is harmless there.

  ## What it does not cover

  `:read_from_new` and `:decommissioned`. From the cutover the resource owns a real
  table, the attribute is a stored column with its own default, and the lock works
  as Ash documents it. A `constant` there only says what the reverse view and the
  backfill write.

  ## What to do instead

  Take the lock off the resource's writes. A host whose base resource adds it to
  every update needs an opt-out on that base for this resource. Or map the attribute
  from a legacy column that really holds a version, so the lock has something to
  compare and increment.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Info
  alias Spark.Dsl.Verifier

  @owned_table_phases [:read_from_new, :decommissioned]

  @impl true
  def verify(dsl) do
    with true <- Info.strangled?(dsl),
         phase when phase not in @owned_table_phases <- Info.strangler_phase!(dsl),
         constants = MapSet.new(Info.constants(dsl), & &1.attribute),
         [_ | _] = locked <- locked_constants(dsl, constants) do
      {:error, error(dsl, phase, locked)}
    else
      _ -> :ok
    end
  end

  # `[{action name, attribute}]`, in action order.
  defp locked_constants(dsl, constants) do
    global = Ash.Resource.Info.changes(dsl)

    for action <- Ash.Resource.Info.actions(dsl),
        writes_row?(action),
        attribute <- lock_attributes(action, global),
        MapSet.member?(constants, attribute),
        uniq: true,
        do: {action.name, attribute}
  end

  defp writes_row?(%{type: :update}), do: true
  defp writes_row?(%{type: :destroy} = action), do: Map.get(action, :soft?, false)
  defp writes_row?(_action), do: false

  defp lock_attributes(action, global) do
    from_action = Enum.flat_map(action.changes || [], &lock_attribute/1)

    from_global =
      global
      |> Enum.filter(&(action.type in List.wrap(&1.on)))
      |> Enum.flat_map(&lock_attribute/1)

    from_action ++ from_global
  end

  defp lock_attribute(%Ash.Resource.Change{change: {Ash.Resource.Change.OptimisticLock, opts}}),
    do: [Keyword.fetch!(opts, :attribute)]

  defp lock_attribute(_change), do: []

  defp error(dsl, phase, locked) do
    module = Verifier.get_persisted(dsl, :module)
    {action, attribute} = hd(locked)

    Spark.Error.DslError.exception(
      module: module,
      path: [:actions, action],
      message: """
      #{inspect(module)} puts an optimistic lock on an attribute it projects as a `constant`:

      #{Enum.map_join(locked, "\n", &describe/1)}

      A constant has no legacy column behind it, so in phase #{inspect(phase)} the view answers the
      same value for every row. The lock's filter (`#{attribute} = <the value read>`) then always
      passes and refuses nothing, and its increment writes to a column the view cannot carry.

      Either:

        * take the lock off these actions (if a base resource adds it to every update, give this
          resource that base's opt-out); or
        * map #{inspect(attribute)} from a legacy column that holds a version, so the lock has
          something to compare and increment.

      From `:read_from_new` the resource owns a table, the attribute is stored, and the lock is
      accepted.
      """
    )
  end

  defp describe({action, attribute}),
    do: "  * action #{inspect(action)} locks on #{inspect(attribute)}"
end
