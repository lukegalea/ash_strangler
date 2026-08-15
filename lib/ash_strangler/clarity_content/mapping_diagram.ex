# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

with {:module, Clarity.Content} <- Code.ensure_loaded(Clarity.Content),
     {:module, _} <- Code.ensure_compiled(AshStrangler.Diagram.Mapping) do
  defmodule AshStrangler.ClarityContent.MappingDiagram do
    @moduledoc """
    Content provider showing the legacy-to-new mapping inside `Clarity`.

    Applications and domains get the overview — which relations feed which
    resources — because a column-level diagram of everything is a picture of
    nothing. A single resource gets the full mapping, column by column.

    Only offered where there is something to show: `applies?/2` is false for a
    resource with no `strangler` block, so this does not add an empty tab to
    every resource in an application where one table is being strangled.
    """

    @behaviour Clarity.Content

    alias AshStrangler.Diagram.Mapping
    alias AshStrangler.Diagram.Overview
    alias Clarity.Vertex
    alias Clarity.Vertex.Ash.Domain
    alias Clarity.Vertex.Ash.Resource

    @impl Clarity.Content
    def name, do: "Strangler Mapping"

    @impl Clarity.Content
    def description, do: "How this resource is projected out of the legacy schema"

    @impl Clarity.Content
    def applies?(%Vertex.Application{app: app}, _lens), do: [app] |> strangled_in() |> any?()
    def applies?(%Domain{domain: domain}, _lens), do: domain |> resources() |> any?()
    def applies?(%Resource{resource: resource}, _lens), do: AshStrangler.Info.strangled?(resource)
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Vertex.Application{app: app}, _lens) do
      [app] |> Overview.for_applications() |> mermaid()
    end

    def render_static(%Domain{domain: domain}, _lens) do
      [domain] |> Overview.for_domains() |> mermaid()
    end

    def render_static(%Resource{resource: resource}, _lens) do
      [resource] |> Mapping.for_resources() |> mermaid()
    end

    defp mermaid(diagram) do
      diagram
      |> AshDiagram.compose()
      |> IO.iodata_to_binary()
      |> then(&{:mermaid, &1})
    end

    defp strangled_in(apps) do
      apps
      |> Enum.flat_map(&Ash.Info.domains/1)
      |> Enum.flat_map(&resources/1)
    end

    defp resources(domain) do
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.filter(&AshStrangler.Info.strangled?/1)
    end

    defp any?([]), do: false
    defp any?(_resources), do: true
  end
end
