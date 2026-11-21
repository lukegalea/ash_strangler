# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Hop do
  @moduledoc """
  One hop of a lineage chain that starts at a facade.

      %Hop{
        kind: :facade,
        resource: MyApp.WorkItem,
        source: MyApp.Task,
        dataset: nil,
        mapping_version: "...",
        edges: [...]
      }

  A facade has no storage of its own, so a facade hop carries no dataset: the
  rows live on the source, and the chain continues there. A `:strangled` hop
  carries the dataset of the source's legacy relation; an `:owned` hop, the
  dataset of the resource's own table. Walking the chain reads one hop at a
  time — no hop has to trust the description of the one above it.

  `edges` are `AshStrangler.Lineage.Edge` structs, classified by the same code
  that draws a strangled mapping, so one lens reads the same way in both graphs.
  """

  alias Ash.Resource.Info
  alias AshStrangler.{Facade.Info, Lineage, MappingVersion}

  defstruct [:kind, :resource, :source, :dataset, :mapping_version, :edges]

  @type kind :: :facade | :strangled | :owned

  @type dataset :: %{namespace: String.t(), name: String.t()} | nil

  @type t :: %__MODULE__{
          kind: kind(),
          resource: Ash.Resource.t(),
          source: Ash.Resource.t() | nil,
          dataset: dataset(),
          mapping_version: String.t() | nil,
          edges: [Lineage.Edge.t()]
        }

  @doc """
  The chain from `resource` down.

  `resource` must itself be a facade — a hop chain starts at one. Each step
  adds one hop for the resource it describes, then moves to that hop's source.
  Hops read compiled modules: a lens needs the source's fields, and a dataset
  needs the repo's configuration.
  """
  @spec chain(Ash.Resource.t()) :: [t()]
  def chain(facade) when is_atom(facade) do
    hop =
      %__MODULE__{
        kind: :facade,
        resource: facade,
        source: Info.source(facade),
        dataset: nil,
        mapping_version: Info.mapping_version(facade),
        edges: Info.hop_edges(facade, Info.source(facade), Map.values(Info.lenses(facade)))
      }

    [hop | continue(Info.source(facade))]
  end

  defp continue(source) do
    cond do
      source == nil ->
        []

      AshStrangler.Facade.Info.source(source) ->
        chain(source)

      AshStrangler.Info.strangled?(source) ->
        [
          %__MODULE__{
            kind: :strangled,
            resource: source,
            source: AshStrangler.Info.twin(source),
            dataset: dataset(AshStrangler.Info.twin(source)),
            mapping_version: MappingVersion.hash(source),
            edges: edges_of_strangled(source)
          }
        ]

      true ->
        [
          %__MODULE__{
            kind: :owned,
            resource: source,
            source: nil,
            dataset: dataset(source),
            mapping_version: nil,
            edges: []
          }
        ]
    end
  end

  defp edges_of_strangled(resource) do
    {_nodes, edges} = Lineage.for_resource(resource)
    edges
  end

  @doc "The dataset the rows physically live in, or `nil` over anything else."
  @spec dataset(Ash.Resource.t()) :: dataset()
  def dataset(resource) do
    if postgres_backed?(resource), do: postgres_dataset(resource), else: nil
  end

  defp postgres_backed?(resource) do
    Code.ensure_loaded?(AshPostgres.DataLayer) and
      Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer
  end

  defp postgres_dataset(resource) do
    repo = AshPostgres.DataLayer.Info.repo(resource)
    config = repo.config()
    schema = AshPostgres.DataLayer.Info.schema(resource) || config[:schema] || "public"

    %{
      namespace: "postgres://#{config[:hostname]}:#{config[:port]}",
      name: "#{config[:database]}.#{schema}.#{AshPostgres.DataLayer.Info.table(resource)}"
    }
  end
end
