# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Verifiers.VerifySensitive do
  @moduledoc """
  `sensitive?` is inherited, never set.

  A facade attribute's `sensitive?` is whatever its lens reads: if any source
  attribute, calculation or aggregate the lens reads is sensitive, the facade
  attribute is sensitive; if none is, it is not. A difference in either
  direction is refused — declaring sensitivity the source does not claim
  hides data the caller is allowed to filter on, and missing it publishes a
  secret the source had already decided to protect.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Facade.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    facade = Verifier.get_persisted(dsl, :module)
    source = Info.source(dsl)

    lenses = safe_lenses(dsl)

    if lenses == :unbuilt do
      # VerifySource refuses the lens first; nothing to add here.
      :ok
    else
      dsl
      |> Ash.Resource.Info.attributes()
      |> Enum.flat_map(&problems(&1, Map.get(lenses, &1.name), source))
      |> case do
        [] ->
          :ok

        problems ->
          {:error,
           Spark.Error.DslError.exception(
             module: facade,
             path: [:facade],
             message:
               "A facade attribute's `sensitive?` is inherited from its source.\n\n" <>
                 Enum.map_join(problems, "\n", &"  * #{&1}")
           )}
      end
    end
  end

  defp safe_lenses(dsl) do
    Info.lenses(dsl)
  rescue
    ArgumentError -> :unbuilt
  end

  defp problems(facade_attribute, nil, _source) do
    if facade_attribute.sensitive? do
      [
        "#{inspect(facade_attribute.name)} is `sensitive?` but no lens produces it: a " <>
          "sensitive attribute needs a lens that reads its source."
      ]
    else
      []
    end
  end

  defp problems(facade_attribute, lens, source) do
    expected = any_source_sensitive?(lens, source)

    cond do
      facade_attribute.sensitive? && !expected ->
        [
          "#{inspect(facade_attribute.name)} is `sensitive?` but nothing its lens reads " <>
            "#{inspect(sources_of(lens))} is sensitive on #{inspect(source)}. Drop the flag."
        ]

      !facade_attribute.sensitive? && expected ->
        [
          "#{inspect(facade_attribute.name)} reads a sensitive field of #{inspect(source)} " <>
            "through #{inspect(sources_of(lens))}, so it must be `sensitive? true`."
        ]

      true ->
        []
    end
  end

  defp any_source_sensitive?(lens, source) do
    lens.sources
    |> Enum.filter(&match?({[], _}, &1))
    |> Enum.any?(fn {_path, name} ->
      case Ash.Resource.Info.field(source, name) do
        nil -> false
        field -> Map.get(field, :sensitive?, false)
      end
    end)
  end

  defp sources_of(lens) do
    lens.sources
    |> Enum.filter(&match?({[], _}, &1))
    |> Enum.map(&elem(&1, 1))
  end
end
