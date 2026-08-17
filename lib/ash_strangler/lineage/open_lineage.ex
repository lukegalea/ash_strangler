# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Lineage.OpenLineage do
  @moduledoc """
  `AshStrangler.Lineage` rendered as OpenLineage's `columnLineage` dataset facet.

  Mermaid (`AshStrangler.Diagram.Mapping`) is the exporter for a human reading a
  pull request. This is the exporter for everything else: Marquez, DataHub,
  OpenMetadata, Atlan, Egeria, Airflow's lineage backend — anything that already
  speaks the facet.

  ## Why it is nearly free

  Because the model was built in the facet's vocabulary rather than translated into
  it afterwards. `AshStrangler.Lens` classifies every mapping as `:identity |
  :transformation | :masked | :structural` — which is OpenLineage's `IDENTITY |
  TRANSFORMATION` plus `masking` — and `AshStrangler.Lineage.Edge` already carries
  `type`, `subtype`, `transformation`, `description` and `masking?` as fields. So
  nothing here decides what a transform *is*. That decision was made once, in the
  grammar, and this module reshapes it.

  If that ever stops being true — if this module grows a `cond` that classifies
  something — then the vocabulary has been forked, and the diagram and the
  writability decision have gone back to agreeing by coincidence, which is the
  failure `AshStrangler.Lineage`'s moduledoc describes at length.

  ## Why it is worth having anyway

  A migration tool's deliverable is not the migration. It is **convincing somebody
  that nothing was lost** — usually somebody who will not read Elixir, and who is
  entitled to ask the question in a tool their organisation already owns. In most
  enterprises that tool is a lineage catalogue, and a column-level answer that
  lands there is worth more than a better diagram in a repository nobody outside
  the team reads.

  It also buys a kind of review this package cannot perform on itself. The
  interesting rows in the facet are the `masking: true` ones — the columns that
  cannot travel back — and `AshStrangler` deliberately makes those explicit and
  reasoned (`read_only?: true, because: "…"`) instead of inferred. Exporting them
  puts each stated reason in front of whoever owns the data, who is the only reader
  able to tell whether the reason is true.

  ## What a structural mapping looks like, and why it is present at all

  A `constant`, a `key` derivation or an `unmapped` attribute reads no legacy
  column, so its output field carries an empty `inputFields` list. That is
  deliberately **not** the same statement as leaving the field out. Omitting it
  says *lineage unknown*, which is what 0.1's regex said when it gave up and what
  `AshStrangler.Lineage` exists to make unrepresentable. Listing it with no inputs
  says *this column has no legacy source*, which is a fact the mapping declared out
  loud.

  ## What is deliberately not exported

  `invertible` (`:yes | :semi | :no`) has no counterpart in the facet, and the
  facet's entire value is being read by tools that validate against its published
  schema. A custom key inside a specified object risks the export being rejected by
  the consumer it exists to reach — trading the one thing this module is for
  against a field the Mermaid exporter already draws as a line style. Where
  invertibility is the point it travels in `description`, which is a prose field:
  `"collapse - invertible modulo a declared default"`.

  ## Namespaces

  OpenLineage's naming convention for PostgreSQL is a `postgres://host:port`
  namespace with the schema-qualified relation as the dataset name, and it is a
  convention rather than a lookup — the namespace has to match what the *other*
  producers writing to the same catalogue use, or one table arrives as two
  unrelated datasets and the graph disconnects at the join without complaining. So
  it is derived from the repo's own connection configuration, and overridable with
  `:namespace` for a catalogue fed through a bouncer or a replica, which is named
  after neither.
  """

  alias AshStrangler.{Info, Lineage}
  alias AshStrangler.Lineage.{Edge, Node}

  @producer "https://github.com/lukegalea/ash_strangler"
  @schema_url "https://openlineage.io/spec/facets/1-2-0/ColumnLineageDatasetFacet.json"

  @doc """
  The `columnLineage` facet for one resource's dataset.

  Takes a resource rather than a `t:AshStrangler.Lineage.t/0` because a facet
  describes exactly one **output** dataset. Three resources over one legacy table —
  the case this package exists for — would otherwise have to merge three sets of
  output fields into one `"fields"` map, describing a relation that does not exist.

  ## Options

    * `:namespace` — the dataset namespace for every relation named, overriding the
      one derived from the repo's connection configuration.
  """
  @spec facet(Ash.Resource.t(), keyword()) :: %{String.t() => term()}
  def facet(resource, opts \\ []) do
    namespace = namespace(resource, opts)
    {nodes, edges} = Lineage.for_resource(resource)

    sources = Map.new(nodes, &{&1.id, &1})
    inputs = Enum.group_by(edges, & &1.to)

    fields =
      nodes
      |> Enum.filter(&(&1.side == :new))
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn output ->
        {output.column, field(Map.get(inputs, output.id, []), sources, namespace)}
      end)

    %{"_producer" => @producer, "_schemaURL" => @schema_url, "fields" => fields}
  end

  @doc """
  The output dataset for one resource, with the `columnLineage` facet attached.

  This is the shape an OpenLineage `RunEvent` carries in its `outputs` array.
  Wrapping it in one is left to the caller, who is the only party that has a run id
  and an event time.
  """
  @spec dataset(Ash.Resource.t(), keyword()) :: %{String.t() => term()}
  def dataset(resource, opts \\ []) do
    %{
      "namespace" => namespace(resource, opts),
      "name" => relation(resource),
      "facets" => %{"columnLineage" => facet(resource, opts)}
    }
  end

  @doc """
  One dataset per resource, for those carrying a `strangler` mapping.

  Unmapped resources are dropped rather than emitted with an empty facet, matching
  `AshStrangler.Lineage.for_resources/1`. The distinction drawn above between an
  empty `inputFields` and an absent field applies to *columns*; a resource that
  declares no mapping at all is not part of the migration and has nothing to assert.
  """
  @spec datasets([Ash.Resource.t()], keyword()) :: [%{String.t() => term()}]
  def datasets(resources, opts \\ []) do
    resources
    |> Enum.filter(&Info.strangled?/1)
    |> Enum.map(&dataset(&1, opts))
  end

  @doc """
  `datasets/2` as JSON.

  `:jason` is not a new dependency — `ash` requires it unconditionally — so this
  costs nothing and saves every caller writing the same line.
  """
  @spec encode!([Ash.Resource.t()], keyword()) :: String.t()
  def encode!(resources, opts \\ []), do: resources |> datasets(opts) |> Jason.encode!()

  # --- fields ------------------------------------------------------------------

  defp field(edges, sources, namespace) do
    %{
      "inputFields" =>
        Enum.map(edges, fn %Edge{from: from} = edge ->
          %Node{relation: relation, column: column} = Map.fetch!(sources, from)

          %{
            "namespace" => namespace,
            "name" => relation,
            "field" => column,
            "transformations" => transformations(edge)
          }
        end)
    }
  end

  # Both entries come off the same `%Edge{}`. `subtype` is the DIRECT-flavoured
  # classification and `transformation` is the INDIRECT-flavoured one, and the facet
  # permits several transformations per input field precisely so that a value which
  # is both transformed and reached through a join can say both.
  defp transformations(%Edge{transformation: nil} = edge), do: [direct(edge)]

  defp transformations(%Edge{transformation: indirect} = edge) do
    [
      direct(edge),
      %{
        "type" => "INDIRECT",
        "subtype" => to_string(indirect),
        "description" => edge.description,
        "masking" => edge.masking?
      }
    ]
  end

  defp direct(%Edge{} = edge) do
    %{
      "type" => to_string(edge.type),
      "subtype" => to_string(edge.subtype),
      "description" => edge.description,
      "masking" => edge.masking?
    }
  end

  # --- naming ------------------------------------------------------------------

  defp namespace(resource, opts) do
    Keyword.get_lazy(opts, :namespace, fn -> derive_namespace(resource) end)
  end

  defp derive_namespace(resource) do
    config =
      case AshPostgres.DataLayer.Info.repo(resource, :read) do
        nil -> []
        repo -> repo.config()
      end

    "postgres://#{Keyword.get(config, :hostname, "localhost")}:#{Keyword.get(config, :port, 5432)}"
  rescue
    # A repo declared as a function of `{resource, type}` cannot be asked for its
    # configuration outside a live query, and an export is not one. Falling back is
    # better than raising out of a reporting tool, and naming the fallback in the
    # namespace is better than emitting a plausible-looking wrong one that would
    # silently split the dataset in the catalogue.
    _ -> "postgres://unknown"
  end

  defp relation(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)

    case AshPostgres.DataLayer.Info.schema(resource) do
      nil -> table
      schema -> "#{schema}.#{table}"
    end
  end
end
