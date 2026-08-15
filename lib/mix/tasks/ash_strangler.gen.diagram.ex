# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Gen.Diagram do
  @shortdoc "Generates Mermaid diagrams of the legacy-to-new mapping"

  @moduledoc """
  Renders the `strangler` mapping as a diagram, one per resource.

      mix ash_strangler.gen.diagram
      mix ash_strangler.gen.diagram --type overview
      mix ash_strangler.gen.diagram --only MyApp.Sales.Customer --format md
      mix ash_strangler.gen.diagram --format svg --output diagrams/

  ## Why a picture

  The mapping is the one part of a strangler migration that everybody has to
  agree about and nobody can hold in their head: which legacy columns feed which
  attribute, which of them travel back, and which are read-only and why. It is
  already declared in one place, so it can be drawn from that declaration rather
  than maintained alongside it — and a drawing that is generated cannot drift
  from the mapping the way one in a wiki does.

  ## Prerequisites

  The `plain` and `md` formats need nothing. `svg`, `pdf` and `png` are rendered
  by `AshDiagram`, which needs either the Mermaid CLI (`mmdc`, with the optional
  `:ex_cmd` dependency) or the `mermaid.ink` service (with `:req`).

  This task also needs the optional `:ash_diagram` dependency itself:

      {:ash_diagram, "~> 0.2", only: [:dev, :test], runtime: false}

  ## Options

    * `--type` — `mapping` (the default) draws one column-level diagram per
      resource. `overview` draws a single diagram of which relations feed which
      resources, which is the one that stays readable for a whole application.
    * `--domain` — only consider resources in this domain.
    * `--only` — only generate for this resource. Repeatable. Accepts a module
      name (`MyApp.Sales.Customer`) or the path to its source file.
    * `--format` — one of:
      * `plain` — writes the Mermaid source as `.mmd`. The default.
      * `md` — writes the Mermaid source in a Markdown code fence.
      * `svg`, `pdf`, `png` — renders the diagram.
    * `--output` — the directory to write into. Defaults to writing beside each
      resource's own source file, which is where `mix ash.generate_resource_diagrams`
      puts its output too.
    * `--verbose` — draw every plain 1:1 mapping individually instead of
      collapsing them into one node. Off by default: a rename is not a
      transformation, and drawing a dozen of them buries the mappings that are.
  """

  use Mix.Task

  @recursive true

  @switches [
    type: :string,
    domain: :string,
    only: :keep,
    format: :string,
    output: :string,
    verbose: :boolean
  ]

  @aliases [t: :type, d: :domain, o: :only, f: :format]

  @formats ~w(plain md svg pdf png)
  @types ~w(mapping overview)

  @impl Mix.Task
  @doc @shortdoc
  def run(argv) do
    Mix.Task.run("compile")

    {opts, _} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    with :ok <- ensure_ash_diagram(),
         {:ok, type} <- validate(opts[:type] || "mapping", @types, "type"),
         {:ok, format} <- validate(opts[:format] || "plain", @formats, "format") do
      case resources(opts) do
        [] -> Mix.shell().info("No strangler-mapped resources found. Nothing to generate.")
        resources -> generate(type, resources, format, opts)
      end
    else
      {:error, message} -> Mix.shell().error(message)
    end
  end

  # --- selection --------------------------------------------------------

  defp resources(opts) do
    opts
    |> domains()
    |> AshStrangler.Migration.resources()
    |> filter_only(Keyword.get_values(opts, :only))
    |> Enum.sort_by(&inspect/1)
  end

  defp domains(opts) do
    case opts[:domain] do
      nil -> nil
      name -> Enum.filter(all_domains(), &(inspect(&1) == name))
    end
  end

  defp all_domains do
    Application.get_env(:ash, :ash_domains, []) ++
      Enum.flat_map(Application.loaded_applications(), fn {app, _, _} ->
        Application.get_env(app, :ash_domains, [])
      end)
  end

  # A module name is what somebody reaching for a single resource actually has
  # in hand; a source path is what `mix ash.generate_resource_diagrams` accepts.
  # Both work, because refusing one of them would only be a rule to remember.
  defp filter_only(resources, []), do: resources

  defp filter_only(resources, only) do
    Enum.filter(resources, fn resource ->
      Enum.any?(only, fn selector ->
        inspect(resource) == selector or source_file(resource) == Path.expand(selector)
      end)
    end)
  end

  # --- generation -------------------------------------------------------

  defp generate("overview", resources, format, opts) do
    diagram = AshStrangler.Diagram.Overview.for_resources(resources)
    path = output_path(opts, hd(resources), "strangler-overview", format)

    write(path, diagram, format)
    report(path, "overview of #{length(resources)} resource(s)")
  end

  defp generate("mapping", resources, format, opts) do
    for resource <- resources do
      diagram =
        AshStrangler.Diagram.Mapping.for_resources([resource],
          verbose?: opts[:verbose] || false
        )

      path = output_path(opts, resource, "#{module_slug(resource)}-strangler-mapping", format)

      write(path, diagram, format)
      report(path, inspect(resource))
    end
  end

  # Named for the resource rather than for its source file, because several
  # resources routinely share one file -- three views over one wide legacy table
  # is the case this package exists for -- and naming by file would have them
  # silently overwrite each other.
  defp module_slug(resource) do
    resource
    |> inspect()
    |> Macro.underscore()
    |> String.replace("/", "_")
  end

  defp write(path, diagram, format) when format in ["plain", "md"] do
    contents =
      case format do
        "plain" -> AshDiagram.compose(diagram)
        "md" -> AshDiagram.compose_markdown(diagram)
      end

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, contents)
  end

  defp write(path, diagram, format) do
    rendered = AshDiagram.render(diagram, format: render_format(format))

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, rendered)
  rescue
    # Broad on purpose. Rendering runs an external program or an HTTP service,
    # and every way that fails -- missing binary, no renderer configured, the
    # service unreachable -- should produce the same next step rather than a
    # stack trace through somebody else's HTTP client.
    error ->
      Mix.shell().error("""
      Could not render #{format}: #{Exception.message(error)}

      Rendering needs either the Mermaid CLI:

          npm install -g @mermaid-js/mermaid-cli

      with the optional `:ex_cmd` dependency, or the `mermaid.ink` service with
      the optional `:req` dependency. `--format plain` and `--format md` need
      neither.
      """)
  end

  defp report(path, what), do: Mix.shell().info("* creating #{path} (#{what})")

  defp output_path(opts, resource, basename, format) do
    directory = opts[:output] || resource |> source_file() |> Path.dirname()

    Path.join(directory, "#{basename}.#{extension(format)}")
  end

  defp extension("plain"), do: "mmd"
  defp extension(format), do: format

  # Spelled out rather than `String.to_existing_atom/1`, which raises unless
  # something else in the release happens to have interned the atom already --
  # and nothing does, so `--format svg` died on its own success path.
  defp render_format("svg"), do: :svg
  defp render_format("pdf"), do: :pdf
  defp render_format("png"), do: :png

  defp source_file(resource) do
    resource.module_info(:compile)[:source] |> to_string() |> Path.expand()
  end

  # --- validation -------------------------------------------------------

  defp validate(value, allowed, what) do
    if value in allowed do
      {:ok, value}
    else
      {:error,
       "Invalid #{what} `#{value}`.\n\nValid options are #{Enum.map_join(allowed, ", ", &"`#{&1}`")}."}
    end
  end

  defp ensure_ash_diagram do
    case Code.ensure_compiled(AshStrangler.Diagram.Mapping) do
      {:module, _} ->
        :ok

      _ ->
        {:error,
         """
         This task needs the optional `:ash_diagram` dependency.

         Add it to your `mix.exs`:

             {:ash_diagram, "~> 0.2", only: [:dev, :test], runtime: false}

         then `mix deps.get`.
         """}
    end
  end
end
