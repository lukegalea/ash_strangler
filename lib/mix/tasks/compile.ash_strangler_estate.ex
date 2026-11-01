# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.Compile.AshStranglerEstate do
  @shortdoc "Fails compilation when an estate leaves a legacy column unaccounted for"

  @moduledoc """
  Evaluates every configured `AshStrangler.Estate` after the Elixir compiler,
  and fails compilation on any problem, naming the relation or column.

  Enable it after the default compilers and list the estates:

      # mix.exs
      def project do
        [compilers: Mix.compilers() ++ [:ash_strangler_estate], ...]
      end

      # config/config.exs
      config :my_app, ash_strangler_estates: [MyApp.Legacy.Estate]

  It runs on every `mix compile`, because the checks read other modules'
  mappings: a check that ran only when the estate module itself recompiled
  would miss a mapping edited elsewhere. Evaluation reads the catalog and the
  compiled modules and touches no database.
  """

  use Mix.Task.Compiler

  alias Mix.Task.Compiler.Diagnostic

  @recursive true

  @impl Mix.Task.Compiler
  def run(_argv) do
    case Application.get_env(Mix.Project.config()[:app], :ash_strangler_estates, []) do
      [] ->
        {:noop, []}

      estates ->
        diagnostics = Enum.flat_map(estates, &diagnostics/1)
        Enum.each(diagnostics, &Mix.shell().error("#{&1.file}:#{&1.position}: #{&1.message}"))
        if diagnostics == [], do: {:ok, []}, else: {:error, diagnostics}
    end
  end

  @doc false
  @spec diagnostics(module()) :: [Diagnostic.t()]
  def diagnostics(estate) do
    if Code.ensure_loaded?(estate) and function_exported?(estate, :spark_dsl_config, 0) do
      file = estate.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
      lines = lines(estate)

      for problem <- AshStrangler.Estate.evaluate(estate).problems do
        diagnostic(
          file,
          Map.get(lines, problem.subject, lines[:estate]),
          "#{problem.check}: #{problem.message}"
        )
      end
    else
      [
        diagnostic(
          "mix.exs",
          0,
          "#{inspect(estate)} is configured as an estate but is not a compiled AshStrangler.Estate"
        )
      ]
    end
  end

  # Declaration lines, keyed by the id a problem names, so a diagnostic about
  # a declared column points at its declaration.
  defp lines(estate) do
    declared =
      for entity <- Spark.Dsl.Extension.get_entities(estate, [:estate]),
          anno = Spark.Dsl.Entity.anno(entity),
          into: %{} do
        {Map.get(entity, :id) || Map.get(entity, :relation), :erl_anno.line(anno)}
      end

    section =
      case Spark.Dsl.Extension.get_section_anno(estate, [:estate]) do
        nil -> 0
        anno -> :erl_anno.line(anno)
      end

    Map.put(declared, :estate, section)
  end

  defp diagnostic(file, line, message) do
    %Diagnostic{
      compiler_name: "ash_strangler_estate",
      file: file,
      position: line,
      message: message,
      severity: :error
    }
  end
end
