# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

with {:module, AshDiagram.Flowchart} <- Code.ensure_compiled(AshDiagram.Flowchart) do
  defmodule AshStrangler.Diagram.Mapping do
    @moduledoc """
    The Mermaid renderer for `AshStrangler.Lineage`.

    Legacy columns on the left, resource attributes on the right, one edge per
    mapping saying what happens in between.

    > #### Mix Dependency {: .warning}
    >
    > This module requires the optional dependency `:ash_diagram`. Without it
    > the module is not compiled at all, and `mix ash_strangler.gen.diagram`
    > says so rather than failing obscurely.

    ## The notation is no longer a second language

    In 0.1 the diagram needed its own vocabulary — four shapes and four line
    styles — because the mapping DSL could not say what a transform *was*. A
    `from:` string was uniformly opaque, so the picture had to carry the meaning
    the declaration could not.

    Every mark below is now a rendering of `AshStrangler.Lens.classify/1`. The
    notation is a *projection* of the model rather than a parallel description of
    it, which is why the rhombus is gone: `AshStrangler.Diagram.Sql`'s "source
    columns not resolved" node existed because lineage was inferred by regex, and
    inferred lineage can fail. Constructed lineage cannot.

    | Mark | Means | Computed from |
    |---|---|---|
    | rectangle | a legacy column, labelled with its type | a twin attribute |
    | stadium | a resource attribute | an Ash attribute |
    | hexagon | a transform, labelled with the **combinator** | `lens.combinator` |
    | `==>` | structural: the key, or a constant with no legacy source | `type: :structural` |
    | `<-->` | the value travels both ways | `invertible: :yes` |
    | `--o` | travels back *modulo* a default, a separator or a `touch()` | `invertible: :semi` |
    | `-.->` | read-only, labelled with the mapping's own `because:` | `type: :masked` |
    | `-.-` | opaque: a `fragment`, proven neither way | `opaque?: true` |
    | `-->` | a column feeding a transform | — |

    > #### One notation the design asked for and Mermaid does not have {: .info}
    >
    > The design document specifies `<-.->` — a dotted bidirectional edge — for
    > `invertible: :semi`. Mermaid has no such edge, and `AshDiagram.Flowchart.Edge`
    > accordingly does not offer one. `--o` (a circle head) is used instead, and the
    > edge label always names the combinator, so the caveat is legible either way.
    > Recorded rather than quietly substituted, because the design document says
    > `<-.->` and a reader comparing the two deserves to know why they differ.

    ## Every edge points legacy to new

    Including the write-back ones, which are drawn `<-->` rather than as a second
    edge pointing the other way. An edge from the new side back to the legacy side
    reverses the layout ranking, and Mermaid then renders the whole diagram
    mirrored — legacy on the right — which reads as though the migration runs
    backwards.

    ## Trivial mappings are collapsed by default

    A rename is not a transformation. Drawing one edge per plain column mapping
    buries the four-columns-into-one-lifecycle case, which is the thing worth
    looking at, under a bundle of parallel lines that carry no information; past
    about a dozen columns the picture stops being readable at all. So plain 1:1
    mappings are gathered into a single node that names them, and `verbose?: true`
    expands them again.

    ## No colours, deliberately

    Shape and line style only. GitHub adapts a diagram to dark mode only when the
    diagram does not pin its own palette, so a `classDef` would make half the
    readers squint.
    """

    alias AshDiagram.Flowchart
    alias AshDiagram.Flowchart.Edge
    alias AshDiagram.Flowchart.Node
    alias AshDiagram.Flowchart.Subgraph
    alias AshStrangler.{Info, Lens, Lineage, Twin}

    @typedoc """
    Configuration option for mapping diagram generation.

    - `{:name, :full | :short}` — how to label resources. `:short` drops the
      module prefix the rendered resources have in common.
    - `{:verbose?, boolean()}` — draw every plain 1:1 mapping individually
      instead of collapsing them into one node.

    0.1 also took `{:known_columns, %{String.t() => [String.t()]}}`, which existed
    to filter the identifiers a regex guessed out of a SQL string. There is no
    guess left to filter.
    """
    @type option() :: {:name, :full | :short} | {:verbose?, boolean()}

    @typedoc "List of configuration options for mapping diagram generation."
    @type options() :: [option()]

    @default_options [name: :short, verbose?: false]

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

    Resources without a `strangler` block are skipped rather than drawn empty — a
    resource that is not mapped has no transformation to show.

    Legacy relations are shared between resources: three resources over one wide
    table is the case this package exists for, and drawing that table three times
    would hide exactly the fan-out worth seeing.

    ## Examples

        AshStrangler.Diagram.Mapping.for_resources([MyApp.Sales.Customer])

        AshStrangler.Diagram.Mapping.for_resources([MyApp.Sales.Customer], verbose?: true)
    """
    @spec for_resources(resources :: [Ash.Resource.t()], options :: options()) :: Flowchart.t()
    def for_resources(resources, options \\ []) do
      options = Keyword.merge(@default_options, options)
      resources = Enum.filter(resources, &Info.strangled?/1)
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
      lenses = Lens.for_resource(resource)
      {legacy_nodes, _edges} = Lineage.for_resource(resource)

      state = %{
        resource: resource,
        twin: Info.twin(resource),
        joins: Map.new(Info.joins(resource), &{&1.relation, &1}),
        label: names[resource],
        slug: slug(names[resource]),
        lenses: lenses,
        nodes: Map.new(legacy_nodes, &{&1.id, &1}),
        legacy: %{},
        legacy_order: [],
        transforms: [],
        attributes: [],
        edges: []
      }

      # Which attributes disappear into the bundle has to be known before any
      # attribute node is built, so the bundle can stand in for them.
      trivial = if options[:verbose?], do: [], else: bundleable(lenses)

      state
      |> Map.put(:bundled, MapSet.new(trivial, & &1.attribute))
      |> plan_attributes()
      |> plan_lenses(lenses -- trivial)
      |> plan_bundle(trivial)
    end

    # --- attributes -------------------------------------------------------

    defp plan_attributes(state) do
      accounted = Info.accounted_for(state.resource)

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
        "#{attribute.name} : #{Lineage.type_name(attribute.type)}",
        if(attribute.primary_key?, do: "PK"),
        states(attribute)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end

    defp states(%{constraints: constraints}) when is_list(constraints) do
      case Keyword.get(constraints, :one_of) do
        nil -> nil
        values -> "[#{Enum.map_join(values, ", ", &to_string/1)}]"
      end
    end

    defp states(_attribute), do: nil

    # --- the bundle -------------------------------------------------------

    defp bundleable(lenses) do
      trivial = Enum.filter(lenses, &trivial?/1)

      if length(trivial) < @bundle_threshold, do: [], else: trivial
    end

    # A rename off the primary relation, with nothing decorating it. `:cast` is
    # deliberately not trivial: a derived `::citext` changes comparison semantics
    # through the view, which is exactly the sort of thing a reader should see.
    defp trivial?(%Lens{combinator: :rename, sources: [{[], _column}]}), do: true
    defp trivial?(_lens), do: false

    defp plan_bundle(state, []), do: state

    defp plan_bundle(state, trivial) do
      relation = Twin.relation(state.twin)
      legacy_id = "l_#{sanitize(relation)}__bundle_#{state.slug}"
      new_id = "n_#{state.slug}__bundle"
      pairs = Enum.map(trivial, &bundle_pair(state, &1))

      state
      |> put_legacy(relation, "bundle_#{state.slug}", %Node{
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

    defp bundle_pair(state, %Lens{attribute: attribute, sources: [{[], name}]}) do
      column = column_name(state, name)

      if column == to_string(attribute), do: column, else: "#{column} -> #{attribute}"
    end

    defp listing(names) when length(names) <= 6, do: Enum.join(names, ", ")
    defp listing(names), do: names |> Enum.take(5) |> Enum.join(", ") |> Kernel.<>(", ...")

    # --- mappings ---------------------------------------------------------

    defp plan_lenses(state, lenses), do: Enum.reduce(lenses, state, &plan_lens(&2, &1))

    # A rename or a cast: one edge, carrying the classification.
    defp plan_lens(state, %Lens{combinator: combinator, sources: [source]} = lens)
         when combinator in [:rename, :cast, :zone] do
      state
      |> put_column(source)
      |> then(fn state ->
        put_edge(
          state,
          edge(
            column_id(state, source),
            attribute_id(state, lens.attribute),
            edge_type(lens),
            Lineage.summarize(lens_label(lens))
          )
        )
      end)
    end

    # The key: a hexagon carrying the derivation, because a uuid_v5 over the legacy
    # key is a transform even though nothing calls it a mapping.
    defp plan_lens(state, %Lens{combinator: :key, entry: entry} = lens) do
      case entry.strategy do
        :identity ->
          state
          |> put_column({[], entry.from})
          |> then(
            &put_edge(
              &1,
              edge(
                column_id(&1, {[], entry.from}),
                attribute_id(&1, lens.attribute),
                :thick_arrow,
                "key"
              )
            )
          )

        {:uuid_v5, namespace: _} ->
          id = transform_id(state, lens.attribute)
          prefix = AshStrangler.KeyDerivation.name_prefix(Twin.relation(state.twin))

          state
          |> put_column({[], entry.from})
          |> put_transform(%Node{
            id: id,
            label: label("uuid_v5(ns, '#{prefix}' || #{column_name(state, entry.from)})"),
            shape: :hexagon
          })
          |> then(fn state ->
            state
            |> put_edge(edge(column_id(state, {[], entry.from}), id, :arrow, nil))
            |> put_edge(edge(id, attribute_id(state, lens.attribute), :thick_arrow, "key"))
          end)

        _other ->
          state
      end
    end

    defp plan_lens(state, %Lens{combinator: :constant} = lens) do
      id = transform_id(state, lens.attribute)

      state
      |> put_transform(%Node{id: id, label: label("constant"), shape: :hexagon})
      |> put_edge(edge(id, attribute_id(state, lens.attribute), :thick_arrow, "constant"))
    end

    defp plan_lens(state, %Lens{combinator: combinator, entry: entry})
         when combinator in [:unmapped, :default] do
      id = "t_#{state.slug}__unmapped_#{unmapped_index(state)}"
      text = if entry.as == :default, do: "default", else: "NULL"

      state
      |> put_transform(%Node{id: id, label: label(text), shape: :hexagon})
      |> then(fn state ->
        Enum.reduce(entry.attributes, state, fn attribute, state ->
          put_edge(
            state,
            edge(
              id,
              attribute_id(state, attribute),
              :dotted_arrow,
              "unmapped - #{Lineage.summarize(entry.because || "no reason given", 56)}"
            )
          )
        end)
      end)
    end

    # Everything else: a transform node labelled with the combinator, fed by every
    # column it reads. In 0.1 this label was the `from:` string truncated to 64
    # characters, because there was nothing else to say about it.
    defp plan_lens(state, %Lens{} = lens) do
      id = transform_id(state, lens.attribute)

      state
      |> put_transform(%Node{id: id, label: label(to_string(lens.combinator)), shape: :hexagon})
      |> feed_transform(id, lens)
      |> put_edge(
        edge(
          id,
          attribute_id(state, lens.attribute),
          edge_type(lens),
          Lineage.summarize(lens_label(lens))
        )
      )
    end

    defp unmapped_index(state) do
      Enum.count(state.transforms, &String.contains?(node_id(&1), "__unmapped_"))
    end

    defp feed_transform(state, transform_id, %Lens{sources: sources}) do
      Enum.reduce(sources, state, fn source, state ->
        state
        |> put_column(source)
        |> then(&put_edge(&1, edge(column_id(&1, source), transform_id, :arrow, nil)))
      end)
    end

    # The whole notation, in one function. See the moduledoc's table.
    defp edge_type(%Lens{type: :structural}), do: :thick_arrow
    defp edge_type(%Lens{opaque?: true}), do: :dotted_line
    defp edge_type(%Lens{type: :masked}), do: :dotted_arrow
    defp edge_type(%Lens{invertible: :semi}), do: :circle
    defp edge_type(%Lens{}), do: :bidirectional

    defp lens_label(%Lens{type: :masked} = lens) do
      reason = Lineage.summarize(lens.because || "no reason given", 56)
      "#{if lens.opaque?, do: "opaque", else: "read only"} - #{reason}"
    end

    defp lens_label(%Lens{combinator: :rename}), do: ""
    defp lens_label(%Lens{combinator: :cast}), do: "cast"
    defp lens_label(%Lens{combinator: :zone, entry: %{zone: zone}}), do: "AT TIME ZONE '#{zone}'"

    defp lens_label(%Lens{combinator: combinator, invertible: :semi}),
      do: "#{combinator} - reverses modulo a declared value"

    defp lens_label(%Lens{combinator: combinator}), do: to_string(combinator)

    # --- assembly ---------------------------------------------------------

    # Grouped by relation, and ordered by first appearance rather than
    # alphabetically -- a column list in the order the mapping declares it is
    # the order the reader is holding in their head.
    defp legacy_subgraphs(plans) do
      nodes_by_key = plans |> Enum.flat_map(&Map.to_list(&1.legacy)) |> Map.new()
      joins = plans |> Enum.flat_map(&Map.to_list(&1.joins)) |> Map.new()

      plans
      |> Enum.flat_map(& &1.legacy_order)
      |> Enum.uniq()
      |> Enum.group_by(fn {relation, _column} -> relation end)
      |> Enum.map(fn {relation, keys} ->
        nodes = Enum.map(keys, &Map.fetch!(nodes_by_key, &1))

        %Subgraph{
          id: "legacy_#{sanitize(relation)}",
          label: label(relation_label(relation, Map.get(joins, relation))),
          direction: :top_bottom,
          entries: nodes ++ chain(nodes)
        }
      end)
    end

    defp relation_label(relation, nil), do: relation

    # Always `LEFT JOIN`, and stated on the subgraph because it is the thing a
    # reader should notice about a gathered relation: an `INNER JOIN` would remove
    # rows the old application can still see. It is not a default here -- the join is
    # derived from a relationship, and a relationship describes which rows RELATE,
    # not which rows survive, so there is no other value it could take.
    defp relation_label(relation, join), do: "#{relation} AS #{join.alias} (LEFT JOIN)"

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
        "writes: #{Info.writes(plan.resource)}"
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

    defp put_column(state, {path, _attribute} = source) do
      relation = relation_of(state, path)

      put_legacy(state, relation, column_name(state, source), %Node{
        id: column_id(state, source),
        label: label(column_label(state, source)),
        shape: :rectangle
      })
    end

    defp relation_of(state, []), do: Twin.relation(state.twin)

    defp relation_of(state, path) do
      case Twin.resource_at(state.twin, path) do
        {:ok, resource} -> Twin.relation(resource)
        {:error, _} -> Twin.relation(state.twin)
      end
    end

    defp column_name(state, {path, attribute}) do
      case Twin.resource_at(state.twin, path) do
        {:ok, resource} -> Twin.column!(resource, attribute)
        {:error, _} -> to_string(attribute)
      end
    rescue
      _ -> to_string(attribute)
    end

    defp column_name(state, attribute) when is_atom(attribute),
      do: column_name(state, {[], attribute})

    # The label carries the column's type, which the rectangle could not do in 0.1
    # because the legacy schema was never read.
    defp column_label(state, {path, attribute} = source) do
      with {:ok, resource} <- Twin.resource_at(state.twin, path),
           %{type: type} <- Ash.Resource.Info.attribute(resource, attribute) do
        "#{column_name(state, source)} : #{Lineage.type_name(type)}"
      else
        _ -> column_name(state, source)
      end
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
      do: %Edge{from: from, to: to, type: type, label: label_or_nil(text)}

    defp label_or_nil(nil), do: nil
    defp label_or_nil(""), do: nil
    defp label_or_nil(text), do: label(text)

    defp column_id(state, {path, _attribute} = source),
      do: "l_#{sanitize(relation_of(state, path))}__#{sanitize(column_name(state, source))}"

    defp attribute_id(state, attribute), do: "n_#{state.slug}__#{sanitize(attribute)}"
    defp transform_id(state, attribute), do: "t_#{state.slug}__#{sanitize(attribute)}"

    defp node_id(%Node{id: id}), do: IO.iodata_to_binary(id)

    @doc false
    # Quotes the label, which is what makes an expression survive being a
    # Mermaid label at all: quoted, `||`, `'`, `(`, `,`, `:` and even a nested
    # `[...]` all pass through untouched. Only a double quote would end the
    # label early, and `#quot;` is Mermaid's own escape for it.
    #
    # `AshDiagram` does not quote labels itself -- `Flowchart.Node.compose/1`
    # interpolates them raw between the shape delimiters -- so the quotes have
    # to be part of the label.
    #
    # Deliberately NOT `AshDiagram.Util.sanitize_non_escapable_string/2`, which
    # substitutes visual lookalikes for punctuation and would render an
    # expression as something that is no longer what the mapping declared.
    def label(text) do
      escaped =
        text
        |> to_string()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.replace("\"", "#quot;")

      ~s("#{escaped}")
    end

    defp sanitize(value), do: Lineage.sanitize(value)

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
