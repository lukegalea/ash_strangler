# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyCollapseRepresentation do
  @moduledoc """
  The `representation:` grammar on collapse states: every state declares
  exactly one answer to "what does a write to this state do?", and the
  declarations hold together.

    * an ordinary state (no `representation:`, not `derived:`) requires `when:`
      and `set:` — the original contract, unchanged.
    * `{:extension, _}` — no `when:`, no `set:` (there is no legacy encoding to
      guard on or write to), and the resource must actually declare an
      `extension` block, because that is where the implicit column lives.
    * `{:refuse, _}` — no `when:`, no `set:`.
    * `{:lossy, to:, loss:}` — no `when:`, and `to:` must name a state with a
      `set:` (the loss applies that state's write values; pointing it at
      another unrepresentable state would be one loss chasing another).
    * `derived: true` — `when:` required (a derived state IS its guard), and
      `set:` forbidden (nothing was stored, so there is nothing to write back).

  The `derived:` guard may be time-nondeterministic —
  `expr(expiry_date < fragment("CURRENT_DATE"))` — because it renders in the
  view's SELECT, not in a generated column.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Collapse
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case AshStrangler.Info.source(dsl) do
      nil ->
        :ok

      source ->
        module = Verifier.get_persisted(dsl, :module)
        declared_extension? = source.extensions != []

        source.mappings
        |> Enum.filter(&is_struct(&1, Collapse))
        |> Enum.flat_map(&collapse_errors(&1, declared_extension?))
        |> case do
          [] ->
            :ok

          [message | _] ->
            {:error,
             Spark.Error.DslError.exception(
               module: module,
               path: [:strangler, :source, :collapse],
               message: message
             )}
        end
    end
  end

  defp collapse_errors(entry, declared_extension?) do
    states_by_value = Map.new(entry.states, &{&1.value, &1})

    entry.states
    |> Enum.flat_map(&state_errors(entry, &1, states_by_value, declared_extension?))
    |> Enum.map(fn message -> "collapse #{inspect(entry.attribute)}: " <> message end)
  end

  defp state_errors(entry, state, states_by_value, declared_extension?) do
    represented? = state.representation != nil
    set_declared? = state.set not in [nil, []]

    cond do
      state.derived and represented? ->
        [
          "state #{inspect(state.value)} declares both `derived: true` and `representation:` -- a derived state needs neither storage nor a declared loss"
        ]

      state.derived ->
        derived_errors(state, set_declared?)

      match?({:extension, _}, state.representation) ->
        missing_extension =
          if declared_extension?,
            do: [],
            else: [
              "state #{inspect(state.value)} declares {:extension, _} but the source has no `extension` block -- there is no table for the implicit column to live in"
            ]

        represented_errors(state) ++ missing_extension

      match?({:refuse, _}, state.representation) ->
        represented_errors(state)

      match?({:lossy, _, _}, state.representation) ->
        represented_errors(state) ++ lossy_errors(entry, state, states_by_value)

      state.when == nil ->
        [
          "state #{inspect(state.value)} has no `when:` and no `representation:` -- every legacy-encoded state is guarded by a `when:` or `:otherwise`"
        ]

      not set_declared? ->
        [
          "state #{inspect(state.value)} has no `set:` -- the backward direction is total because every clause writes every column the table touches"
        ]

      true ->
        []
    end
  end

  defp derived_errors(state, set_declared?) do
    [
      if(state.when in [nil, :otherwise],
        do:
          "derived state #{inspect(state.value)} requires a `when:` -- a derived state IS its guard",
        else: nil
      ),
      if(set_declared?,
        do:
          "derived state #{inspect(state.value)} takes no `set:` -- nothing was stored, so there is nothing to write back",
        else: nil
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp represented_errors(state) do
    when_error =
      if is_nil(state.when) do
        nil
      else
        "state #{inspect(state.value)} declares a `representation:` and takes no `when:` -- there is no legacy encoding to guard on"
      end

    set_error =
      if state.set in [nil, []] do
        nil
      else
        "state #{inspect(state.value)} declares a `representation:` and takes no `set:` -- there is no legacy column to write"
      end

    Enum.reject([when_error, set_error], &is_nil/1)
  end

  defp lossy_errors(_entry, state, states_by_value) do
    {:lossy, to, _loss} = state.representation

    case Map.fetch(states_by_value, to) do
      :error ->
        [
          "state #{inspect(state.value)} collapses to `to: #{inspect(to)}`, which names no state of this table"
        ]

      {:ok, %{set: to_set}} when to_set in [nil, []] ->
        [
          "state #{inspect(state.value)} collapses to `to: #{inspect(to)}`, which has no `set:` -- the loss applies that state's write values"
        ]

      {:ok, _found} ->
        []
    end
  end
end
