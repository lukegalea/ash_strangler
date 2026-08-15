# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

with {:module, AshDiagram.Flowchart} <- Code.ensure_compiled(AshDiagram.Flowchart) do
  defmodule AshStrangler.Diagram.Mapping do
    @moduledoc """
    Draws the transformation between a legacy relation and a strangled resource.

    Everything else `AshStrangler` generates is derived from the `strangler`
    block; so is this. The picture *is* the mapping, rendered — legacy columns
    on the left, resource attributes on the right, and one edge per mapping
    saying what happens in between.

    > #### Mix Dependency {: .warning}
    >
    > This module requires the optional dependency `:ash_diagram`. Without it
    > the module is not compiled at all, and `mix ash_strangler.gen.diagram`
    > says so rather than failing obscurely.

    ## What the picture means

    The notation carries the whole of the mapping, and it does so with **shape
    and line style only** — no colours. That is not an aesthetic choice: GitHub
    only adapts a diagram to dark mode when the diagram does not pin its own
    palette, so a `classDef` would make half the readers squint.

    | | |
    |---|---|
    | rectangle | a legacy column |
    | stadium | a resource attribute |
    | hexagon | a transformation — an expression, a key derivation, a constant |
    | rhombus | source columns this generator could not work out |
    | `==>` | structural: the key, or a constant with no legacy source |
    | `<-->` | writable — the value travels in both directions |
    | `-->` | a column feeding a transformation |
    | `-.->` | read-only, labelled with the mapping's own `because:` |

    ## Every edge points legacy to new

    Including the write-back ones, which are drawn `<-->` with the target column
    named in the label rather than as a second edge pointing the other way. An
    edge from the new side back to the legacy side reverses the layout ranking,
    and Mermaid then renders the whole diagram mirrored — legacy on the right —
    which reads as though the migration runs backwards.

    ## Trivial mappings are collapsed by default

    A rename is not a transformation. Drawing one edge per plain column mapping
    buries the four-columns-into-one-state-machine case, which is the thing
    worth looking at, under a bundle of parallel lines that carry no
    information; past about a dozen columns the picture stops being readable at
    all. So plain 1:1 mappings are gathered into a single node that names them,
    and `verbose?: true` expands them again.
    """

    alias AshDiagram.Flowchart
    alias AshDiagram.Flowchart.Edge
    alias AshDiagram.Flowchart.Node
    alias AshDiagram.Flowchart.Subgraph
    alias AshStrangler.Constant
    alias AshStrangler.Diagram.Sql
    alias AshStrangler.Join
    alias AshStrangler.Key
    alias AshStrangler.Map, as: MapEntry
    alias AshStrangler.Unmapped

    @typedoc """
    Configuration option for mapping diagram generation.

    - `{:name, :full | :short}` — how to label resources. `:short` drops the
      module prefix the rendered resources have in common.
    - `{:verbose?, boolean()}` — draw every plain 1:1 mapping individually
      instead of collapsing them into one node.
    - `{:known_columns, %{String.t() => [String.t()]}}` — real columns per
      relation, used to filter the identifiers extracted from `from:`
      expressions. See `AshStrangler.Diagram.Sql`.
    """
    @type option() ::
            {:name, :full | :short}
            | {:verbose?, boolean()}
            | {:known_columns, %{String.t() => [String.t()]}}

    @typedoc "List of configuration options for mapping diagram generation."
    @type options() :: [option()]

    @default_options [name: :short, verbose?: false, known_columns: %{}]

    # Below this many trivial mappings, drawing them individually costs less
    # than the indirection of a bundle node.
    @bundle_threshold 3

    @doc """
    Generates a mapping diagram for every strangled resource in `applications`.
    """
    @spec for_applications(applications :: [Application.app()], options :: options()) ::
            Flowchart.t()
    def for_applications(applications, options \\ []),
      do: applications |> Enum.flat_map(&Ash.Info.domains/1) |> for_domains(options)

    @doc """
    Generates a mapping diagram for every strangled resource in `domains`.
    """
    @spec for_domains(domains :: [Ash.Domain.t()], options :: options()) :: Flowchart.t()
    def for_domains(domains, options \\ []),
      do: domains |> Enum.flat_map(&Ash.Domain.Info.resources/1) |> for_resources(options)

    @doc """
    Generates a mapping diagram for `resources`.

    Resources without a `strangler` block are skipped rather than drawn empty —
    a resource that is not mapped has no transformation to show.

    Legacy relations are shared between resources: three resources over one wide
    table is the case this package exists for, and drawing that table three
    times would hide exactly the fan-out worth seeing.

    ## Examples

        AshStrangler.Diagram.Mapping.for_resources([MyApp.Sales.Customer])

        AshStrangler.Diagram.Mapping.for_resources([MyApp.Sales.Customer], verbose?: true)
    """
    @spec for_resources(resources :: [Ash.Resource.t()], options :: options()) :: Flowchart.t()
    def for_resources(resources, options \\ []) do
      options = Keyword.merge(@default_options, options)
      resources = Enum.filter(resources, &AshStrangler.Info.strangled?/1)
      names = resource_names(resources, options[:name])
      plans = Enum.map(resources, &plan(&1, names, options))

      %Flowchart{
        direction: :left_right,
        entries:
          legacy_subgraphs(plans) ++
            Enum.flat_map(plans, &transform_entries/1) ++
            Enum.map(plans, &resource_subgraph/1) ++
            Enum.flat_map(plans, & &1.edges)
      }
    end

    # --- planning ---------------------------------------------------------
    #
    # One pass per resource produces the nodes it contributes to each legacy
    # relation, the transform nodes it owns, its own attribute subgraph, and its
    # edges. Assembly then groups the legacy nodes by relation.

    defp plan(resource, names, options) do
      source = AshStrangler.Info.source(resource)
      mappings = source.mappings
      aliases = AshStrangler.Info.join_aliases(resource)
      primary = AshStrangler.Sql.View.primary_alias(source)

      state = %{
        resource: resource,
        source: source,
        label: names[resource],
        slug: slug(names[resource]),
        aliases: aliases,
        primary: primary,
        options: options,
        relations: relations(source),
        relation_info: relation_info(source),
        legacy: %{},
        legacy_order: [],
        transforms: [],
        attributes: [],
        edges: []
      }

      # Which attributes disappear into the bundle has to be known before any
      # attribute node is built, so the bundle can stand in for them.
      trivial = if options[:verbose?], do: [], else: bundleable(mappings, state)

      # The key first, then the mappings that do something, then the bundle --
      # which is also the order they read in, and the order the nodes end up in
      # inside each subgraph.
      state
      |> Map.put(:bundled, MapSet.new(trivial, & &1.attribute))
      |> plan_attributes()
      |> plan_key(source.keys)
      |> plan_mappings(mappings -- trivial)
      |> plan_bundle(trivial)
    end

    # Legacy nodes are keyed by RELATION, not by the alias mappings qualify
    # against. An alias defaults to the table's bare name, so `legacy.users` and
    # `archive.users` are both aliased `users` -- keying by alias would merge two
    # different tables into one subgraph and silently draw edges to the wrong
    # columns.
    defp relation_info(source) do
      source.joins
      |> Map.new(fn %Join{} = join ->
        {join.relation, {join, AshStrangler.Sql.View.alias_for(join)}}
      end)
      |> Map.put(source.relation, {nil, AshStrangler.Sql.View.primary_alias(source)})
    end

    # The relation each qualifier refers to, so assembly can title the subgraphs.
    defp relations(source) do
      source.joins
      |> Map.new(fn %Join{} = join ->
        {AshStrangler.Sql.View.alias_for(join), {join.relation, join}}
      end)
      |> Map.put(AshStrangler.Sql.View.primary_alias(source), {source.relation, nil})
    end

    # --- attributes -------------------------------------------------------

    defp plan_attributes(state) do
      accounted = AshStrangler.Info.accounted_for(state.resource)

      state.resource
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(&(MapSet.member?(accounted, &1.name) and not bundled?(state, &1.name)))
      |> Enum.reduce(state, fn attribute, state ->
        put_attribute(state, %Node{
          id: attribute_id(state, attribute.name),
          label: label(attribute_label(attribute)),
          shape: :stadium
        })
      end)
    end

    defp bundled?(state, name), do: MapSet.member?(state.bundled, name)

    defp attribute_label(attribute) do
      [
        "#{attribute.name} : #{type_name(attribute.type)}",
        if(attribute.primary_key?, do: "PK"),
        states(attribute)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end

    # Reads the state set off the attribute's own constraints rather than asking
    # `AshStateMachine`, so a plain `one_of` atom gets the same treatment and
    # nothing here depends on that extension being loaded.
    defp states(%{constraints: constraints}) when is_list(constraints) do
      case Keyword.get(constraints, :one_of) do
        nil -> nil
        values -> "[#{Enum.map_join(values, ", ", &to_string/1)}]"
      end
    end

    defp states(_attribute), do: nil

    defp type_name({:array, inner}), do: type_name(inner) <> "[]"
    defp type_name(nil), do: "unknown"
    defp type_name(type) when is_atom(type), do: type |> Module.split() |> List.last()
    defp type_name(type), do: inspect(type)

    # --- the bundle -------------------------------------------------------

    defp bundleable(mappings, state) do
      trivial = Enum.filter(mappings, &trivial?(&1, state))

      if length(trivial) < @bundle_threshold, do: [], else: trivial
    end

    defp trivial?(%MapEntry{} = mapping, state) do
      is_binary(mapping.column) and is_nil(mapping.cast) and is_nil(mapping.from_zone) and
        is_nil(mapping.to) and is_nil(mapping.into) and mapping.writable? and
        qualifier(mapping.column, state) == state.primary
    end

    defp trivial?(_entry, _state), do: false

    defp plan_bundle(state, []), do: state

    defp plan_bundle(state, trivial) do
      legacy_id = "l_#{sanitize(state.source.relation)}__bundle_#{state.slug}"
      new_id = "n_#{state.slug}__bundle"
      pairs = Enum.map(trivial, &bundle_pair/1)

      state
      |> put_legacy(state.source.relation, "bundle_#{state.slug}", %Node{
        id: legacy_id,
        label: label("#{length(trivial)} columns mapped 1:1: #{listing(pairs)}"),
        shape: :subroutine
      })
      |> put_attribute(%Node{
        id: new_id,
        label: label("#{length(trivial)} attributes"),
        shape: :subroutine
      })
      |> put_edge(edge(legacy_id, new_id, :bidirectional, "1:1"))
    end

    defp bundle_pair(%MapEntry{column: column, attribute: attribute}) do
      if column == to_string(attribute), do: column, else: "#{column} -> #{attribute}"
    end

    defp listing(names) when length(names) <= 6, do: Enum.join(names, ", ")
    defp listing(names), do: names |> Enum.take(5) |> Enum.join(", ") |> Kernel.<>(", ...")

    # --- the key ----------------------------------------------------------

    defp plan_key(state, [%Key{strategy: :identity} = key]) do
      state
      |> put_column(key.from)
      |> then(fn state ->
        put_edge(
          state,
          edge(
            column_id(state, key.from),
            attribute_id(state, key.attribute),
            :thick_arrow,
            "key"
          )
        )
      end)
    end

    defp plan_key(state, [%Key{strategy: {:uuid_v5, namespace: _}} = key]) do
      id = transform_id(state, key.attribute)
      prefix = AshStrangler.KeyDerivation.name_prefix(state.source.relation)

      state
      |> put_column(key.from)
      |> put_transform(%Node{
        id: id,
        label: label("uuid_v5(ns, '#{prefix}' || #{key.from})"),
        shape: :hexagon
      })
      |> then(fn state ->
        state
        |> put_edge(edge(column_id(state, key.from), id, :arrow, nil))
        |> put_edge(edge(id, attribute_id(state, key.attribute), :thick_arrow, "key"))
      end)
    end

    # No key, or several. `AshStrangler.Sql.View` raises on both; a diagram is
    # the wrong place to relitigate that, so it draws what it has.
    defp plan_key(state, _keys), do: state

    # --- mappings ---------------------------------------------------------

    defp plan_mappings(state, mappings), do: Enum.reduce(mappings, state, &plan_mapping(&2, &1))

    # A plain column: one edge, carrying the cast and the writability.
    defp plan_mapping(state, %MapEntry{column: column} = mapping) when is_binary(column) do
      state
      |> put_column(column)
      |> then(fn state ->
        put_edge(
          state,
          edge(
            column_id(state, column),
            attribute_id(state, mapping.attribute),
            direction(mapping),
            mapping_label(mapping)
          )
        )
      end)
    end

    # An expression: a transform node, fed by every column it reads.
    defp plan_mapping(state, %MapEntry{from: from} = mapping) when is_binary(from) do
      id = transform_id(state, mapping.attribute)

      state
      |> put_transform(%Node{id: id, label: label(Sql.summarize(from)), shape: :hexagon})
      |> feed_transform(id, from)
      |> put_edge(
        edge(
          id,
          attribute_id(state, mapping.attribute),
          direction(mapping),
          mapping_label(mapping)
        )
      )
    end

    defp plan_mapping(state, %Constant{} = constant) do
      id = transform_id(state, constant.attribute)

      state
      |> put_transform(%Node{
        id: id,
        label: label(Sql.summarize(constant.expression)),
        shape: :hexagon
      })
      |> put_edge(edge(id, attribute_id(state, constant.attribute), :thick_arrow, "constant"))
    end

    defp plan_mapping(state, %Unmapped{} = unmapped) do
      id = "t_#{state.slug}__unmapped_#{unmapped_index(state)}"
      text = if unmapped.as == :default, do: "default", else: "NULL"

      state
      |> put_transform(%Node{id: id, label: label(text), shape: :hexagon})
      |> then(fn state ->
        Enum.reduce(unmapped.attributes, state, fn attribute, state ->
          put_edge(
            state,
            edge(
              id,
              attribute_id(state, attribute),
              :dotted_arrow,
              "unmapped - #{reason(unmapped.because)}"
            )
          )
        end)
      end)
    end

    defp unmapped_index(state) do
      Enum.count(state.transforms, &String.contains?(node_id(&1), "__unmapped_"))
    end

    # Columns the expression reads. When none can be worked out the diagram says
    # so out loud rather than drawing a transform node fed by nothing.
    defp feed_transform(state, transform_id, expression) do
      known = state.options[:known_columns][state.source.relation]

      case Sql.columns(expression, known_columns: known) do
        :unresolved ->
          id = "u_#{transform_id}"

          state
          |> put_transform(%Node{
            id: id,
            label: label("source columns not resolved"),
            shape: :rhombus
          })
          |> put_edge(edge(id, transform_id, :arrow, nil))

        {:ok, columns} ->
          Enum.reduce(columns, state, fn column, state ->
            state
            |> put_column(column)
            |> then(&put_edge(&1, edge(column_id(&1, column), transform_id, :arrow, nil)))
          end)
      end
    end

    defp direction(%MapEntry{writable?: false}), do: :dotted_arrow
    defp direction(%MapEntry{}), do: :bidirectional

    defp mapping_label(%MapEntry{writable?: false} = mapping) do
      ["read only - #{reason(mapping.because)}", cast_label(mapping)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")
    end

    defp mapping_label(%MapEntry{} = mapping) do
      [cast_label(mapping), write_label(mapping)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")
      |> case do
        "" -> nil
        label -> label
      end
    end

    defp cast_label(%MapEntry{cast: :timestamptz, from_zone: zone}) when is_binary(zone),
      do: "AT TIME ZONE '#{zone}'"

    defp cast_label(%MapEntry{cast: nil}), do: nil
    defp cast_label(%MapEntry{cast: cast}), do: "::#{cast}"

    defp write_label(%MapEntry{into: into}) when is_binary(into), do: "write -> #{into}"
    defp write_label(%MapEntry{}), do: nil

    defp reason(nil), do: "no reason given"
    defp reason(because), do: Sql.summarize(because, 56)

    # --- assembly ---------------------------------------------------------

    # Grouped by relation, and ordered by first appearance rather than
    # alphabetically -- a column list in the order the mapping declares it is
    # the order the reader is holding in their head.
    defp legacy_subgraphs(plans) do
      nodes_by_key = plans |> Enum.flat_map(&Map.to_list(&1.legacy)) |> Map.new()

      plans
      |> Enum.flat_map(& &1.legacy_order)
      |> Enum.uniq()
      |> Enum.group_by(fn {relation, _column} -> relation end)
      |> Enum.map(fn {relation, keys} ->
        {join, alias} = info_for(plans, relation)
        nodes = Enum.map(keys, &Map.fetch!(nodes_by_key, &1))

        %Subgraph{
          id: "legacy_#{sanitize(relation)}",
          label: label(relation_label(relation, join, alias)),
          direction: :top_bottom,
          entries: nodes ++ chain(nodes)
        }
      end)
    end

    defp info_for(plans, relation) do
      Enum.find_value(plans, {nil, relation}, &Map.get(&1.relation_info, relation))
    end

    defp relation_label(relation, nil, _alias), do: relation

    defp relation_label(relation, %Join{} = join, alias) do
      keyword = if join.type == :inner, do: "INNER JOIN", else: "LEFT JOIN"
      "#{relation} AS #{alias} (#{keyword})"
    end

    # Transform nodes sit between the two subgraphs, chained so they stack in
    # the order their attributes were declared rather than fanning out.
    defp transform_entries(plan), do: plan.transforms ++ chain(plan.transforms)

    defp resource_subgraph(plan) do
      %Subgraph{
        id: "resource_#{plan.slug}",
        label: label(resource_label(plan)),
        direction: :top_bottom,
        entries: plan.attributes ++ chain(plan.attributes)
      }
    end

    defp resource_label(plan) do
      [
        to_string(plan.label),
        view_name(plan.resource),
        "writes: #{AshStrangler.Info.writes(plan.resource)}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")
    end

    defp view_name(resource) do
      if Code.ensure_loaded?(AshPostgres.DataLayer.Info) do
        case AshPostgres.DataLayer.Info.table(resource) do
          nil -> nil
          table -> "#{AshPostgres.DataLayer.Info.schema(resource) || "public"}.#{table} (view)"
        end
      end
    end

    # Invisible edges in declaration order. Mermaid ignores a subgraph's
    # `direction` as soon as any node in it has an edge leaving the subgraph --
    # which is every node here -- so without this chain the columns come out in
    # whatever order the layout engine prefers, which is not the order anybody
    # wrote them in.
    defp chain(nodes) when length(nodes) < 2, do: []

    defp chain(nodes) do
      nodes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %Edge{from: from.id, to: to.id, type: :invisible} end)
    end

    # --- state helpers ----------------------------------------------------

    defp put_column(state, column) do
      bare = bare_column(column)

      put_legacy(state, relation_of(state, column), bare, %Node{
        id: column_id(state, column),
        label: label(bare),
        shape: :rectangle
      })
    end

    defp relation_of(state, column) do
      {relation, _join} = Map.fetch!(state.relations, qualifier(column, state))
      relation
    end

    defp put_legacy(state, relation, bare, node) do
      key = {relation, bare}

      order =
        if Map.has_key?(state.legacy, key),
          do: state.legacy_order,
          else: state.legacy_order ++ [key]

      %{state | legacy: Map.put(state.legacy, key, node), legacy_order: order}
    end

    defp put_transform(state, node), do: %{state | transforms: state.transforms ++ [node]}
    defp put_attribute(state, node), do: %{state | attributes: state.attributes ++ [node]}
    defp put_edge(state, edge), do: %{state | edges: state.edges ++ [edge]}

    defp edge(from, to, type, text),
      do: %Edge{from: from, to: to, type: type, label: text && label(text)}

    defp column_id(state, column),
      do: "l_#{sanitize(relation_of(state, column))}__#{sanitize(bare_column(column))}"

    defp attribute_id(state, attribute), do: "n_#{state.slug}__#{sanitize(attribute)}"
    defp transform_id(state, attribute), do: "t_#{state.slug}__#{sanitize(attribute)}"

    defp node_id(%Node{id: id}), do: IO.iodata_to_binary(id)

    defp qualifier(column, state) do
      case String.split(column, ".", parts: 2) do
        [qualifier, _rest] -> if qualifier in state.aliases, do: qualifier, else: state.primary
        [_bare] -> state.primary
      end
    end

    defp bare_column(column) do
      case String.split(column, ".", parts: 2) do
        [_qualifier, rest] -> rest
        [bare] -> bare
      end
    end

    @doc false
    # Quotes the label, which is what makes a SQL expression survive being a
    # Mermaid label at all: quoted, `||`, `'`, `(`, `,`, `:` and even a nested
    # `[...]` all pass through untouched. Only a double quote would end the
    # label early, and `#quot;` is Mermaid's own escape for it.
    #
    # `AshDiagram` does not quote labels itself -- `Flowchart.Node.compose/1`
    # interpolates them raw between the shape delimiters -- so the quotes have
    # to be part of the label.
    #
    # Deliberately NOT `AshDiagram.Util.sanitize_non_escapable_string/2`, which
    # substitutes visual lookalikes for punctuation and would render
    # `coalesce(first_name,'')` as something that is no longer the SQL the
    # mapping declared.
    def label(text) do
      escaped =
        text
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.replace("\"", "#quot;")

      ~s("#{escaped}")
    end

    defp sanitize(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "_")

    defp slug(name), do: name |> to_string() |> sanitize() |> String.downcase()

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
