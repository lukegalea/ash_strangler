# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifyAuthorization do
  @moduledoc """
  A facade's domain may not authorize less than its source's.

  A facade reads and writes its source with the authorization its own domain
  resolved: the caller's `authorize?` and `actor` travel, but when the caller
  supplies neither, the facade's domain's `authorize` setting is what reaches
  the source — there is no way through the facade to be held to the source's
  own setting instead. A facade in a domain that resolves
  `authorize :when_requested` over a source whose domain resolves
  `:by_default` would therefore read and write the source unchecked, where a
  caller calling the source directly would have been authorized, and a
  field-policy protected value would come back in clear. That difference is
  refused at compile time; the fix belongs in the facade's domain.

  A facade over a facade compares with the source facade's domain, one hop
  up.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Facade.Info
  alias Spark.Dsl.Verifier

  # Lax to strict: a facade may be stricter than its source, never laxer.
  @strictness [:when_requested, :by_default, :always]

  @impl true
  def verify(dsl) do
    facade = Verifier.get_persisted(dsl, :module)
    facade_domain = Ash.Resource.Info.domain(dsl)
    source = Info.source(dsl)
    source_domain = source && Ash.Resource.Info.domain(source)

    if facade_domain && source_domain do
      facade_authorize = Ash.Domain.Info.authorize(facade_domain)
      source_authorize = Ash.Domain.Info.authorize(source_domain)

      if strictness(facade_authorize) < strictness(source_authorize) do
        {:error,
         Spark.Error.DslError.exception(
           module: facade,
           path: [:facade],
           message:
             "This facade's domain authorizes less than its source's.\n\n" <>
               "A facade reads and writes its source with the authorization its own domain " <>
               "resolved: when a caller supplies neither `actor` nor `authorize?`, it is " <>
               "#{inspect(facade_domain)}'s `authorize #{inspect(facade_authorize)}` that " <>
               "reaches the source, not #{inspect(source_domain)}'s " <>
               "`authorize #{inspect(source_authorize)}`. Through this facade, a call that " <>
               "asks for no authorization would read and write #{inspect(source)} unchecked, " <>
               "where calling the source directly would have been authorized.\n\n" <>
               "Authorize #{inspect(facade_domain)} at least as strictly as " <>
               "#{inspect(source_domain)} is authorized."
         )}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp strictness(setting) when setting in @strictness,
    do: Enum.find_index(@strictness, &(&1 == setting))
end
