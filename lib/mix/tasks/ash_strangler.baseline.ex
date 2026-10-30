# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Baseline do
  @shortdoc "Snapshots a resource through the forward mapping at watch start"

  @moduledoc """
  Wraps `AshStrangler.Observation.Baseline.run/2`: a REPEATABLE READ
  snapshot of the legacy relation projected through the forward mapping,
  stamped with one baseline_group and the current mapping version.

      mix ash_strangler.baseline MyApp.Clm.Contract --repo MyApp.Repo

  Requires the resource to carry `ledger? true` — the ledger trigger is what
  makes the snapshot/stream handoff lossless. The baseline is idempotent per
  `(record_id, resource, baseline_group)`; re-run with the same `--group` to
  count zero.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [repo: :string, group: :string]

  @impl Mix.Task
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches)

    resource =
      case args do
        [resource] -> Module.concat([resource])
        _ -> Mix.raise("usage: mix ash_strangler.baseline <Resource> --repo <Repo>")
      end

    repo =
      Keyword.get(opts, :repo)
      |> case do
        nil -> repo_for(resource)
        name -> Module.concat([name])
      end

    {:ok, _} = repo.start_link([])

    run_opts =
      [repo: repo] ++ if(opts[:group], do: [group: Ecto.UUID.cast!(opts[:group])], else: [])

    case AshStrangler.Observation.Baseline.run(resource, run_opts) do
      {:ok, %{group: group, count: count}} ->
        Mix.shell().info("baseline #{group}: #{count} observation(s) for #{inspect(resource)}")

      {:error, :no_ledger} ->
        Mix.raise(
          "#{inspect(resource)} has no `ledger? true` -- a baseline without the ledger trigger loses everything committed after the snapshot"
        )

      {:error, reason} ->
        Mix.raise("baseline failed: #{inspect(reason)}")
    end
  end

  defp repo_for(resource) do
    AshPostgres.DataLayer.Info.repo(resource)
  end
end
