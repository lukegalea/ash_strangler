defmodule AshStrangler.Verifiers.VerifyCompleteMapping do
  @moduledoc """
  Every attribute must be mapped, constant, unmapped, or the key.

  ## Why this is an error rather than a default

  The convenient behaviour is to select `NULL` for anything the mapping does not
  mention. That is also how a strangler migration loses data silently: someone
  adds an attribute to the resource, the view keeps compiling, and the column
  reads NULL in production for every legacy row.

  Requiring `unmapped ... because:` makes the omission a decision somebody wrote
  down, and the reason lands in the generated documentation.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if AshStrangler.Info.strangled?(dsl) do
      accounted = AshStrangler.Info.accounted_for(dsl)

      missing =
        dsl
        |> Verifier.get_entities([:attributes])
        |> Enum.reject(&Map.get(&1, :private?, false))
        |> Enum.map(& &1.name)
        |> Enum.reject(&MapSet.member?(accounted, &1))

      case missing do
        [] -> :ok
        missing -> {:error, error(dsl, missing)}
      end
    else
      :ok
    end
  end

  defp error(dsl, missing) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source],
      message: """
      These attributes are neither mapped nor declared unmapped:

        #{Enum.map_join(missing, "\n  ", &inspect/1)}

      An unmentioned attribute would read NULL for every legacy row, which is a
      silent data loss rather than a failure. Either map it:

          map #{inspect(List.first(missing))}, "legacy_column"

      or declare the omission and say why:

          unmapped #{inspect(missing)}, as: :null,
            because: "..."
      """
    )
  end
end
