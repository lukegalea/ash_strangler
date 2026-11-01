# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Transformers.AddTwinPolicy do
  @moduledoc """
  Gives a twin declaring `twin do system_actor Check end` its one policy:

      policies do
        policy always() do
          authorize_if Check
        end
      end

  Refused, rather than silently ineffective, when the twin has no
  `Ash.Policy.Authorizer` (the policy would never run) or declares a `bypass`
  (which could authorize an actor the system-actor policy does not).
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    case AshStrangler.Twin.system_actor(dsl) do
      nil -> {:ok, dsl}
      check -> add_policy(dsl, check)
    end
  end

  defp add_policy(dsl, check) do
    cond do
      Ash.Policy.Authorizer not in Transformer.get_persisted(dsl, :authorizers, []) ->
        {:error,
         error(
           dsl,
           "`system_actor` needs `authorizers: [Ash.Policy.Authorizer]` on the twin, " <>
             "or its policy never runs"
         )}

      Enum.any?(Transformer.get_entities(dsl, [:policies]), &match?(%{bypass?: true}, &1)) ->
        {:error,
         error(
           dsl,
           "a twin with `system_actor` cannot declare a `bypass`: a bypass can authorize an " <>
             "actor that is not the system actor"
         )}

      true ->
        {check_module, check_opts} = if is_tuple(check), do: check, else: {check, []}

        authorize =
          Transformer.build_entity!(Ash.Policy.Authorizer, [:policies, :policy], :authorize_if,
            check: {check_module, check_opts}
          )

        policy =
          Transformer.build_entity!(Ash.Policy.Authorizer, [:policies], :policy,
            condition: [{Ash.Policy.Check.Static, result: true}],
            description: "legacy rows are read by the system actor only",
            policies: [authorize]
          )

        {:ok, Transformer.add_entity(dsl, [:policies], policy)}
    end
  end

  defp error(dsl, message) do
    Spark.Error.DslError.exception(
      module: Transformer.get_persisted(dsl, :module),
      path: [:twin, :system_actor],
      message: message
    )
  end
end
