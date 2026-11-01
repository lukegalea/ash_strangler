# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyEstate do
  @moduledoc """
  An estate's declarations agree with its catalog.

  Fails compilation of an `AshStrangler.Estate` module when:

    * its `snapshot` catalog cannot be read;
    * a declaration names a relation or column the catalog does not have;
    * `carried` names a relation rather than a column;
    * one relation or column is declared more than once;
    * a column is declared inside a relation declared as a whole;
    * a `residue` relation is in the catalog, or is declared twice;
    * an `open_reference` names a foreign key the catalog does not have.

  These need only the estate and the catalog, so they run here, at compile
  time. Coverage, consistency, writers, references and plug-ins read other
  modules' compiled mappings, so they run in the `:ash_strangler_estate`
  compiler after everything is compiled (see `AshStrangler.Estate`).
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Estate.Report
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    path = AshStrangler.Estate.snapshot(dsl)

    case AshStrangler.Snapshot.read_catalog(path) do
      {:error, message} ->
        {:error, error(dsl, "the estate's snapshot catalog cannot be read: #{message}")}

      {:ok, catalog} ->
        case Report.declaration_problems(dsl, catalog) do
          [] ->
            :ok

          problems ->
            {:error,
             error(dsl, """
             The estate's declarations disagree with the catalog #{path}:

             #{Enum.map_join(problems, "\n", &"  * #{&1.message}")}
             """)}
        end
    end
  end

  defp error(dsl, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:estate],
      message: message
    )
  end
end
