# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyWatch do
  @moduledoc """
  A watched twin has a primary key.

  The watch payload is the key and nothing else (see `AshStrangler.Sql.Watch`),
  so a relation without one would announce that *something* changed and give a
  consumer no way to say what.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if AshStrangler.Twin.watch(dsl) && Ash.Resource.Info.primary_key(dsl) == [] do
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:twin, :watch],
         message: """
         `watch` needs a primary key on the twin: the notification carries the key
         of the changed row and nothing else.
         """
       )}
    else
      :ok
    end
  end
end
