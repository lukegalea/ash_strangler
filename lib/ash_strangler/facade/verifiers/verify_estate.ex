# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifyEstate do
  @moduledoc """
  Every attribute of the source is placed: exposed, hidden, or deferred.

  The estate check (`AshStrangler.Facade.Info.estate/1`) is the facade's
  version of the strangler's "every attribute must be accounted for": a source
  attribute the facade neither reads nor names is one that silently goes
  unanswered, and a silent gap is a decision nobody made. `hide` and `defer`
  naming an attribute the source does not have are refused — a typo in a
  deferral is a hole, not a note — and a `hide` of an attribute some lens
  reads is refused, because the declaration and the lens cannot both be true.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Facade.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    facade = Verifier.get_persisted(dsl, :module)
    source = Info.source(dsl)

    # VerifySource refuses an uncompiled source first; nothing to add here.
    if compiled?(source) do
      case problems(dsl, source) do
        [] ->
          :ok

        problems ->
          {:error,
           Spark.Error.DslError.exception(
             module: facade,
             path: [:facade],
             message:
               "The source's attributes are not all placed.\n\n" <>
                 Enum.map_join(problems, "\n", &"  * #{&1}")
           )}
      end
    else
      :ok
    end
  end

  defp problems(dsl, source) do
    source_attributes = source |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
    estate = Info.estate(dsl)
    lenses = safe_lenses(dsl)

    Enum.concat([
      for attribute <- estate.unplaced do
        "#{inspect(attribute)} of #{inspect(source)} is neither exposed, hidden nor " <>
          "deferred. A source attribute the facade does not place goes unanswered: hide it " <>
          "with a `because:`, defer it, or map it."
      end,
      for %{attribute: attribute} <- Info.hidden(dsl) ++ Info.deferred(dsl),
          attribute not in source_attributes do
        "#{inspect(attribute)} is not an attribute of #{inspect(source)}: the `hide`/`defer` " <>
          "names nothing."
      end,
      for attribute <- Enum.map(Info.hidden(dsl), & &1.attribute),
          MapSet.member?(read(estate, lenses), attribute) do
        "#{inspect(attribute)} is hidden but some lens reads it. The declaration and the " <>
          "lens cannot both be true."
      end
    ])
  end

  defp read(estate, lenses) do
    MapSet.union(
      MapSet.new(estate.exposed),
      lenses |> Map.values() |> Info.source_attributes()
    )
  end

  defp safe_lenses(dsl) do
    Info.lenses(dsl)
  rescue
    ArgumentError -> %{}
  end

  defp compiled?(source) when is_atom(source),
    do: Code.ensure_compiled(source) == {:module, source}
end
