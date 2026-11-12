# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyArchiveRelated do
  @moduledoc """
  At `:read_from_new`, every `archive_related` relationship a legacy `DELETE`
  must cascade is one a trigger can follow faithfully.

  A legacy `DELETE` through the reverse view archives the owned row and, in the
  same statement, the related rows `AshArchival`'s `archive_related` would
  archive (`AshStrangler.Sql.ReverseTriggers`). The trigger compares foreign
  keys and stamps archive columns, so a relationship whose rows only Ash can
  find, or a destination whose archive is not a column stamp in the same
  database, would be cascaded wrongly or not at all. This verifier refuses
  them, at every level of the cascade, naming the resource that declares the
  relationship, the relationship, and the reason. The rules live in
  `AshStrangler.Sql.ArchiveCascade`, which the trigger is built from too.

  Only a resource strangled at `:read_from_new` that archives is checked: in
  every other phase a legacy `DELETE` never reaches the owned table, and a
  resource that does not archive deletes its row and cascades nothing. There
  is no opt-out: remove the relationship from `archive_related`, or change it.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Info
  alias AshStrangler.Sql.{ArchiveCascade, ReverseTriggers}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    resource = Verifier.get_persisted(dsl, :module)

    if applies?(resource) do
      case ArchiveCascade.plan(resource) do
        {:ok, _steps} ->
          :ok

        {:error, refusal} ->
          {:error,
           Spark.Error.DslError.exception(
             module: resource,
             path: [:archive, :archive_related],
             message: ArchiveCascade.message(refusal)
           )}
      end
    else
      :ok
    end
  end

  defp applies?(resource) do
    resource != nil and Info.strangled?(resource) and
      Info.strangler_phase!(resource) == :read_from_new and
      ReverseTriggers.archive_column(resource) != :error
  end
end
