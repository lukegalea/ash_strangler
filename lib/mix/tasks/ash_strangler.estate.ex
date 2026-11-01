# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Estate do
  @shortdoc "Evaluates estates and exports the estate manifest"

  @moduledoc """
  Evaluates one or more `AshStrangler.Estate` modules, prints every problem and
  exits 1 if there are any.

      mix ash_strangler.estate
      mix ash_strangler.estate MyApp.Legacy.Estate --manifest priv/legacy/estate-manifest.json

  With no estate named, evaluates the application's `:ash_strangler_estates`.

  ## Options

    * `--manifest FILE` — write the estate manifest (`AshStrangler.Estate.manifest/1`)
      as canonical JSON. Needs exactly one estate. Written even when there are
      problems; they are part of the manifest.
  """

  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [manifest: :string])
    estates = estates(args)

    if opts[:manifest] && length(estates) != 1 do
      Mix.raise("--manifest needs exactly one estate, got #{length(estates)}")
    end

    reports = Enum.map(estates, &AshStrangler.Estate.evaluate/1)

    if path = opts[:manifest] do
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        reports
        |> hd()
        |> AshStrangler.Estate.manifest()
        |> AshStrangler.Snapshot.Catalog.encode()
      )
    end

    problems =
      for report <- reports, problem <- report.problems do
        Mix.shell().error("#{inspect(report.estate)}: #{problem.check}: #{problem.message}")
        problem
      end

    if problems == [] do
      Enum.each(
        reports,
        &Mix.shell().info("#{inspect(&1.estate)}: every relation and column accounted for")
      )
    else
      exit({:shutdown, 1})
    end
  end

  defp estates([]) do
    case Application.get_env(Mix.Project.config()[:app], :ash_strangler_estates, []) do
      [] -> Mix.raise("No estate named and no :ash_strangler_estates configured")
      estates -> estates
    end
  end

  defp estates(names) do
    for name <- names do
      module = Module.concat([name])

      unless Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) do
        Mix.raise("#{name} is not a compiled AshStrangler.Estate")
      end

      module
    end
  end
end
