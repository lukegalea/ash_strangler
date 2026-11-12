# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Codegen do
  @moduledoc """
  The comparison layer behind `mix ash.codegen`'s strangler coverage: what the
  renderer produces now, what the committed snapshots record, and the difference
  between the two — so the comparison lives in the library, not in hosts.

  Attaching this extension to a domain opts that domain's strangled resources
  into coverage; nothing is compared and nothing is written for applications
  whose domains do not attach it.
  """

  use Spark.Dsl.Extension

  @behaviour Ash.Extension

  @default_snapshot_root "priv/strangler_snapshots"

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
  carry (empty for a `:removed`, because a removal is carried by nothing).

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
    default = default_repo!()

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

  defp snapshot_root do
    Path.join([File.cwd!(), config(:snapshot_root, @default_snapshot_root)])
  end

  defp config(key, default) do
    ensure_app_config()
    Application.get_env(:ash_strangler, __MODULE__, []) |> Keyword.get(key, default)
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
