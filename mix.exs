# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukegalea/ash_strangler"

  def project do
    [
      app: :ash_strangler,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      description:
        "Strangler-fig migrations for Ash: map an Ash resource onto a legacy Postgres schema " <>
          "and move it through the migration phases without hand-writing SQL.",
      package: package(),
      # Deferred on purpose. `docs/0` calls `Spark.Docs.search_data_for/1`, which
      # introspects the compiled extension -- evaluating it eagerly would run it
      # on every `mix` invocation, including the ones that have not compiled yet.
      docs: &docs/0,
      name: "AshStrangler",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        list_unused_filters: true
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # test/support carries the real-Postgres harness: the test repo, the legacy
  # fixture schema, and the mapped resources the round-trip tests read through.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.0"},
      # Optional deliberately. Step 1 is checks and verifiers, which reason about
      # the mapping rather than emitting SQL, so a consumer can adopt the
      # pre-flight tooling without this extension dragging a data layer into
      # their dependency tree. SQL generation (step 2) will need it.
      {:ash_postgres, "~> 2.0", optional: true},
      # Rides in transitively via `ash`, but the round-trip property tests
      # depend on it directly -- so it is declared directly. A transitive
      # dependency that a test suite leans on is one `mix deps.update` away
      # from disappearing.
      #
      # It cannot carry `only: [:dev, :test]`, tempting as that is: `ash`
      # requires it unconditionally (non-optional, all environments), and mix
      # rejects a narrower `:only` than a dependency's own dependents declare
      # with "dependencies have diverged".
      {:stream_data, "~> 1.0"},
      # Optional rather than dev-only, because `AshStrangler.Diagram.Mapping`
      # and `mix ash_strangler.gen.diagram` are built on it and a consumer has
      # to be able to reach them. Optional keeps it out of the dependency tree
      # of anyone who only wants the checks and the SQL: the diagram modules are
      # guarded with `Code.ensure_compiled/1` and are simply not compiled
      # without it, the same way `AshDiagram.Renderer.CLI` guards `:ex_cmd`.
      #
      # The README's diagrams are real generator output -- the mapping diagram,
      # the entity-relationship diagram of the modernised model and the state
      # machine chart -- rather than hand-drawn approximations of it, and a test
      # asserts they still match.
      {:ash_diagram, "~> 0.2", optional: true},
      {:ash_state_machine, "~> 0.2", only: [:dev, :test]},
      # Required by Spark.Formatter, which formats the DSL blocks.
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # The Ash CI workflow runs `mix igniter.upgrade` on dependabot pull
      # requests, and the ecosystem's installer convention (`mix igniter.install
      # ash_strangler`) is built on it.
      {:igniter, "~> 0.6", only: [:dev, :test]},
      # Backs the unconditional `mix deps.audit` step in the shared Ash CI
      # workflow's `audit` job.
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE LICENSE.license LICENSES
        usage-rules.md documentation),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Discord" => "https://discord.gg/HTHRaaVPUc",
        "Website" => "https://ash-hq.org",
        "Forum" => "https://elixirforum.com/c/elixir-framework-forums/ash-framework-forum",
        "REUSE Compliance" => "https://api.reuse.software/info/github.com/lukegalea/ash_strangler"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: "GUIDES",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/how-it-works.md",
        "documentation/topics/the-transform-layer.md",
        "documentation/topics/phases.md",
        "documentation/topics/what-it-refuses.md",
        "documentation/topics/backfill-and-reconciliation.md",
        "documentation/topics/notifications.md",
        "usage-rules.md",
        {"documentation/dsls/DSL-AshStrangler.Resource.md",
         search_data: Spark.Docs.search_data_for(AshStrangler.Resource)},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Tutorials: ~r'documentation/tutorials',
        "How To": ~r'documentation/how_to',
        Topics: ~r'documentation/topics',
        DSLs: ~r'documentation/dsls',
        "About AshStrangler": [
          "CHANGELOG.md",
          "usage-rules.md"
        ]
      ],
      groups_for_modules: [
        Dsl: [
          AshStrangler.Resource,
          AshStrangler.Twin
        ],
        "The transform layer": [
          AshStrangler.Lens,
          AshStrangler.Obligations,
          AshStrangler.Mechanism,
          AshStrangler.Sql.Printer,
          AshStrangler.Expr
        ],
        Introspection: [
          AshStrangler.Info
        ],
        Lineage: [
          AshStrangler.Lineage,
          AshStrangler.Diagram.Mapping,
          AshStrangler.Diagram.Overview,
          AshStrangler.Lineage.OpenLineage
        ],
        Internals: ~r/.*/
      ],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  # ex_doc has no built-in Mermaid support and never has -- it is documentation
  # only, and the script below is what its README tells you to inject. Without
  # it every diagram in this project renders on HexDocs as a wall of raw
  # `flowchart LR` source, which is worse than no diagram.
  #
  # `startOnLoad: false` with an explicit render pass, rather than the simpler
  # `startOnLoad: true`, because ex_doc is a single-page application: the
  # `exdoc:loaded` event fires again on navigation, and the one-shot version
  # leaves every page after the first unrendered.
  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11.12.0/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_format), do: ""

  defp aliases do
    [
      credo: "credo --strict",
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links"
      ],
      "spark.formatter": "spark.formatter --extensions AshStrangler.Resource",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshStrangler.Resource"
    ]
  end
end
