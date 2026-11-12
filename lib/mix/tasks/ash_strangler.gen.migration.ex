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
      mix ash_strangler.gen.migration --only MyApp.Visits,MyApp.Accounts.User

  ## Why this is not `mix ash.codegen`

  By itself, `mix ash.codegen` cannot write this DDL. A strangler resource's `table` names a view, so it must
  declare `migrate? false` — otherwise codegen emits a `create table` for that
  name and the view DDL then fails against it. But `migrate? false` also stops
  the migration generator producing a snapshot for the resource, and
  `custom_statements` are only read from snapshots. Both settings were tried:
  `true` collides, `false` discards.

  So the compatibility DDL gets its own task. This is the same position
  AshPostgres itself takes for view-backed resources — `mix
  ash_postgres.gen.resources --include-views` writes `migrate? false` beside a
  comment saying migrations for views are handled manually.

  ## Covering it from `mix ash.codegen`

  What `mix ash.codegen` can do is *notice* the layer. Attach `AshStrangler.Codegen` to the
  domain (`use Ash.Domain, extensions: [AshStrangler.Codegen]`) and `mix ash.codegen --check`
  fails in CI when the rendered DDL differs from the committed snapshots, while `mix ash.codegen
  <name>` writes a `<version>_<name>_strangler.exs` migration beside AshPostgres's own. This task
  stays available: when the domain attaches the extension, it refreshes the snapshots of the
  resources it writes, so the two ways of writing the DDL cannot disagree. See the
  [codegen guide](codegen.md).

  ## Regenerating is safe

  Re-running statements that have not changed is safe: they are `CREATE OR
  REPLACE` and `CREATE INDEX IF NOT EXISTS`, so regenerating after a mapping
  change leaves the unchanged parts as they were. A hand-edited migration is
  invisible to this task and will be contradicted by the next one.

  Regenerating after a **column was added** is additive too:

    * Every table the generator owns (a union's owned table, a union's or a
      resource's extension table) is followed by `ALTER TABLE ... ADD COLUMN IF
      NOT EXISTS` for each declared column, so a column declared after the table
      was created reaches it. A column declared `null?: false`, which has no
      default, cannot be added to a table that already holds rows: a guard
      statement refuses that with a message saying to add it nullable, backfill
      it and set `NOT NULL`. Rolling back never drops an added column, as it
      never drops rows.
    * A view whose column names are the installed ones plus new ones at the end
      is replaced in place, as before. A view whose columns changed shape (one
      inserted mid-list, renamed, removed or reordered) is dropped with a plain
      `DROP VIEW` and created again, and the `INSTEAD OF` triggers that follow
      it in the migration are re-created. There is no `CASCADE`: a view or
      function that depends on it makes the migration fail instead of being
      dropped. A grant on a dropped view is lost with it; re-grant after
      migrating. A column whose *type* changed is still refused by PostgreSQL.

  See "Changing a view's shape, in any phase" in the [phases guide](phases.md).

  ## Options

    * `--name` — migration name, defaulting to `add_strangler_compatibility`.
    * `--repo` — the repo whose `priv/` directory receives the file. Defaults to
      the first configured `ecto_repos` entry.
    * `--dry-run` — print the migration instead of writing it.
    * `--only` — comma-separated module names; render only those resources,
      unions or deriveds, for a reviewable migration of one mapping. An unknown
      name is an error.
  """

  use Mix.Task

  @switches [name: :string, repo: :string, dry_run: :boolean, only: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("compile")

    resources =
      case opts[:only] do
        nil ->
          AshStrangler.Migration.resources()

        only ->
          AshStrangler.Migration.only(AshStrangler.Migration.resources(), String.split(only, ","))
      end

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

      refresh_snapshots(resources)
    end
  end

  # A domain that attaches `AshStrangler.Codegen` has committed snapshots that
  # `mix ash.codegen --check` compares against. Writing the DDL here without
  # refreshing them would leave the two ways of writing it in disagreement, so
  # the resources this migration covers get their snapshots rewritten.
  defp refresh_snapshots(resources) do
    if AshStrangler.Codegen.attached?() do
      case AshStrangler.Codegen.write_snapshots!(resources: resources) do
        [] ->
          :ok

        paths ->
          Mix.shell().info(
            "Refreshed #{length(paths)} strangler snapshot(s): " <>
              Enum.map_join(paths, ", ", &Path.relative_to_cwd/1)
          )
      end
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

    Path.expand(Path.join(priv, "migrations"))
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
