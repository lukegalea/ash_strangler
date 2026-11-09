# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

with {:module, Clarity.Content} <- Code.ensure_loaded(Clarity.Content) do
  defmodule AshStrangler.ClarityContent.MappingDiagram do
    @moduledoc """
    Content provider showing the legacy-to-new mapping inside `Clarity`.

    The tab is Markdown, not a diagram. A mapping is a list of facts about
    columns -- which legacy column feeds which attribute, through what SQL, in
    which direction, and why a value is read only -- and a picture either drops
    those facts (a relation-level overview that says "9 mapped, 3 read only") or
    drowns in them (a column-level graph of a dozen resources). A table keeps one
    row per attribute and has room for the text. See `AshStrangler.Diagram.Report`
    for exactly what each level holds.

    * **A resource** gets its phase, write mode, view and legacy relations, then
      one row per attribute, the read-only attributes by name with their reasons,
      and the legacy columns that nothing reads or that are `retired`.
    * **A domain or an application** gets an index of legacy relation to the
      resources it feeds, a one-row-per-resource summary that names its read-only
      and unmapped attributes, and then the section of every resource.

    The Mermaid renderers (`AshStrangler.Diagram.Mapping` and
    `AshStrangler.Diagram.Overview`) are still what the README and
    `mix ash_strangler.gen.diagram` use.

    Only offered where there is something to show: `applies?/2` is false for a
    resource with no `strangler` block, so this does not add an empty tab to
    every resource in an application where one table is being strangled.
    """

    @behaviour Clarity.Content

    alias AshStrangler.Diagram.Report
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
    def render_static(%Vertex.Application{app: app}, _lens),
      do: {:markdown, [app] |> strangled_in() |> Report.for_resources()}

    def render_static(%Domain{domain: domain}, _lens),
      do: {:markdown, domain |> resources() |> Report.for_resources()}

    def render_static(%Resource{resource: resource}, _lens),
      do: {:markdown, Report.for_resources([resource])}

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
