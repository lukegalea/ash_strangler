# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyStateMachineBacked do
  @moduledoc """
  When a resource is an `AshStateMachine` and its state attribute is
  strangler-mapped, the machine and the collapse must be the SAME answer to
  "what state is this?" — and the machine's vocabulary must fit the collapse's.

    * the state attribute's mapping must be a `collapse`. Any other mapping is
      two answers to one question.
    * every machine state must have a collapse clause. A machine state with no
      clause is a state the view reads as NULL — the machine would believe a
      transition stuck, and nothing would report why.
    * no transition may target a `derived:` or `{:refuse, _}` state. A derived
      target could never stick (the state is a function of the data, not a
      stored value — the trigger refuses the write); a refused target aborts
      the transaction by declaration. The machine layer's guard and the
      trigger's guard would disagree about which one is the reason.
    * `initial_states` must not include a refused state: every create would
      fail, in the trigger, after the machine had already said yes.

  Machine guards see the forward value by construction — the view computes it
  — and the transition's write goes through the update action into the
  INSTEAD OF trigger, which writes the declared backward `set:`. The
  lifecycle tests prove both directions against the real database.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Collapse
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    if Code.ensure_loaded?(AshStateMachine) and module != nil and
         machine?(module) and strangler_mapped_state?(dsl, module) do
      verify_machine(dsl)
    else
      :ok
    end
  end

  defp machine?(module) do
    AshStateMachine in Spark.extensions(module)
  rescue
    _ -> false
  end

  defp strangler_mapped_state?(dsl, module) do
    # The generated accessor is typed {:ok, term()} — {:ok, nil} when the
    # resource declares no state attribute — so nil is the unset case, not a
    # shape to raise on.
    case AshStateMachine.Info.state_machine_state_attribute(module) do
      {:ok, attribute} when is_atom(attribute) -> mapped_attribute(dsl, attribute) != nil
      _ -> false
    end
  end

  defp verify_machine(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    attribute = AshStateMachine.Info.state_machine_state_attribute!(module)
    mapping = mapped_attribute(dsl, attribute)

    with {:collapse, %Collapse{} = collapse} <- {:collapse, mapping},
         :ok <- verify_covered(dsl, collapse),
         :ok <- verify_transitions(dsl, collapse),
         :ok <- verify_initial(dsl, collapse) do
      :ok
    else
      {:collapse, other} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:strangler, :source],
           message: """
           the state attribute is mapped as #{inspect(other.__struct__)}; a \
           lifecycle over shared rows must be a collapse (two answers to \
           "what state is this?" is a bug).

           The machine reasons over the attribute the view projects; the
           collapse is what projects it. A `map`/`decode`/`constant` beside
           the machine would be a second source of truth for the same
           question, and whichever one a reader hit first would win.

               collapse #{inspect(attribute)} do ... end
           """
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp verify_covered(dsl, collapse) do
    declared = MapSet.new(collapse.states, & &1.value)

    dsl
    |> AshStateMachine.Info.state_machine_all_states()
    |> Enum.reject(&MapSet.member?(declared, &1))
    |> case do
      [] ->
        :ok

      missing ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:strangler, :source, :collapse],
           message: """
           the machine declares states with no collapse clause: \
           #{Enum.map_join(missing, ", ", &inspect/1)}.

           A machine state with no clause reads as NULL through the view --
           the machine would believe a transition stuck, and nothing would
           say why. Add a clause per state, even if the answer is a declared
           `representation:`.
           """
         )}
    end
  end

  defp verify_transitions(dsl, collapse) do
    by_value = Map.new(collapse.states, &{&1.value, &1})
    module = Verifier.get_persisted(dsl, :module)

    dsl
    |> AshStateMachine.Info.state_machine_transitions()
    |> Enum.flat_map(fn transition ->
      # `to:` is an atom or a list of atoms, and FillInTransitionDefaults
      # normalises to a list — the map is keyed by single states.
      transition.to |> List.wrap() |> Enum.map(&{transition, &1})
    end)
    |> Enum.find_value(fn {transition, target} ->
      state = by_value[target]

      refuses? =
        match?(%{representation: {:refuse, _}}, state) or
          match?(%{derived: true, representation: nil}, state)

      if refuses? do
        reason =
          case state do
            %{representation: {:refuse, _}} ->
              "a refused target aborts the transaction by declaration"

            _derived ->
              "a derived target could never stick: the state is a function of the data, not a stored value"
          end

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:strangler, :source, :collapse],
           message: """
           the transition #{inspect(transition.action)} \
           #{inspect(transition.from)} -> #{inspect(target)} targets a \
           state no write can store: #{reason}.

           The machine's guard would say yes and the trigger would say no,
           and the two answers would disagree about which one is the reason.
           Retarget the transition, or change the state's declaration.
           """
         )}
      end
    end)
    |> case do
      nil -> :ok
      {:error, _} = error -> error
    end
  end

  defp verify_initial(dsl, collapse) do
    by_value = Map.new(collapse.states, &{&1.value, &1})
    module = Verifier.get_persisted(dsl, :module)

    AshStateMachine.Info.state_machine_initial_states!(dsl)
    |> Enum.find(fn initial ->
      match?(%{representation: {:refuse, _}}, by_value[initial])
    end)
    |> case do
      nil ->
        :ok

      refused ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:strangler, :source, :collapse],
           message: """
           #{inspect(refused)} is an initial state and a refused one: every \
           create would fail in the trigger, after the machine had already \
           said yes.

           Initial states are the one set of states the HOST writes without a
           transition, so a refused initial state is a create that can never
           succeed. Start the machine somewhere representable.
           """
         )}
    end
  end

  defp mapped_attribute(dsl, attribute) do
    source = AshStrangler.Info.source(dsl)

    with %{keys: keys, mappings: mappings} <- source do
      Enum.find(mappings ++ keys, fn entry ->
        Map.has_key?(entry, :attribute) and entry.attribute == attribute
      end)
    end
  end
end
