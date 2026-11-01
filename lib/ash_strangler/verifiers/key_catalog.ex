# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.KeyCatalog do
  @moduledoc false
  # What `VerifyKey` and `VerifyReferences` read from a twin's snapshot
  # catalog: column facts, unique sets and foreign keys of one relation.

  alias AshStrangler.{KeyKind, KeyKinds, Twin}

  @doc "The catalog relation name of a twin: `schema.table`, `public` by default."
  def relation_name(twin) do
    "#{AshPostgres.DataLayer.Info.schema(twin) || "public"}.#{AshPostgres.DataLayer.Info.table(twin)}"
  end

  @doc "`{:ok, catalog, relation}` for a pinned twin, `:unpinned`, or `{:error, message}`."
  def relation(twin) do
    case Twin.snapshot(twin) do
      nil ->
        :unpinned

      path ->
        name = relation_name(twin)

        with {:ok, catalog} <- AshStrangler.Snapshot.read_catalog(path) do
          case catalog["relations"][name] do
            nil -> {:error, "the snapshot catalog #{path} has no relation `#{name}`"}
            relation -> {:ok, catalog, relation}
          end
        end
    end
  end

  @doc "The catalog column named `name`, or `nil`."
  def column(relation, name), do: Enum.find(relation["columns"], &(&1["name"] == name))

  @doc "The integer width of a catalog column, or `nil` when it is not an integer."
  def width(column),
    do: Map.get(AshStrangler.Verifiers.VerifyKeyKinds.integer_widths(), column["udt"])

  @doc "The twin column names behind `attributes`, or `{:error, attribute}` for one the twin lacks."
  def columns(twin, attributes) do
    Enum.reduce_while(attributes, {:ok, []}, fn attribute, {:ok, acc} ->
      case Ash.Resource.Info.attribute(twin, attribute) do
        nil -> {:halt, {:error, attribute}}
        attr -> {:cont, {:ok, acc ++ [to_string(attr.source || attr.name)]}}
      end
    end)
  end

  @doc "True when some non-partial unique set (or the primary key) lies within `columns`."
  def unique?(relation, columns) do
    within = MapSet.new(columns)

    sets =
      [relation["primary_key"] | Enum.filter(relation["unique"], &is_nil(&1["predicate"]))]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&MapSet.new(&1["columns"]))

    Enum.any?(sets, &MapSet.subset?(&1, within))
  end

  @doc """
  `{:ok, kind}` when `registry` is a compiled key-kind registry declaring
  `name`, else `{:error, message}`.
  """
  def kind(registry, name) do
    cond do
      not KeyKinds.registry?(registry) ->
        {:error, "#{inspect(registry)} is not a key-kind registry (`use AshStrangler.KeyKinds`)"}

      kind = KeyKinds.kind(registry, name) ->
        {:ok, kind}

      true ->
        {:error,
         "#{inspect(registry)} declares no key kind #{inspect(name)}; it declares " <>
           inspect(Enum.map(KeyKinds.kinds(registry), & &1.name))}
    end
  end

  @doc """
  Problems with `columns` of `relation` as the parts of `kind`: each must be
  an integer no wider than its part, and NOT NULL when `not_null?`.
  """
  def width_problems(relation, columns, %KeyKind{} = kind, not_null?) do
    columns
    |> Enum.zip(KeyKind.widths(kind))
    |> Enum.flat_map(fn {name, part_width} ->
      column = column(relation, name)
      width = column && width(column)

      cond do
        is_nil(column) ->
          ["`#{name}` is not a column of the snapshot relation"]

        is_nil(width) ->
          ["`#{name}` is #{column["type"]}; a packed part must be smallint, integer or bigint"]

        width > part_width ->
          [
            "`#{name}` is #{column["type"]} (#{width} bits); kind #{inspect(kind.name)} packs " <>
              "that part in #{part_width}"
          ]

        not_null? and not column["not_null"] ->
          ["`#{name}` is nullable; a key part must be NOT NULL"]

        true ->
          []
      end
    end)
  end
end
