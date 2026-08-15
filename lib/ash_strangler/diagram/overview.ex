# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

with {:module, AshDiagram.Flowchart} <- Code.ensure_compiled(AshDiagram.Flowchart) do
  defmodule AshStrangler.Diagram.Overview do
    @moduledoc """
    Draws which legacy relations feed which resources, one edge per pair.

    This is `AshStrangler.Diagram.Mapping` with the columns taken out. It is the
    diagram to reach for when the question is *shape* — how many resources came
    out of one table, which tables a resource gathers from, which way writes
    flow, and how far along each resource is — rather than what happens to any
    particular column.

    It is also the one that stays readable. A column-level diagram of a whole
    application is a picture of every mapping at once, which is a picture of
    nothing; this one has an edge per resource-relation pair and holds its shape
    at any size.

    > #### Mix Dependency {: .warning}
    >
    > This module requires the optional dependency `:ash_diagram`.

    ## What the picture means

    | | |
    |---|---|
    | cylinder | a legacy relation |
    | rectangle | a resource, with the view it reads through and its write mode |
    | `<-->` | the resource can write back |
    | `-->` | every mapping on this pair is read-only |
    | `-.->` | a joined relation, which is always read-only |
    """

    alias AshDiagram.Flowchart
    alias AshDiagram.Flowchart.Edge
    alias AshDiagram.Flowchart.Node
    alias AshDiagram.Flowchart.Subgraph
    alias AshStrangler.Diagram.Mapping
    alias AshStrangler.Join
    alias AshStrangler.Map, as: MapEntry

    @typedoc """
    Configuration option for overview diagram generation.

    - `{:name, :full | :short}` — how to label resources.
    """
    @type option() :: {:name, :full | :short}

    @typedoc "List of configuration options for overview diagram generation."
    @type options() :: [option()]

    @default_options [name: :short]

    @doc "Generates an overview diagram for every strangled resource in `applications`."
    @spec for_applications(applications :: [Application.app()], options :: options()) ::
            Flowchart.t()
    def for_applications(applications, options \\ []),
      do: applications |> Enum.flat_map(&Ash.Info.domains/1) |> for_domains(options)

    @doc "Generates an overview diagram for every strangled resource in `domains`."
    @spec for_domains(domains :: [Ash.Domain.t()], options :: options()) :: Flowchart.t()
    def for_domains(domains, options \\ []),
      do: domains |> Enum.flat_map(&Ash.Domain.Info.resources/1) |> for_resources(options)

    @doc """
    Generates an overview diagram for `resources`.

    ## Examples

        AshStrangler.Diagram.Overview.for_resources([MyApp.Sales.Customer, MyApp.Sales.Address])
    """
    @spec for_resources(resources :: [Ash.Resource.t()], options :: options()) :: Flowchart.t()
    def for_resources(resources, options \\ []) do
      options = Keyword.merge(@default_options, options)
      resources = Enum.filter(resources, &AshStrangler.Info.strangled?/1)
      names = resource_names(resources, options[:name])

      ids = Map.new(resources, &{&1, "res_" <> slug(names[&1])})
      pairs = Enum.flat_map(resources, &pairs/1)
      relations = pairs |> Enum.map(& &1.relation) |> Enum.uniq()

      %Flowchart{
        direction: :left_right,
        entries: [
          legacy_subgraph(relations),
          resource_subgraph(resources, names, ids)
          | Enum.map(pairs, &edge(&1, ids))
        ]
      }
    end

    # One entry per resource-relation pair: the primary relation, plus each
    # joined one. Joins are always read-only -- writes go back through
    # `__legacy_id`, which identifies a row in the primary relation and nothing
    # in a joined one.
    defp pairs(resource) do
      source = AshStrangler.Info.source(resource)
      aliases = AshStrangler.Info.join_aliases(resource)
      primary = AshStrangler.Sql.View.primary_alias(source)

      mappings = Enum.filter(source.mappings, &is_struct(&1, MapEntry))

      {joined, own} =
        Enum.split_with(mappings, fn %MapEntry{column: column} ->
          is_binary(column) and qualifier(column, aliases, primary) != primary
        end)

      primary_pair = %{
        resource: resource,
        relation: source.relation,
        join: nil,
        mapped: length(own),
        read_only: Enum.count(own, &(not &1.writable?)),
        writable?: Enum.any?(own, & &1.writable?)
      }

      [primary_pair | Enum.map(source.joins, &join_pair(resource, &1, joined, aliases, primary))]
    end

    defp join_pair(resource, %Join{} = join, joined, aliases, primary) do
      name = AshStrangler.Sql.View.alias_for(join)

      mapped =
        Enum.count(joined, fn %MapEntry{column: column} ->
          qualifier(column, aliases, primary) == name
        end)

      %{
        resource: resource,
        relation: join.relation,
        join: join,
        mapped: mapped,
        read_only: mapped,
        writable?: false
      }
    end

    defp legacy_subgraph(relations) do
      nodes =
        Enum.map(relations, fn relation ->
          %Node{id: relation_id(relation), label: Mapping.label(relation), shape: :database}
        end)

      %Subgraph{
        id: "legacy",
        label: Mapping.label("Legacy schema"),
        direction: :top_bottom,
        entries: nodes ++ chain(nodes)
      }
    end

    defp resource_subgraph(resources, names, ids) do
      nodes =
        Enum.map(resources, fn resource ->
          %Node{
            id: ids[resource],
            label: Mapping.label(resource_label(resource, names)),
            shape: :rectangle
          }
        end)

      %Subgraph{
        id: "strangled",
        label: Mapping.label(phase_label(resources)),
        direction: :top_bottom,
        entries: nodes ++ chain(nodes)
      }
    end

    defp resource_label(resource, names) do
      [
        to_string(names[resource]),
        view_name(resource),
        "writes: #{AshStrangler.Info.writes(resource)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")
    end

    defp phase_label(resources) do
      case resources |> Enum.map(&AshStrangler.Info.strangler_phase!/1) |> Enum.uniq() do
        [phase] -> "The strangled model - phase: #{phase}"
        phases -> "The strangled model - phases: #{Enum.map_join(phases, ", ", &to_string/1)}"
      end
    end

    defp edge(pair, ids) do
      %Edge{
        from: relation_id(pair.relation),
        to: ids[pair.resource],
        type: edge_type(pair),
        label: Mapping.label(edge_label(pair))
      }
    end

    defp edge_type(%{join: %Join{}}), do: :dotted_arrow
    defp edge_type(%{writable?: true}), do: :bidirectional
    defp edge_type(_pair), do: :arrow

    defp edge_label(%{join: %Join{} = join} = pair) do
      keyword = if join.type == :inner, do: "INNER JOIN", else: "LEFT JOIN"
      "#{keyword} - #{pair.mapped} mapped, read only"
    end

    defp edge_label(pair) do
      case pair.read_only do
        0 -> "#{pair.mapped} mapped"
        n -> "#{pair.mapped} mapped, #{n} read only"
      end
    end

    defp chain(nodes) when length(nodes) < 2, do: []

    defp chain(nodes) do
      nodes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %Edge{from: from.id, to: to.id, type: :invisible} end)
    end

    defp qualifier(column, aliases, primary) do
      case String.split(column, ".", parts: 2) do
        [qualifier, _rest] -> if qualifier in aliases, do: qualifier, else: primary
        [_bare] -> primary
      end
    end

    defp view_name(resource) do
      if Code.ensure_loaded?(AshPostgres.DataLayer.Info) do
        case AshPostgres.DataLayer.Info.table(resource) do
          nil -> nil
          table -> "#{AshPostgres.DataLayer.Info.schema(resource) || "public"}.#{table} (view)"
        end
      end
    end

    defp relation_id(relation), do: "rel_#{sanitize(relation)}"

    defp slug(name), do: name |> to_string() |> sanitize() |> String.downcase()

    defp sanitize(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "_")

    defp resource_names(resources, :full), do: Map.new(resources, &{&1, inspect(&1)})

    defp resource_names(resources, :short) do
      common = common_prefix(resources)

      Map.new(resources, fn resource ->
        {resource, resource |> Module.split() |> Enum.drop(length(common)) |> Enum.join(".")}
      end)
    end

    defp common_prefix([]), do: []

    defp common_prefix([resource]) do
      parts = Module.split(resource)
      Enum.take(parts, length(parts) - 1)
    end

    defp common_prefix(resources) do
      resources
      |> Enum.map(&Module.split/1)
      |> Enum.reduce(fn parts, acc ->
        acc
        |> Enum.zip(parts)
        |> Enum.take_while(fn {a, b} -> a == b end)
        |> Enum.map(&elem(&1, 0))
      end)
    end
  end
end
