# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifyOwnShape do
  @moduledoc """
  A facade owns nothing: no security vocabulary and no storage actions.

  It declares no field policy — the source's field policies decide what a
  caller sees, and a second copy of that decision would drift from it. No
  `secured_fields` and no `extra_grants` either (they exist only on hosts
  whose base resource carries them, which is why they are read defensively).
  And no create, update or destroy action of its own: there is nowhere to
  write, and every write goes through one named source action. Every read
  action it declares is the facade manual read — anything else would answer
  reads from the `Ash.DataLayer.Simple` storage the facade does not have.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  # Read defensively: the section exists only on hosts whose base resource
  # has it, so its absence must read as "none declared", not as an error.
  @platform_keys [:secured_fields, :extra_grants]

  @impl true
  def verify(dsl) do
    facade = Verifier.get_persisted(dsl, :module)

    problems =
      Enum.concat([
        field_policies(dsl),
        platform_security(dsl),
        write_actions(dsl),
        reads(dsl)
      ])

    case problems do
      [] ->
        :ok

      problems ->
        {:error,
         Spark.Error.DslError.exception(
           module: facade,
           path: [:facade],
           message:
             "A facade declares no security vocabulary and no storage of its own.\n\n" <>
               Enum.map_join(problems, "\n", &"  * #{&1}")
         )}
    end
  end

  defp field_policies(dsl) do
    policies = Spark.Dsl.Extension.get_entities(dsl, [:policies])
    field_policies = Spark.Dsl.Extension.get_entities(dsl, [:field_policies])

    Enum.concat([
      for _policy <- policies do
        "a `policy` is declared. A facade has no rules of its own: the source's policies " <>
          "decide. Remove the `policies` block."
      end,
      for _policy <- field_policies do
        "a `field_policy` is declared. Field policies are the source's decision, read " <>
          "through it. Remove the `field_policies` block."
      end
    ])
  end

  defp platform_security(dsl) do
    for key <- @platform_keys,
        granted = Spark.Dsl.Extension.get_opt(dsl, [:platform], key, []),
        granted != [] do
      "`#{key} #{inspect(granted)}` is declared. A facade grants nothing: the source's own " <>
        "secured fields and grants decide."
    end
  end

  defp write_actions(dsl) do
    for action <- Spark.Dsl.Transformer.get_entities(dsl, [:actions]),
        action.type in [:create, :update, :destroy] do
      "a #{action.type} action `#{action.name}` is declared. A facade has nowhere to write: " <>
        "declare a `write` in the `facade` block, which runs one source action."
    end
  end

  defp reads(dsl) do
    for action <- Spark.Dsl.Transformer.get_entities(dsl, [:actions]),
        action.type == :read,
        facade_manual?(action.manual) == false do
      "the read action `#{action.name}` is not the facade manual read. A facade has no " <>
        "storage to read: use `manual AshStrangler.Facade.Read` (or declare no read and let " <>
        "the facade add one)."
    end
  end

  # The DSL normalises `manual AshStrangler.Facade.Read` to `{module, opts}`;
  # the transformer builds the tuple directly.
  defp facade_manual?({AshStrangler.Facade.Read, _opts}), do: true
  defp facade_manual?(_manual), do: false
end
