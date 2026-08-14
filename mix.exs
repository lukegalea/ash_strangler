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
          AshStrangler.Resource
        ],
        Introspection: [
          AshStrangler.Info
        ],
        Internals: ~r/.*/
      ]
    ]
  end

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
