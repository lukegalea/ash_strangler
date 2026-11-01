# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifySecrets do
  @moduledoc """
  A column a twin declares secret is not an attribute of the twin.

  That is the whole mechanism of secret omission. Every place this package
  reads legacy data from (the compatibility view, the triggers, the ledger's
  row image, the notify payload, the backfill) reads it through the twin's
  attributes, so a column that is not an attribute cannot leave the legacy
  database through any of them. Declaring it secret *and* keeping the
  attribute would make the declaration a comment, so it is refused.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    secrets = AshStrangler.Twin.secrets(dsl)

    carried =
      for attribute <- Ash.Resource.Info.attributes(dsl),
          column = to_string(attribute.source || attribute.name),
          column in secrets,
          do: column

    if carried == [] do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: Verifier.get_persisted(dsl, :module),
         path: [:twin, :secrets],
         message: """
         #{Enum.map_join(carried, ", ", &"`#{&1}`")} is declared secret and is also an attribute of this twin.

         A secret column is omitted from the twin, and that omission is what keeps
         it out of every view, ledger image and notification. Delete the attribute,
         or regenerate the twin, which leaves secrets out:

             mix ash_strangler.gen.twin #{inspect(Verifier.get_persisted(dsl, :module))}
         """
       )}
    end
  end
end
