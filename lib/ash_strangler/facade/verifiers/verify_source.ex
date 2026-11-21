# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifySource do
  @moduledoc """
  The source is real, readable, and has what the entries read.

  A facade is nothing without its source: the module must be an Ash resource
  carrying the named read action, and every entry must produce a facade
  attribute that exists and read something the source has. The last check is
  `AshStrangler.Lens.over/3` itself — which raises `ArgumentError` for a
  `from:` the source does not have — turned into a `Spark.Error.DslError`, so
  a typo stops this resource's compile with the offending attribute named.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Facade.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    source = Info.source(dsl)
    read_action = Info.read_action(dsl)

    cond do
      not compiled?(source) ->
        {:error,
         error(dsl, """
         The source #{inspect(source)} is not compiled.

         A facade builds its lenses against the source's fields, so the source
         compiles first: declare both in a domain, with the source listed, and
         the facade will see it. If it is not an Ash resource at all, that is
         the actual mistake.
         """)}

      not Ash.Resource.Info.resource?(source) ->
        {:error,
         error(
           dsl,
           "#{inspect(source)} is not an Ash resource, so it cannot be a facade's source."
         )}

      is_nil(Ash.Resource.Info.action(source, read_action)) ->
        {:error,
         error(
           dsl,
           "#{inspect(source)} has no read action #{inspect(read_action)} for this facade to call."
         )}

      Ash.Resource.Info.action(source, read_action).type != :read ->
        {:error,
         error(
           dsl,
           "#{inspect(read_action)} on #{inspect(source)} is not a read action; a facade reads " <>
             "through one."
         )}

      true ->
        lenses(dsl)
    end
  end

  # `Lens.over/3` raises for a `from:` the source does not have; a decompiled
  # here into a `Spark.Error.DslError`, so the failure names the attribute and
  # reads like every other DSL refusal. The entries' own attributes are
  # checked here too: a lens for an attribute the facade does not declare
  # would produce values nothing reads.
  defp lenses(dsl) do
    facade = Verifier.get_persisted(dsl, :module)

    for entry <- Info.entries(dsl), attribute <- entry_attributes(entry) do
      unless Ash.Resource.Info.attribute(facade, attribute) do
        raise ArgumentError,
              "#{inspect(attribute)} is declared in the facade but is not an attribute of " <>
                "#{inspect(facade)}"
      end
    end

    Info.lenses(dsl)
    :ok
  rescue
    error in ArgumentError ->
      {:error, error(dsl, Exception.message(error))}
  end

  defp entry_attributes(%{attribute: attribute}) when is_atom(attribute), do: [attribute]

  # An `unmapped [:a, :b]` produces one lens per attribute.
  defp entry_attributes(%{attributes: attributes}) when is_list(attributes), do: attributes
  defp entry_attributes(_entry), do: []

  defp compiled?(source) when is_atom(source) do
    Code.ensure_compiled(source) == {:module, source}
  end

  defp error(dsl, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:facade],
      message: message
    )
  end
end
