# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Derived.Info do
  @moduledoc "Introspection of an `AshStrangler.Derived`. Works on a compiled module or a `Spark.Dsl` state."

  alias AshStrangler.Derived.Source
  alias AshStrangler.Union.Column

  defp opt(derived, name, default \\ nil),
    do: Spark.Dsl.Extension.get_opt(derived, [:derived], name, default)

  @spec schema(module() | Spark.Dsl.t()) :: String.t()
  def schema(derived), do: opt(derived, :schema, "public")

  @spec view(module() | Spark.Dsl.t()) :: String.t() | nil
  def view(derived), do: opt(derived, :view)

  @doc "The schema-qualified, quoted name of the view."
  @spec view_name(module() | Spark.Dsl.t()) :: String.t()
  def view_name(derived), do: ~s("#{schema(derived)}"."#{view(derived)}")

  @spec twin(module() | Spark.Dsl.t()) :: module() | nil
  def twin(derived), do: opt(derived, :twin)

  @spec key(module() | Spark.Dsl.t()) :: atom()
  def key(derived), do: opt(derived, :key, :id)

  @spec registry(module() | Spark.Dsl.t()) :: module() | nil
  def registry(derived), do: opt(derived, :registry)

  @spec kind(module() | Spark.Dsl.t()) :: atom() | nil
  def kind(derived), do: opt(derived, :kind)

  @doc "The twin columns that identify the legacy row."
  @spec from(module() | Spark.Dsl.t()) :: [atom()]
  def from(derived), do: opt(derived, :from, [])

  @doc "The filter every source shares, or `nil`."
  @spec filter(module() | Spark.Dsl.t()) :: term()
  def filter(derived), do: opt(derived, :filter)

  @doc "The tenant column (estate check E5), or `nil`."
  @spec tenant(module() | Spark.Dsl.t()) :: atom() | nil
  def tenant(derived), do: opt(derived, :tenant)

  @spec columns(module() | Spark.Dsl.t()) :: [Column.t()]
  def columns(derived), do: entities(derived, Column)

  @doc "Every source (`slot`, `synthesized`, `element`), in declaration order."
  @spec sources(module() | Spark.Dsl.t()) :: [Source.t()]
  def sources(derived), do: entities(derived, Source)

  @spec source(module() | Spark.Dsl.t(), atom()) :: Source.t() | nil
  def source(derived, name), do: Enum.find(sources(derived), &(&1.name == name))

  @doc "Only the `element` sources."
  @spec elements(module() | Spark.Dsl.t()) :: [Source.t()]
  def elements(derived), do: Enum.filter(sources(derived), &(&1.kind == :element))

  defp entities(derived, struct) do
    derived |> Spark.Dsl.Extension.get_entities([:derived]) |> Enum.filter(&is_struct(&1, struct))
  end
end
