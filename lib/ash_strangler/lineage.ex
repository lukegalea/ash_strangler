# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Lineage do
  @moduledoc """
  Column-level lineage as a **model**, with renderers behind it.

  Nodes are `{side, relation, column}`; edges carry a type, a subtype, a
  description and an invertibility. Mermaid is one exporter
  (`AshStrangler.Diagram.Mapping`) and OpenLineage is another
  (`AshStrangler.Lineage.OpenLineage`). That is Structurizr's separation of model,
  view selection and exporters, and it is what stops Mermaid *being* the model.

  ## Why the vocabulary is borrowed rather than invented

  0.1 needed a **second notation** — four shapes and four line styles, documented
  in `AshStrangler.Diagram.Mapping` — to describe what the first notation did.
  Needing a second language to talk about the first is the symptom, not the
  disease: the mapping DSL could not say what a transform *was*, so the diagram had
  to.

  The edge vocabulary here is OpenLineage's `columnLineage` facet, taken directly:
  `DIRECT` / `INDIRECT`, subtypes `IDENTITY | TRANSFORMATION | AGGREGATION` and
  `JOIN | GROUP_BY | FILTER | SORT | WINDOW | CONDITIONAL`, plus `masking`. That
  matters for a reason beyond not inventing things: **`IDENTITY | TRANSFORMATION |
  MASKED` is already a three-way invertibility classification**, so the diagram and
  the writability decision compute from one source rather than agreeing by
  coincidence. It also makes the model readable by existing lineage tooling, which
  is worth something for a tool whose job is proving to somebody that nothing was
  lost.

  ## The failure mode that is now unrepresentable

  `AshStrangler.Diagram.Sql` inferred lineage with a regex over the `from:` string
  and a 60-word SQL keyword denylist, returning `:unresolved` when it found
  nothing. Its own moduledoc argued — correctly — that a diagram which quietly
  omits edges it could not work out is worse than no diagram, so the mapping
  diagram drew a rhombus reading *"source columns not resolved"*.

  But it had a second consumer that did not get that treatment.
  `AshStrangler.Resource`'s `legacy_columns/1` hook degraded `:unresolved` to `[]`, so a
  column the regex could not parse vanished silently from every
  entity-relationship diagram the application drew — including
  `mix ash.generate_resource_diagrams`' and Clarity's.

  Both are gone. Lineage is `AshStrangler.Expr.refs/1` over a tree that was
  *constructed*, so there is no failure to degrade and no rhombus to draw. That is
  the industrial argument too: SQLGlot and SQLMesh both document that recovered
  column lineage degrades to nothing on `SELECT *` and unknown schemas. Constructing
  the structure beats recovering it.
  """

  alias AshStrangler.{Info, Lens, Twin}

  defmodule Node do
    @moduledoc "One column, on one side of the migration."
    defstruct [:id, :side, :relation, :column, :type, :label]

    @type t() :: %__MODULE__{
            id: String.t(),
            side: :legacy | :new,
            relation: String.t(),
            column: String.t(),
            type: String.t() | nil,
            label: String.t()
          }
  end

  defmodule Edge do
    @moduledoc """
    One flow from a legacy column to a resource attribute.

    `type`/`subtype`/`transformation`/`masking?` are OpenLineage's `columnLineage`
    vocabulary; `invertible` is this package's addition and is what the Mermaid
    exporter turns into a line style.
    """
    defstruct [
      :from,
      :to,
      :attribute,
      :combinator,
      :description,
      type: :DIRECT,
      subtype: :IDENTITY,
      transformation: nil,
      masking?: false,
      invertible: :yes
    ]

    @type t() :: %__MODULE__{}
  end

  defstruct nodes: [], edges: [], resources: []

  @type t() :: %__MODULE__{nodes: [Node.t()], edges: [Edge.t()], resources: [Ash.Resource.t()]}

  @doc """
  The lineage model for a set of resources.

  Resources without a `strangler` block are skipped rather than drawn empty — a
  resource that is not mapped has no transformation to show.

  Legacy relations are **shared** between resources: three resources over one wide
  table is the case this package exists for, and modelling that table three times
  would hide exactly the fan-out worth seeing.
  """
  @spec for_resources([Ash.Resource.t()]) :: t()
  def for_resources(resources) do
    resources = Enum.filter(resources, &Info.strangled?/1)

    {nodes, edges} =
      Enum.reduce(resources, {[], []}, fn resource, {nodes, edges} ->
        {resource_nodes, resource_edges} = for_resource(resource)
        {nodes ++ resource_nodes, edges ++ resource_edges}
      end)

    %__MODULE__{
      nodes: Enum.uniq_by(nodes, & &1.id),
      edges: Enum.uniq_by(edges, &{&1.from, &1.to}),
      resources: resources
    }
  end

  @doc "The nodes and edges one resource contributes."
  @spec for_resource(Ash.Resource.t()) :: {[Node.t()], [Edge.t()]}
  def for_resource(resource) do
    twin = Info.twin(resource)
    attributes = Map.new(Ash.Resource.Info.attributes(resource), &{&1.name, &1})

    # `by_attribute/1` rather than `for_resource/1`, because an `unmapped [:a, :b]`
    # is ONE entity and therefore one lens, whose `attribute` is `:a`. Folding the
    # composite would model `:a` and leave `:b` with no node and no field in the
    # OpenLineage facet -- the one shape in which a column could still go missing
    # from a diagram, which is the failure this module exists to make
    # unrepresentable.
    #
    # The key's lens is added back, because `by_attribute/1` covers mappings only and
    # the derived key is an edge worth drawing.
    key_lens = resource |> Lens.for_resource() |> Enum.filter(&(&1.combinator == :key))

    (key_lens ++ Map.values(Lens.by_attribute(resource)))
    |> Enum.reduce({[], []}, fn lens, {nodes, edges} ->
      target = attribute_node(resource, Map.get(attributes, lens.attribute), lens.attribute)

      {source_nodes, source_edges} =
        lens.sources
        |> Enum.map(&column_node(twin, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce({[], []}, fn source, {ns, es} ->
          {ns ++ [source], es ++ [edge(lens, source, target)]}
        end)

      {nodes ++ [target] ++ source_nodes, edges ++ source_edges}
    end)
  end

  @doc """
  Every attribute's lineage as a map, which is the shape both exporters want and
  the shape `AshStrangler.Resource`'s entity-relationship hook reads.
  """
  @spec by_attribute(t()) :: %{atom() => [{Node.t(), Edge.t()}]}
  def by_attribute(%__MODULE__{nodes: nodes, edges: edges}) do
    index = Map.new(nodes, &{&1.id, &1})

    edges
    |> Enum.group_by(& &1.attribute)
    |> Map.new(fn {attribute, edges} ->
      {attribute, Enum.map(edges, &{Map.fetch!(index, &1.from), &1})}
    end)
  end

  # --- nodes -------------------------------------------------------------------

  defp column_node(nil, _reference), do: nil

  defp column_node(twin, {path, attribute}) do
    with {:ok, resource} <- Twin.resource_at(twin, path),
         %{} = attr <- Ash.Resource.Info.attribute(resource, attribute) do
      relation = Twin.relation(resource)
      column = Twin.column!(resource, attribute)

      %Node{
        id: "l_#{sanitize(relation)}__#{sanitize(column)}",
        side: :legacy,
        relation: relation,
        column: column,
        type: type_name(attr.type),
        label: "#{column} : #{type_name(attr.type)}"
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp attribute_node(resource, nil, name) do
    %Node{
      id: "n_#{slug(resource)}__#{sanitize(name)}",
      side: :new,
      relation: inspect(resource),
      column: to_string(name),
      type: nil,
      label: to_string(name)
    }
  end

  defp attribute_node(resource, attribute, name) do
    %Node{
      id: "n_#{slug(resource)}__#{sanitize(name)}",
      side: :new,
      relation: inspect(resource),
      column: to_string(name),
      type: type_name(attribute.type),
      label: attribute_label(attribute)
    }
  end

  defp attribute_label(attribute) do
    [
      "#{attribute.name} : #{type_name(attribute.type)}",
      if(attribute.primary_key?, do: "PK"),
      states(attribute)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # Read off the attribute's own constraints rather than asked of
  # `AshStateMachine`, so a plain `one_of` atom gets the same treatment and nothing
  # here depends on that extension being loaded.
  defp states(%{constraints: constraints}) when is_list(constraints) do
    case Keyword.get(constraints, :one_of) do
      nil -> nil
      values -> "[#{Enum.map_join(values, ", ", &to_string/1)}]"
    end
  end

  defp states(_attribute), do: nil

  # --- edges -------------------------------------------------------------------

  defp edge(%Lens{} = lens, source, target) do
    {type, subtype} = edge_type(lens)

    %Edge{
      from: source.id,
      to: target.id,
      attribute: lens.attribute,
      combinator: lens.combinator,
      type: type,
      subtype: subtype,
      transformation: transformation(lens),
      masking?: lens.type == :masked,
      invertible: lens.invertible,
      description: description(lens)
    }
  end

  defp subtype(%Lens{type: :identity}), do: :IDENTITY
  defp subtype(%Lens{}), do: :TRANSFORMATION

  # `IDENTITY` is a **DIRECT** subtype in the OpenLineage facet; the INDIRECT
  # subtypes are `JOIN | GROUP_BY | FILTER | SORT | WINDOW | CONDITIONAL`. So an edge
  # cannot be `INDIRECT`/`IDENTITY` -- a strict validator rejects the pairing, and
  # being readable by those validators is the reason for borrowing the vocabulary at
  # all.
  #
  # Every edge this model produces has a legacy column at one end, because a mapping
  # with no sources produces no edge. So every edge is `DIRECT`, and a derived key --
  # which reads the legacy key and hashes it -- is a `TRANSFORMATION` of it rather
  # than a structural annotation.
  defp edge_type(%Lens{combinator: :key, entry: %{strategy: :identity}}), do: {:DIRECT, :IDENTITY}
  defp edge_type(%Lens{combinator: :key}), do: {:DIRECT, :TRANSFORMATION}
  defp edge_type(%Lens{} = lens), do: {:DIRECT, subtype(lens)}

  defp transformation(%Lens{subtypes: subtypes}) do
    cond do
      :join in subtypes -> :JOIN
      :conditional in subtypes -> :CONDITIONAL
      true -> nil
    end
  end

  # The label the Mermaid exporter puts on the edge, and the `description` the
  # OpenLineage facet carries. One string, because they are answering the same
  # question and two would drift.
  defp description(%Lens{combinator: :rename}), do: nil
  defp description(%Lens{combinator: :key}), do: "key"
  defp description(%Lens{combinator: :constant}), do: "constant"
  defp description(%Lens{combinator: :cast}), do: "cast"

  defp description(%Lens{combinator: :zone, entry: %{zone: zone}}), do: "AT TIME ZONE '#{zone}'"

  defp description(%Lens{type: :masked} = lens) do
    reason = lens.because || "no reason given"
    "#{if lens.opaque?, do: "opaque", else: "read only"} - #{summarize(reason, 56)}"
  end

  defp description(%Lens{combinator: combinator, invertible: :semi}),
    do: "#{combinator} - invertible modulo a declared default"

  defp description(%Lens{combinator: combinator}), do: to_string(combinator)

  @doc """
  Collapses text onto one line and shortens it for use as a label.

  Truncation is honest rather than clever -- no attempt is made to summarise a
  decision table into something shorter, because a summary that drops a clause is a
  diagram that lies.
  """
  @spec summarize(String.t(), pos_integer()) :: String.t()
  def summarize(text, limit \\ 64) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(collapsed) <= limit do
      collapsed
    else
      collapsed |> String.slice(0, limit - 3) |> trim_to_word() |> Kernel.<>("...")
    end
  end

  # Cut at a word boundary rather than mid-token. A label ending "and no r..."
  # reads as a rendering fault; ending "and no..." reads as elision. It matters
  # most for `because:` reasons, where the label *is* the payload -- carrying why a
  # value cannot travel back is half the point of drawing the mapping.
  #
  # Only when a boundary is near the end: a long unbroken token (a URL, a
  # snake_case identifier) has no useful boundary, and backing up to the previous
  # space would drop more than the ragged edge costs.
  defp trim_to_word(text) do
    trimmed = String.trim_trailing(text)

    case :binary.matches(trimmed, " ") do
      [] ->
        trimmed

      matches ->
        {last, _} = List.last(matches)

        if last >= byte_size(trimmed) - 12 do
          trimmed |> binary_part(0, last) |> String.trim_trailing()
        else
          trimmed
        end
    end
  end

  @doc false
  def sanitize(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "_")

  @doc false
  def slug(value), do: value |> inspect() |> sanitize() |> String.downcase()

  @doc false
  def type_name({:array, inner}), do: type_name(inner) <> "[]"
  def type_name(nil), do: "unknown"
  def type_name(type) when is_atom(type), do: type |> Module.split() |> List.last()
  def type_name(type), do: inspect(type)
end
