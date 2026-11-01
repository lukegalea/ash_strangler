# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Snapshot do
  @shortdoc "Captures, derives, verifies and drift-checks a pinned legacy schema snapshot"

  @moduledoc """
  Manages a snapshot directory: `schema.sql`, the optional `extensions.sql`
  preamble, `catalog.json` and `lock.json`. See `AshStrangler.Snapshot` for
  what each file is and the "Snapshot" guide for the workflow.

      mix ash_strangler.snapshot capture priv/legacy/snapshot --url "$LEGACY_URL" \\
        --schema shop --head-from migrations=shop.schema_migrations.version
      mix ash_strangler.snapshot derive priv/legacy/snapshot --schema shop
      mix ash_strangler.snapshot verify priv/legacy/snapshot
      mix ash_strangler.snapshot drift priv/legacy/snapshot --allow-file priv/legacy/drift-allow.txt
      mix ash_strangler.snapshot load priv/legacy/snapshot

  ## Commands

    * `capture DIR` — `pg_dump --schema-only` of the `--schema`s from the
      database, normalised into `DIR/schema.sql`, then `derive`.
    * `derive DIR` — `catalog.json` and `lock.json` from `DIR`'s SQL files, on
      a scratch database (the role needs `CREATEDB`).
    * `verify DIR` — G-SNAP: the lock's hashes match and re-deriving reproduces
      `catalog.json` byte for byte. Exits 1 otherwise.
    * `drift DIR` — G-DRIFT: the database's catalog against `catalog.json`.
      Exits 1 on any difference not allowed.
    * `load DIR` — loads `extensions.sql` then `schema.sql` into the database:
      a stand-in for the legacy one.

  ## Options

    * `--url` — the database, as `postgres://user:password@host:port/database`.
      Prefer leaving the password out and setting `PGPASSWORD`.
    * `--repo` — take the connection from a repo's configuration instead.
      Defaults to the application's only `ecto_repos` entry.
    * `--schema` — repeatable; the schemas to capture or derive.
    * `--head NAME=VALUE` — repeatable; a declared migration head for the lock.
    * `--head-from NAME=SCHEMA.TABLE.COLUMN` — repeatable, `capture` only; the
      head read from the captured database (`max(column)` and the row count).
    * `--derive-url` — `capture` only; derive on this server rather than the
      captured one.
    * `--allow PATTERN`, `--allow-file FILE` — `drift` only; differences whose
      id matches are reported as allowed. `*` matches anything. The file holds
      one pattern per line; `#` starts a comment.
    * `--json FILE` — `drift` only; also write the report as JSON.
  """

  use Mix.Task

  alias AshStrangler.Snapshot

  @switches [
    url: :string,
    repo: :string,
    schema: :keep,
    head: :keep,
    head_from: :keep,
    derive_url: :string,
    allow: :keep,
    allow_file: :string,
    json: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.config")

    case args do
      [command, dir] when command in ~w(capture derive verify drift load) ->
        command(command, dir, opts)

      _ ->
        Mix.raise(
          "usage: mix ash_strangler.snapshot capture|derive|verify|drift|load DIR [options]"
        )
    end
  end

  defp command("capture", dir, opts) do
    config = connection(opts)

    dir
    |> Snapshot.capture(config,
      schemas: required_schemas(opts),
      heads: pairs(opts, :head),
      head_from: pairs(opts, :head_from),
      derive_config: if(url = opts[:derive_url], do: parse_url(url), else: config)
    )
    |> report_lock(dir)
  end

  defp command("derive", dir, opts) do
    dir
    |> Snapshot.derive(connection(opts),
      schemas: Keyword.get_values(opts, :schema) |> nil_if_empty(),
      heads: pairs(opts, :head)
    )
    |> report_lock(dir)
  end

  defp command("verify", dir, opts) do
    case Snapshot.verify(dir, connection(opts)) do
      :ok ->
        Mix.shell().info("#{dir}: lock, files and catalog agree")

      {:error, problems} ->
        Enum.each(problems, &Mix.shell().error("#{dir}: #{&1}"))
        exit({:shutdown, 1})
    end
  end

  defp command("drift", dir, opts) do
    allow = Keyword.get_values(opts, :allow) ++ allow_file(opts[:allow_file])

    case Snapshot.drift(dir, connection(opts), allow) do
      {:ok, report} ->
        Enum.each(report.allowed, &Mix.shell().info("allowed: #{Snapshot.describe(&1)}"))
        Enum.each(report.differences, &Mix.shell().error("drift: #{Snapshot.describe(&1)}"))

        if path = opts[:json] do
          File.write!(path, AshStrangler.Snapshot.Catalog.encode(json_report(report)))
        end

        if report.differences == [] do
          Mix.shell().info("no drift against #{dir} (#{length(report.allowed)} allowed)")
        else
          exit({:shutdown, 1})
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp command("load", dir, opts) do
    case Snapshot.load(dir, connection(opts)) do
      :ok -> Mix.shell().info("loaded #{dir}")
      {:error, message} -> Mix.raise(message)
    end
  end

  defp report_lock({:ok, lock}, dir) do
    Mix.shell().info("#{dir}: catalog and lock written (#{map_size(lock["files"])} files hashed)")
  end

  defp report_lock({:error, message}, _dir), do: Mix.raise(message)

  defp json_report(report) do
    entry = fn difference ->
      %{
        "id" => difference.id,
        "change" => Atom.to_string(difference.change),
        "locked" => difference.locked,
        "live" => difference.live
      }
    end

    %{
      "differences" => Enum.map(report.differences, entry),
      "allowed" => Enum.map(report.allowed, entry)
    }
  end

  defp required_schemas(opts) do
    case Keyword.get_values(opts, :schema) do
      [] -> Mix.raise("capture needs at least one --schema")
      schemas -> schemas
    end
  end

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(list), do: list

  defp pairs(opts, key) do
    opts
    |> Keyword.get_values(key)
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name, value] when name != "" and value != "" ->
          {name, value}

        _ ->
          Mix.raise(
            "--#{String.replace(to_string(key), "_", "-")} takes NAME=VALUE, got #{inspect(pair)}"
          )
      end
    end)
  end

  defp allow_file(nil), do: []

  defp allow_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/#.*$/, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp connection(opts) do
    cond do
      url = opts[:url] -> parse_url(url)
      repo = opts[:repo] -> Module.concat([repo]).config()
      true -> default_repo().config()
    end
  end

  defp default_repo do
    case Application.get_env(Mix.Project.config()[:app], :ecto_repos, []) do
      [repo] -> repo
      [] -> Mix.raise("No `ecto_repos` configured: pass --url or --repo")
      repos -> Mix.raise("Several repos are configured (#{inspect(repos)}): pass --repo")
    end
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    unless uri.scheme in ["postgres", "postgresql"] and uri.host do
      Mix.raise("--url must be postgres://user@host:port/database")
    end

    {username, password} =
      case String.split(uri.userinfo || "", ":", parts: 2) do
        [""] -> {nil, nil}
        [user] -> {URI.decode(user), nil}
        [user, password] -> {URI.decode(user), URI.decode(password)}
      end

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "", "/"),
      username: username || System.get_env("PGUSER"),
      password: password || System.get_env("PGPASSWORD")
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end
end
