# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Gen.Migration do
  @shortdoc "Generate the migration that builds the strangler compatibility layer"

  @moduledoc """
  Writes an Ecto migration containing the view, index and trigger DDL for every
  strangler-mapped resource.

      mix ash_strangler.gen.migration
      mix ash_strangler.gen.migration --name add_user_compatibility_view
      mix ash_strangler.gen.migration --dry-run

  ## Why this is not `mix ash.codegen`

  Because it cannot be. A strangler resource's `table` names a view, so it must
  declare `migrate? false` — otherwise codegen emits a `create table` for that
  name and the view DDL then fails against it. But `migrate? false` also stops
  the migration generator producing a snapshot for the resource, and
  `custom_statements` are only read from snapshots. Both settings were tried:
  `true` collides, `false` discards.

  So the compatibility DDL gets its own task. This is the same position
  AshPostgres itself takes for view-backed resources — `mix
  ash_postgres.gen.resources --include-views` writes `migrate? false` beside a
  comment saying migrations for views are handled manually.

  ## Regenerating is safe

  Every generated statement is idempotent (`CREATE OR REPLACE`,
  `CREATE INDEX IF NOT EXISTS`), so after changing a mapping you regenerate and
  run the new migration rather than hand-editing the old one. A hand-edited
  migration is invisible to this task and will be contradicted by the next one.

  ## Options

    * `--name` — migration name, defaulting to `add_strangler_compatibility`.
    * `--repo` — the repo whose `priv/` directory receives the file. Defaults to
      the first configured `ecto_repos` entry.
    * `--dry-run` — print the migration instead of writing it.
  """

  use Mix.Task

  @switches [name: :string, repo: :string, dry_run: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("compile")

    resources = AshStrangler.Migration.resources()

    if resources == [] do
      Mix.shell().info("No strangler-mapped resources found. Nothing to generate.")
    else
      generate(resources, opts)
    end
  end

  defp generate(resources, opts) do
    name = opts[:name] || "add_strangler_compatibility"
    module_name = "#{repo(opts) |> inspect()}.Migrations.#{Macro.camelize(name)}"
    source = AshStrangler.Migration.render(module_name, resources)

    if opts[:dry_run] do
      Mix.shell().info(source)
    else
      path = Path.join(migrations_path(opts), "#{timestamp()}_#{name}.exs")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)

      Mix.shell().info("""

      * creating #{path}

      Covers #{length(resources)} resource(s): #{Enum.map_join(resources, ", ", &inspect/1)}

      Review it, then run `mix ecto.migrate`.
      """)
    end
  end

  defp repo(opts) do
    case opts[:repo] do
      nil ->
        Application.get_env(Mix.Project.config()[:app], :ecto_repos, []) |> List.first() ||
          Mix.raise("No repo configured. Pass --repo.")

      repo ->
        Module.concat([repo])
    end
  end

  # Ecto's own convention: `:priv` from the repo config if set, otherwise
  # `priv/<repo_underscored>`, resolved against the PROJECT root.
  #
  # Not `Mix.Project.app_path/0` — that points inside `_build`, so a migration
  # written relative to it lands in build output, gets wiped by `mix clean`,
  # and is never committed.
  defp migrations_path(opts) do
    repo = repo(opts)
    priv = repo.config()[:priv] || Path.join("priv", repo_dir(repo))

    Path.join([File.cwd!(), priv, "migrations"])
  end

  defp repo_dir(repo) do
    repo |> Module.split() |> List.last() |> Macro.underscore()
  end

  # Same format Ecto uses, so generated files interleave correctly with
  # `mix ecto.gen.migration` output in the same directory.
  defp timestamp do
    %{year: y, month: m, day: d, hour: hh, minute: mm, second: ss} = DateTime.utc_now()

    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: to_string(i)
end
