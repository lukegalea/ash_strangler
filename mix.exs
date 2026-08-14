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
      deps: deps(),
      description:
        "Strangler-fig migrations for Ash: map an Ash resource onto a legacy Postgres schema " <>
          "and move it through the migration phases without hand-writing SQL.",
      package: package(),
      docs: docs(),
      name: "AshStrangler",
      source_url: @source_url,
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "usage-rules.md"],
      source_ref: "v#{@version}"
    ]
  end
end
