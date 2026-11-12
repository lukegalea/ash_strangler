# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Codegen do
  @moduledoc """
  Makes `mix ash.codegen` cover the strangler compatibility layer.

  The view, key index and ledger DDL for the legacy estate comes from
  `AshStrangler.Migration`, not from AshPostgres: a strangled resource declares
  `migrate? false` (its `table` names the compatibility *view*, and codegen
  would emit a `create table` for that name), and with `migrate? false` there
  is no resource snapshot for `custom_statements` to hang off either. That is
  why `mix ash_strangler.gen.migration` is its own task — and it is why the CI
  gate, `mix ash.codegen --check`, is blind to the layer: a mapping change that
  leaves the installed DDL stale is only caught later, by `mix
  ash_strangler.check --strict` against a database.

  This extension exports `codegen/1`, the callback `mix ash.codegen` calls on
  every extension in use. It renders the current statements **from compiled
  resources, with no database** (`AshStrangler.Migration.statements/1`, the
  same function the generator task writes migrations from) and compares them,
  statement for statement, against a committed snapshot of what the newest
  installed strangler migration contains. See `pending/1` for the comparison.

  ## Opt-in by attachment

  Attach the extension to the domain whose strangled resources it should
  cover:

      use Ash.Domain, extensions: [AshStrangler.Codegen]

  `mix ash.codegen` runs every extension defined in every dependency that
  depends on ash, attached or not — so this module runs in every host that
  depends on `ash_strangler`. It therefore does nothing beyond one `info` line
  unless at least one domain in the application's `:ash_domains` attaches it,
  and it covers only the resources of attaching domains (plus the unions and
  deriveds in `config :ash_strangler`, which are application-wide). A host
  that upgrades without attaching sees no change.

  ## Flags

  Flags of *other* extensions flow through `codegen/1` too; the ones this hook
  acts on:

    * `--check` — when a snapshot is stale or missing, reports each affected
      resource by name and raises `Ash.Error.Framework.PendingCodegen` (the
      same exception AshPostgres raises, so the task's handling — and the
      "Pending Code Generation Detected" message — is unchanged).
    * `--dry-run` — prints the pending statements.
    * `<name>` — writes `priv/<repo>/migrations/<timestamp>_<name>_strangler.exs`
      and refreshes the snapshots. The timestamp is allocated strictly after
      the newest file already in the migrations directory and strictly after
      AshPostgres's own in-process counter, so it cannot land on the version
      AshPostgres writes in the same run, whichever extension runs first. The
      `_strangler` suffix also keeps the migration recognizably the strangler
      layer's own, in a directory AshPostgres writes too.
    * `--snapshots-only` — writes the snapshots and no migration. That is how
      an existing host seeds the snapshots before adopting the extension.
    * `--dev` — refused while anything is pending, and a no-op when clean; see
      "Why there is no `--dev`" below.

  ## Why there is no `--dev`

  AshPostgres's dev mode exists so its final named run can roll the dev
  migrations back and squash them against resource snapshots. The strangler
  layer has no snapshots to squash and its statements are idempotent
  (`CREATE OR REPLACE`, `IF NOT EXISTS`), so a dev-suffixed migration would
  only add a second name for DDL the final run rewrites, plus a
  `schema_migrations` row orphaned when the final file replaces the dev one.
  During development run `mix ash.codegen <name>` directly. The refusal only
  fires when strangler statements are actually pending: an iteration that
  changed nothing in the mapping still passes through.

  ## Where the snapshots live, and what they record

  `priv/strangler_snapshots/<repo underscored>/<underscored resource>.json`,
  one file per rendered resource, because a stale mapping is reported by name
  and per-file diffs are reviewable. Each file records the `name` and `up` of
  every statement the renderer produces for that resource — what the newest
  installed strangler DDL contains, as proven when the host seeded it.
  `down` is not recorded: the renderer derives it from `up`, so it can never
  disagree. Statements are compared in position order, including the view
  reshape guard: the snapshot records what the renderer produces now, not
  what a migration file once contained, and the guard's `up` embeds the view's
  expected column list, so it changes whenever the view changes shape.

  ## More than one repo

  Covered resources are grouped by the repo their `AshPostgres.DataLayer`
  declares, and each group gets its own migration in that repo's `priv`
  directory and its own snapshot directory — a migration is executed by one
  repo, so DDL for another repo's schemas does not belong in it. Resources
  that declare no repo fall back to the application's first `ecto_repos`
  entry.

  ## Configuration

      config :ash_strangler, AshStrangler.Codegen,
        snapshot_root: "priv/strangler_snapshots",
        migration_suffix: "strangler"

  `snapshot_root` replaces the base directory; the repo subdirectory and the
  `<resource>.json` name are appended to whatever base is configured.
  `migration_suffix` replaces the `_strangler` filename suffix.

  The extension declares no DSL sections. It is attached to a domain so its
  intent — the strangler layer is part of that domain's contract — is visible
  where the strangled resources are declared.
  """

  use Spark.Dsl.Extension

  @behaviour Ash.Extension

  @default_migration_suffix "strangler"
  @default_snapshot_root "priv/strangler_snapshots"

  @doc """
  Called by `mix ash.codegen`, which appends `--name <name-or-nil>` to its own
  arguments before handing them to every extension.

  Other extensions' flags (`--snapshots-only`, `--no-format`, ...) flow
  through here too; the ones that matter to this hook are parsed below. An
  application whose domains do not attach this extension gets one `info` line
  and nothing else.
  """
  @impl Ash.Extension
  def codegen(argv) do
    {opts, _invalid, _positional} =
      OptionParser.parse(argv,
        strict: [
          name: :string,
          check: :boolean,
          dry_run: :boolean,
          dev: :boolean,
          snapshots_only: :boolean
        ]
      )

    if attached?() do
      cond do
        opts[:dev] -> dev()
        opts[:check] -> check()
        opts[:dry_run] -> dry_run()
        opts[:snapshots_only] -> snapshots_only()
        true -> generate(name!(opts[:name]))
      end
    else
      Mix.shell().info(
        "Strangler compatibility layer: no domain attaches AshStrangler.Codegen; skipping."
      )
    end
  end

  @doc """
  Every resource this extension covers for the current application, mapped to
  its current statements (`%{name: atom, up: binary, down: binary}`, exactly
  what `mix ash_strangler.gen.migration` writes migrations from). No database
  is involved.

  A resource is covered when a domain in the application's `:ash_domains`
  attaches this extension and lists the resource, or when it is named in
  `config :ash_strangler, unions:` / `deriveds:` while any domain attaches.
  An application whose domains do not attach this extension renders nothing.
  """
  @spec rendered() :: %{
          optional(module()) => [
            %{
              required(:name) => atom(),
              required(:up) => String.t(),
              required(:down) => String.t()
            }
          ]
        }
  def rendered do
    Map.new(covered_resources(), fn resource ->
      {resource, AshStrangler.Migration.statements(resource)}
    end)
  end

  @doc """
  Every covered resource whose statements disagree with its snapshot, or that
  has no snapshot yet: rendered statements against a snapshot directory, so the
  comparison lives here rather than in hosts.

  Each entry is a map with the resource, its snapshot path, a `:status` of
  `:missing | :invalid | :changed`, a human summary of the difference, and the
  pending statements — the current render of what the next migration has to
  carry (statements that only disappeared from the render are listed in the summary, not here, because a removal is carried by nothing).

  Options:

    * `:snapshot_root` — where snapshots are read from; defaults to
      `priv/strangler_snapshots` under the project root, one subdirectory per
      repo.
  """
  @spec pending(keyword()) :: [
          %{
            resource: module(),
            snapshot_path: String.t(),
            status: :missing | :invalid | :changed,
            summary: String.t(),
            pending: [{String.t(), String.t()}]
          }
        ]
  def pending(opts \\ []) do
    root = opts[:snapshot_root] || snapshot_root()

    rendered()
    |> Enum.map(fn {resource, statements} -> compare(root, resource, statements) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "The subset of `resources` this extension covers."
  @spec covered_resources([module()]) :: [module()]
  def covered_resources(resources) do
    Enum.filter(resources, &covered?(&1))
  end

  @doc """
  Every resource this extension covers for the current application. See
  `rendered/0` for what that means.
  """
  @spec covered_resources() :: [module()]
  def covered_resources do
    ensure_app_config()

    app = Mix.Project.config()[:app]

    case attached_domains(Application.get_env(app, :ash_domains, [])) do
      [] -> []
      attached -> AshStrangler.Migration.resources(attached)
    end
  end

  @doc "Whether any domain in the application's `:ash_domains` attaches this extension."
  @spec attached?() :: boolean()
  def attached? do
    ensure_app_config()

    app = Mix.Project.config()[:app]
    attached_domains(Application.get_env(app, :ash_domains, [])) != []
  end

  @doc """
  The application's domains, among `domains`, that attach this extension.
  """
  @spec attached_domains([module()]) :: [module()]
  def attached_domains(domains) do
    Enum.filter(domains, fn domain ->
      Code.ensure_loaded?(domain) and __MODULE__ in Spark.extensions(domain)
    end)
  end

  @doc "Whether `resource` is covered by this extension. See `rendered/0`."
  @spec covered?(module()) :: boolean()
  def covered?(resource) do
    attached?() and resource in covered_resources()
  end

  @doc "Where `resource`'s snapshot lives under base `root`."
  @spec snapshot_path(String.t(), module()) :: String.t()
  def snapshot_path(root, resource) do
    Path.join([root, repo_dir(repo_for(resource)), key(resource)]) <> ".json"
  end

  @doc "Where `resource`'s snapshot lives for this project."
  @spec snapshot_path(module()) :: String.t()
  def snapshot_path(resource), do: snapshot_path(snapshot_root(), resource)

  @doc """
  Writes every covered resource's current statements to its snapshot file, and
  returns the paths written.

  Options:

    * `:snapshot_root` — where snapshots are written; see `pending/1`.
    * `:resources` — restrict the write to these resources, dropping the ones
      this extension does not cover. `mix ash_strangler.gen.migration` passes
      the resources its migration covers, so an application can adopt `mix
      ash.codegen` one mapping at a time.

  Called by `mix ash.codegen <name>` after it writes the migration those
  statements belong in, and once by hand (`--snapshots-only`) to seed the
  initial snapshots.
  """
  # Paths here come from compiled resource module names and the project's own
  # priv/ directory — never from request or user input — so Sobelow's
  # low-confidence Traversal findings on the File calls are false positives.
  # sobelow_skip ["Traversal.FileModule"]
  @spec write_snapshots!(keyword()) :: [String.t()]
  def write_snapshots!(opts \\ []) do
    resources =
      case Keyword.fetch(opts, :resources) do
        {:ok, given} -> covered_resources(List.wrap(given))
        :error -> covered_resources()
      end

    root = opts[:snapshot_root] || snapshot_root()

    for resource <- Enum.sort(resources) do
      path = snapshot_path(root, resource)
      File.mkdir_p!(Path.dirname(path))

      doc = %{
        "resource" => inspect(resource),
        "statements" =>
          Enum.map(normalize(AshStrangler.Migration.statements(resource)), fn {name, up} ->
            %{"name" => name, "up" => up}
          end)
      }

      File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")
      path
    end
  end

  @doc """
  A migration version for a new strangler migration: strictly greater than
  every version already in `dir`, strictly greater than the current second,
  and strictly greater than AshPostgres's last allocated version when this
  process has seen one.

  AshPostgres's generator takes "the current second" and protects only against
  itself, through the `:ash_postgres_last_migration_timestamp` **process key**
  — undocumented, and the only handshake between the two generators. If
  AshPostgres renames the key, this extension can no longer see what it
  allocated, and a collision becomes possible when *this* extension runs
  first: our version would land on the same second AshPostgres then picks.
  The directory scan still covers the other direction — this extension
  running second always lands strictly after AshPostgres's file. Publishing
  our version into the same counter covers the first case today, because it
  is the mechanism AshPostgres itself uses between its own writes.
  """
  @spec next_migration_version(String.t()) :: String.t()
  def next_migration_version(dir) do
    now = utc_now_version()

    from_files =
      case newest_version(dir) do
        0 -> []
        newest -> [bump(Integer.to_string(newest))]
      end

    from_counter =
      case Process.get(:ash_postgres_last_migration_timestamp) do
        nil -> []
        last -> [bump(last)]
      end

    version = Enum.max([now | from_files ++ from_counter])
    Process.put(:ash_postgres_last_migration_timestamp, version)
    version
  end

  # -- the codegen modes -------------------------------------------------------

  defp check do
    case pending() do
      [] ->
        :ok

      pending ->
        Mix.shell().error(pending_report(pending))

        raise Ash.Error.Framework.PendingCodegen,
          diff: Enum.map(pending, &{&1.snapshot_path, &1.summary})
    end
  end

  defp dry_run do
    case pending() do
      [] ->
        Mix.shell().info("Strangler compatibility layer is up to date.")

      pending ->
        Mix.shell().info(dry_run_report(pending))
    end
  end

  defp dev do
    case pending() do
      [] ->
        Mix.shell().info("Strangler compatibility layer is up to date; --dev is a no-op for it.")

      pending ->
        Mix.shell().error(pending_report(pending))
        Mix.raise(dev_refusal())
    end
  end

  defp snapshots_only do
    paths = write_snapshots!()

    Mix.shell().info(
      "Wrote #{length(paths)} strangler snapshot(s) under #{relative(snapshot_root())}."
    )
  end

  defp generate(name) do
    case pending() do
      [] ->
        Mix.shell().info("Strangler compatibility layer is up to date; no migration written.")

      pending ->
        paths =
          repo_groups()
          |> Enum.map(fn {repo, resources} -> write_migration!(repo, resources, name) end)

        write_snapshots!()

        case pending() do
          [] ->
            Mix.shell().info("""

            Covers #{length(pending)} resource(s): #{Enum.map_join(pending, ", ", &inspect(&1.resource))}

            Review #{Enum.map_join(paths, " and ", &relative/1)}, then run `mix ecto.migrate` for each repo.
            """)

          still ->
            Mix.raise(
              "wrote #{Enum.join(paths, ", ")} and refreshed the snapshots, but these still differ: " <>
                Enum.map_join(still, ", ", &inspect(&1.resource))
            )
        end
    end
  end

  # One migration per repo: a migration is executed by one repo, so DDL for
  # another repo's schemas does not belong in it. The migration carries the
  # FULL current render of its group, not only the pending statements — every
  # statement is idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`), so
  # re-running the unchanged parts is safe and the file always describes the
  # whole layer for that repo.
  defp repo_groups do
    default = default_repo!()

    covered_resources()
    |> Enum.map(&{repo_for(&1, default), &1})
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {repo, _resources} -> inspect(repo) end)
  end

  # The directory is the repo's own priv/migrations and the name comes from the
  # developer's own command line, not from request input; see write_snapshots!/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_migration!(repo, resources, name) do
    dir = migrations_path(repo)
    version = next_migration_version(dir)
    suffix = migration_suffix()

    module_name = "#{inspect(repo)}.Migrations.#{Macro.camelize("#{name}_#{suffix}")}"
    source = AshStrangler.Migration.render(module_name, resources)

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{version}_#{name}_#{suffix}.exs")
    Mix.Generator.create_file(path, source, force: true)
    path
  end

  defp name!(name) do
    if is_binary(name) and name != "" do
      name
    else
      Mix.raise("""
      Name must be provided when generating a strangler migration, unless `--check`, `--dry-run`, `--snapshots-only` or `--dev` is also provided.

      Please provide a name, for example:

          mix ash.codegen <name>
      """)
    end
  end

  defp dev_refusal do
    """
    ash_strangler's compatibility layer has no `--dev` mode.

    AshPostgres uses `--dev` so its final named run can roll the dev migrations back and
    squash them against resource snapshots. The strangler layer has no snapshots to squash
    and its statements are idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`), so a dev
    migration would only add a second name for DDL the final run rewrites, plus a
    `schema_migrations` row orphaned when the dev file is replaced.

    Run `mix ash.codegen <name>` instead: it writes the strangler migration and refreshes
    the snapshots in the same run. AshPostgres's own dev files, if any were written before
    this refusal, are unaffected.
    """
  end

  # -- comparison --------------------------------------------------------------

  defp compare(root, resource, statements) do
    path = snapshot_path(root, resource)
    current = normalize(statements)

    case read_snapshot(path) do
      {:ok, stored} ->
        if stored == current do
          nil
        else
          {summary, pending} = diff(stored, current)
          entry(resource, path, :changed, summary, pending)
        end

      {:error, :missing} ->
        entry(resource, path, :missing, "no snapshot yet", current)

      {:error, reason} ->
        entry(resource, path, :invalid, "unreadable snapshot: #{reason}", current)
    end
  end

  defp entry(resource, path, status, summary, pending) do
    %{
      resource: resource,
      snapshot_path: path,
      status: status,
      summary: summary,
      pending: pending
    }
  end

  # Reads only the committed snapshot files under the project root; see
  # write_snapshots!/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_snapshot(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, "cannot read: #{inspect(reason)}"}

      {:ok, body} ->
        case decode_snapshot(body) do
          {:ok, statements} -> {:ok, statements}
          :error -> {:error, "expected {\"resource\", \"statements\": [{\"name\", \"up\"}]}"}
        end
    end
  end

  defp decode_snapshot(body) do
    with {:ok, %{"statements" => statements}} <- Jason.decode(body),
         statements when is_list(statements) <- statements,
         true <-
           Enum.all?(
             statements,
             &match?(%{"name" => n, "up" => u} when is_binary(n) and is_binary(u), &1)
           ) do
      {:ok, Enum.map(statements, &{&1["name"], &1["up"]})}
    else
      _ -> :error
    end
  end

  # Statements are compared positionally: the order is the dependency order the
  # renderer guarantees (schema, extension table, view, reshape guard, index,
  # triggers, ledger), so a reorder is drift the same way a changed body is.
  # The snapshot records what the renderer produces NOW, not what a migration
  # file once contained — that is why even the view reshape guard, whose `up`
  # embeds the expected column list and therefore changes whenever the view
  # changes shape, is compared statement for statement.
  defp diff(stored, current) do
    zipped = Enum.zip(stored, current)

    changed =
      for {{stored_name, stored_up}, {current_name, current_up}} <- zipped,
          stored_name != current_name or stored_up != current_up do
        {current_name, current_up}
      end

    added = Enum.drop(current, length(stored))
    removed = max(length(stored) - length(current), 0)

    summary =
      [
        if(changed == [],
          do: nil,
          else: "changed: #{Enum.map_join(changed, ", ", &elem(&1, 0))}"
        ),
        if(added == [], do: nil, else: "added: #{Enum.map_join(added, ", ", &elem(&1, 0))}"),
        if(removed == 0, do: nil, else: "removed: #{removed}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    {summary, changed ++ added}
  end

  defp normalize(statements) do
    Enum.map(statements, fn statement ->
      {to_string(statement.name), String.trim_trailing(statement.up)}
    end)
  end

  # -- reporting ---------------------------------------------------------------

  defp pending_report(pending) do
    Enum.map_join(pending, "\n\n", fn entry ->
      """

      Pending strangler compatibility DDL for #{inspect(entry.resource)}: #{entry.summary}
      snapshot: #{relative(entry.snapshot_path)}
      """
    end) <>
      """

      Run `mix ash.codegen <name>` to write the migration and refresh the snapshots,
      or `mix ash.codegen --dry-run` to see the pending statements.
      """
  end

  defp dry_run_report(pending) do
    Enum.map_join(pending, "\n\n", fn entry ->
      body =
        Enum.map_join(entry.pending, "\n", fn {name, up} ->
          String.trim_trailing("""
          -- #{name}
          #{up}
          """)
        end)

      String.trim_trailing("""
      #{inspect(entry.resource)}: #{entry.summary}
      #{body}
      """)
    end)
  end

  defp relative(path) do
    Path.relative_to(path, File.cwd!())
  rescue
    _ -> path
  end

  # -- paths and discovery -----------------------------------------------------

  # `mix ash.codegen` runs `compile` but not `app.config`, and the order the
  # extensions run in is not guaranteed — AshPostgres may not have loaded the
  # host's config yet. Reading `:ash_domains`, `:ecto_repos`, the unions and
  # deriveds, and this module's own config all need it.
  defp ensure_app_config do
    if Code.ensure_loaded?(Mix.Task) and Code.ensure_loaded?(Mix.Project) and
         Mix.Project.get() do
      Mix.Task.run("app.config")
    end

    :ok
  end

  defp repo_for(resource) do
    repo_for(resource, default_repo!())
  end

  defp repo_for(resource, default) do
    if Code.ensure_loaded?(AshPostgres.DataLayer.Info) do
      case AshPostgres.DataLayer.Info.repo(resource, :mutate) do
        repo when is_atom(repo) and not is_nil(repo) -> repo
        _ -> default
      end
    else
      default
    end
  end

  # The repo a migration (and its snapshot directory) belongs to. Strangled
  # resources, unions and deriveds all declare a repo through
  # `AshPostgres.DataLayer`; the app's first `ecto_repos` entry is the fallback
  # for anything that does not.
  defp default_repo! do
    ensure_app_config()
    app = Mix.Project.config()[:app]

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] ->
        Module.concat([repo])

      [] ->
        Mix.raise(
          "no ecto_repos configured for #{inspect(app)}; cannot place the strangler migration " <>
            "or its snapshots"
        )
    end
  end

  # Ecto's own convention: `:priv` from the repo config if set, otherwise
  # `priv/<repo_underscored>`, resolved against the PROJECT root.
  #
  # Not `Mix.Project.app_path/0` — that points inside `_build`, so a migration
  # written relative to it lands in build output, gets wiped by `mix clean`,
  # and is never committed.
  defp migrations_path(repo) do
    priv = repo.config()[:priv] || Path.join("priv", repo_dir(repo))
    Path.expand(Path.join(priv, "migrations"))
  end

  defp snapshot_root do
    # `Path.expand`, not `Path.join(cwd, ...)`: an absolute override
    # (`/srv/shared/snapshots`) must not be glued onto the project root.
    Path.expand(config(:snapshot_root, @default_snapshot_root))
  end

  defp config(key, default) do
    ensure_app_config()
    Application.get_env(:ash_strangler, __MODULE__, []) |> Keyword.get(key, default)
  end

  defp migration_suffix do
    config(:migration_suffix, @default_migration_suffix)
  end

  defp repo_dir(repo) do
    repo |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp key(resource) do
    resource |> Module.split() |> Enum.map_join("_", &Macro.underscore/1)
  end

  # -- version arithmetic --------------------------------------------------------

  defp newest_version(dir) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.flat_map(fn
      <<version::binary-size(14), "_", _rest::binary>> ->
        if String.match?(version, ~r/^\d{14}$/), do: [String.to_integer(version)], else: []

      _ ->
        []
    end)
    |> case do
      [] -> 0
      versions -> Enum.max(versions)
    end
  end

  defp utc_now_version do
    NaiveDateTime.utc_now() |> format_version()
  end

  defp bump(version) do
    <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), h::binary-size(2),
      mi::binary-size(2), s::binary-size(2)>> = version

    NaiveDateTime.new!(
      Date.new!(String.to_integer(y), String.to_integer(mo), String.to_integer(d)),
      Time.new!(String.to_integer(h), String.to_integer(mi), String.to_integer(s))
    )
    |> NaiveDateTime.add(1, :second)
    |> format_version()
  end

  defp format_version(datetime) do
    Calendar.strftime(datetime, "%Y%m%d%H%M%S")
  end
end
