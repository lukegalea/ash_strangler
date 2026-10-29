# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Transformers.ResolveMappingTarget do
  @moduledoc """
  Persists the target of an attached `AshStrangler.Mapping` fragment onto the
  merged `AshStrangler.Source` entity.

  Spark merges fragment entities before transformers run, but deliberately does
  not persist the parent's fragment-module list. The fragment's DSL entity
  metadata DOES survive the merge at this point (file + location); its own
  `spark_dsl_config/0` carries the same site. Match those two facts against the
  loaded `target/0` modules and persist the result on Source. The mix check then
  compares it to the attaching resource without source scanning or a heuristic.

  Inline sources have no matching fragment site and remain untouched. An
  external source whose site cannot be uniquely resolved is marked
  `mapping_target_unverifiable?` so `mix ash_strangler.check` reports it rather
  than silently skipping the contract.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  @impl true
  def transform(dsl) do
    resource_file =
      dsl
      |> Transformer.get_persisted(:file)
      |> normalize_file()

    dsl
    |> Transformer.get_entities([:strangler])
    |> Enum.filter(&is_struct(&1, AshStrangler.Source))
    |> Enum.reduce(dsl, fn source, dsl ->
      case resolve(source, resource_file) do
        {:ok, mapping_module, target} ->
          replace(dsl, source, %{
            source
            | mapping_module: mapping_module,
              mapping_target: target,
              mapping_target_unverifiable?: false
          })

        :inline ->
          dsl

        :unverifiable ->
          replace(dsl, source, %{source | mapping_target_unverifiable?: true})
      end
    end)
    |> then(&{:ok, &1})
  end

  defp resolve(source, resource_file) do
    case site(source) do
      # Inline entities can have no annotation when Spark's location tracking
      # is disabled. A fragment compiled through Spark.Dsl.Fragment carries a
      # site (and target/0); absent that marker, the declaration is inline.
      nil ->
        :inline

      {file, _location} = site ->
        candidates = mapping_modules(file)

        case Enum.filter(candidates, &(fragment_source_site(&1) == site)) do
          [mapping] -> {:ok, mapping, mapping.target()}
          [] when file == resource_file -> :inline
          _ -> :unverifiable
        end
    end
  end

  defp replace(dsl, source, replacement) do
    source_meta = source.__spark_metadata__

    Transformer.replace_entity(
      dsl,
      [:strangler],
      replacement,
      &(&1.__spark_metadata__ == source_meta)
    )
  end

  defp site(%{__spark_metadata__: %{anno: anno}}) when is_list(anno) do
    with file when not is_nil(file) <- Keyword.get(anno, :file),
         location when not is_nil(location) <- Keyword.get(anno, :location) do
      {file |> IO.iodata_to_binary() |> Path.basename(), location}
    end
  end

  defp site(%{__spark_metadata__: %{anno: anno}}) when is_map(anno) do
    with file when not is_nil(file) <- Map.get(anno, :file),
         location when not is_nil(location) <- Map.get(anno, :location) do
      {file |> IO.iodata_to_binary() |> Path.basename(), location}
    end
  end

  defp site(_), do: nil

  defp fragment_source_site(module) do
    module.spark_dsl_config()
    |> Spark.Dsl.Extension.get_entities([:strangler])
    |> Enum.find(&is_struct(&1, AshStrangler.Source))
    |> site()
  rescue
    _ -> nil
  end

  defp mapping_modules(file) do
    for {module, _} <- :code.all_loaded(),
        function_exported?(module, :target, 0),
        fragment_of_resource?(module),
        source_file(module) == file do
      module
    end
  end

  defp fragment_of_resource?(module) do
    module.__info__(:attributes)
    |> Keyword.get(:spark_fragment_of, [])
    |> Enum.any?(&(&1 == Ash.Resource))
  rescue
    _ -> false
  end

  defp normalize_file(nil), do: nil

  defp normalize_file(file),
    do: file |> IO.iodata_to_binary() |> Path.basename()

  defp source_file(module) do
    case module.module_info(:compile)[:source] do
      nil -> nil
      source -> IO.iodata_to_binary(source) |> Path.basename()
    end
  end
end
