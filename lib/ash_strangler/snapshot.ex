# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Snapshot do
  @moduledoc """
  A pinned, offline copy of the legacy schema, and the gates that keep it
  honest.

  A snapshot is a directory of four files:

  | File | Content | Written by |
  |---|---|---|
  | `schema.sql` | `pg_dump --schema-only` of the legacy schemas, normalised | `capture/3` |
  | `extensions.sql` | optional preamble: `CREATE EXTENSION ... SCHEMA ...` and anything else `schema.sql` assumes exists | you, by hand, and committed |
  | `catalog.json` | the catalog facts, derived from the two files above (`AshStrangler.Snapshot.Catalog`) | `derive/3` |
  | `lock.json` | hashes of the three files, the schemas, the declared migration heads, tool versions | `derive/3` |

  The catalog is a **function of the SQL files**: `derive/3` loads
  `extensions.sql` then `schema.sql` into a scratch database created from
  `template0`, reads `pg_catalog`, encodes canonical JSON and drops the
  database. Nobody writes a catalog by hand, and `verify/2` proves nobody did:
  it re-derives and compares bytes.

  The extension preamble is separate because `pg_dump -n` never emits `CREATE
  EXTENSION`, while where an extension lives (`citext` in the legacy schema, or
  in `public`) changes how every type in the dump resolves. Placement is
  recorded in the catalog, so drift catches a database whose extensions live
  somewhere else.

  ## Gates

    * `verify/2` (G-SNAP): every hash in the lock matches its file, and
      re-deriving reproduces `catalog.json` byte for byte. Needs a PostgreSQL
      server to derive on, not the legacy database.
    * `drift/3` (G-DRIFT): the live database's catalog against the locked one.
      Additions, removals and changes, each named, minus an allow-list.
    * `AshStrangler.Verifiers.VerifySnapshot` (V-SNAPSHOT): twins against the
      catalog, at compile time, with no database at all.

  ## Connection configuration

  Every function that touches PostgreSQL takes `config`, a keyword list in the
  shape of an Ecto repo's configuration (`hostname`, `port`, `username`,
  `password`, `database`, ...). `MyApp.Repo.config()` is one. Loading uses
  `psql` and capture uses `pg_dump`, through `Ecto.Adapters.Postgres`, so both
  must be on `PATH`, and `pg_dump` must be at least the server's version.
  """

  alias AshStrangler.Snapshot.Catalog

  @schema_file "schema.sql"
  @extensions_file "extensions.sql"
  @catalog_file "catalog.json"
  @lock_file "lock.json"
  @lock_format "ash_strangler.lock/1"

  @doc "The file names a snapshot directory holds."
  @spec files() :: %{
          schema: String.t(),
          extensions: String.t(),
          catalog: String.t(),
          lock: String.t()
        }
  def files,
    do: %{
      schema: @schema_file,
      extensions: @extensions_file,
      catalog: @catalog_file,
      lock: @lock_file
    }

  # --- normalise ---------------------------------------------------------

  # One `pg_dump` TOC entry whose object name (the last word of its `Name:`,
  # which for a trigger is `<table> <trigger>`) starts `strangler_`, up to the
  # next entry's header or the end of the script.
  defp strangler_objects,
    do: ~r/^--\n-- Name: (?:[^;\n]* )?strangler_[^; \n]*; Type: [^\n]*\n--\n.*?(?=^--\n-- |\z)/ms

  @doc """
  Normalises a `pg_dump` script into a file a reviewer can diff and a plain
  SQL client can load.

    * psql meta-commands are dropped. `pg_dump` 17.6 and later wrap the script
      in `\\restrict <random key>` / `\\unrestrict`, which changes on every run.
    * The `-- Dumped from` / `-- Dumped by` version lines are dropped; the lock
      records tool versions instead.
    * `SET transaction_timeout = 0;` is dropped. `pg_dump` 17 and later emit
      it, servers before 17 reject it, and a schema-only load has no use for
      it: without this, a capture taken with a newer `pg_dump` will not derive
      on an older server.
    * `CREATE SCHEMA x;` becomes `CREATE SCHEMA IF NOT EXISTS x;`, so the script
      loads into a database where the extension preamble already created the
      schema, or where `public` exists, which is every database.
    * Every object named `strangler_*` (the triggers, trigger functions and
      key indexes this package installs) is dropped with its `-- Name:` block.
      They are the strangle, not the legacy schema, so a capture taken where a
      strangle already runs records the same schema as one taken before it.
      `pg_dump -n` emits a trigger on a dumped table even when its function
      lives in a schema it does not dump, so without this such a capture would
      not even load.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(dump) do
    dump
    |> String.replace(strangler_objects(), "")
    |> String.split("\n")
    |> Enum.reject(
      &(String.starts_with?(&1, "\\") or
          &1 =~ ~r/^(-- Dumped (from|by) |SET transaction_timeout = )/)
    )
    |> Enum.map_join(
      "\n",
      &String.replace(&1, ~r/^CREATE SCHEMA (?!IF NOT EXISTS )/, "CREATE SCHEMA IF NOT EXISTS ")
    )
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # --- capture -----------------------------------------------------------

  @doc """
  Captures `schema.sql` from the live database `config` points at, then
  derives `catalog.json` and `lock.json` from it.

  Options:

    * `:schemas` (required) — the schemas to dump.
    * `:heads` — declared migration heads, `%{"name" => "value"}`.
    * `:head_from` — heads read from the captured database:
      `%{"name" => "schema.table.column"}` records the column's maximum and the
      table's row count. A migration table read at capture time cannot
      disagree with the schema it was captured with.
    * `:derive_config` — the server to derive on, when it is not the captured
      one (the captured database may be read-only to you). Defaults to `config`.
  """
  @spec capture(Path.t(), keyword(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def capture(dir, config, opts) do
    schemas = Keyword.fetch!(opts, :schemas)
    File.mkdir_p!(dir)
    raw = Path.join(dir, ".#{@schema_file}.raw")

    args =
      ["--schema-only", "--no-owner", "--no-privileges", "--no-comments", "--file", raw] ++
        Enum.flat_map(schemas, &["--schema", &1])

    try do
      case Ecto.Adapters.Postgres.dump_cmd(args, [], config) do
        {_output, 0} ->
          File.write!(Path.join(dir, @schema_file), raw |> File.read!() |> normalise())
          {heads, server} = read_heads(config, Keyword.get(opts, :head_from, %{}))

          captured = %{
            "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            "pg_dump" => pg_dump_version(),
            "server" => server
          }

          derive(dir, Keyword.get(opts, :derive_config, config),
            schemas: schemas,
            heads: Map.merge(declared(Keyword.get(opts, :heads, %{})), heads),
            captured: captured
          )

        {output, status} ->
          {:error, "pg_dump exited #{status}:\n#{output}"}
      end
    after
      File.rm(raw)
    end
  end

  defp read_heads(config, head_from) do
    with_connection(config, fn conn ->
      %{rows: [[server]]} = Postgrex.query!(conn, "SHOW server_version", [])

      heads =
        Map.new(head_from, fn {name, path} ->
          {relation, column} = split_column(path)

          %{rows: [[head, count]]} =
            Postgrex.query!(
              conn,
              "SELECT max(#{quote_ident(column)})::text, count(*) FROM #{quote_relation(relation)}",
              []
            )

          {name, %{"head" => head, "count" => count}}
        end)

      {heads, server}
    end)
  end

  # `--version` is only honoured as pg_dump's first argument, so not through
  # `dump_cmd/3`, which puts connection flags first.
  defp pg_dump_version do
    case System.cmd("pg_dump", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp declared(heads),
    do: Map.new(heads, fn {name, value} -> {name, %{"head" => value, "count" => nil}} end)

  # --- derive ------------------------------------------------------------

  @doc """
  Derives `catalog.json` and `lock.json` from the SQL files in `dir`, on a
  scratch database on the server `config` points at (it needs `CREATEDB`).

  Options:

    * `:schemas` — the schemas the catalog covers. Defaults to the existing
      lock's.
    * `:heads` — declared migration heads, `%{"name" => "value"}`, merged over
      the existing lock's.
    * `:captured` — capture metadata; `capture/3` passes it. Otherwise the
      existing lock's is kept.
  """
  @spec derive(Path.t(), keyword(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def derive(dir, config, opts \\ []) do
    previous =
      case read_lock(dir) do
        {:ok, lock} -> lock
        {:error, _} -> %{}
      end

    schemas = Keyword.get(opts, :schemas) || previous["schemas"]

    heads =
      previous
      |> Map.get("heads", %{})
      |> Map.merge(Keyword.get(opts, :heads, %{}), fn _name, _old, new -> new end)
      |> Map.new(fn
        {name, %{} = head} -> {name, head}
        {name, value} -> {name, %{"head" => value, "count" => nil}}
      end)

    cond do
      schemas in [nil, []] ->
        {:error, "no schemas: pass `schemas:` (`--schema`), or derive in a directory with a lock"}

      not File.exists?(Path.join(dir, @schema_file)) ->
        {:error, "#{Path.join(dir, @schema_file)} does not exist"}

      true ->
        with {:ok, {catalog, server}} <- derive_catalog(dir, config, schemas) do
          File.write!(Path.join(dir, @catalog_file), catalog)

          lock = %{
            "format" => @lock_format,
            "generator" => "ash_strangler #{Application.spec(:ash_strangler, :vsn)}",
            "schemas" => Enum.sort(schemas),
            "heads" => heads,
            "files" => hashes(dir),
            "derived_on" => server,
            "captured" => Keyword.get(opts, :captured, previous["captured"])
          }

          File.write!(Path.join(dir, @lock_file), Catalog.encode(lock))
          {:ok, lock}
        end
    end
  end

  defp derive_catalog(dir, config, schemas) do
    with_scratch_database(config, fn scratch ->
      with :ok <- load(dir, scratch) do
        with_connection(scratch, fn conn ->
          %{rows: [[server]]} = Postgrex.query!(conn, "SHOW server_version", [])
          {:ok, {Catalog.encode(Catalog.introspect(conn, schemas)), "PostgreSQL #{server}"}}
        end)
      end
    end)
  end

  defp hashes(dir) do
    [@schema_file, @extensions_file, @catalog_file]
    |> Enum.filter(&File.exists?(Path.join(dir, &1)))
    |> Map.new(&{&1, sha256(Path.join(dir, &1))})
  end

  defp sha256(path), do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  # --- load --------------------------------------------------------------

  @doc """
  Loads `extensions.sql` (when present) and then `schema.sql` into the
  database `config` points at, each in one transaction, stopping at the first
  error. This is how a stand-in for the legacy database is built.
  """
  @spec load(Path.t(), keyword()) :: :ok | {:error, String.t()}
  def load(dir, config) do
    [@extensions_file, @schema_file]
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.exists?/1)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Ecto.Adapters.Postgres.structure_load(dir, Keyword.put(config, :dump_path, path)) do
        {:ok, _path} -> {:cont, :ok}
        {:error, output} -> {:halt, {:error, "loading #{path} failed:\n#{output}"}}
      end
    end)
  end

  # --- verify (G-SNAP) ---------------------------------------------------

  @doc """
  G-SNAP: the lock's hashes match the files, no snapshot file is missing from
  the lock, and re-deriving reproduces `catalog.json` byte for byte.

  Returns `:ok` or `{:error, problems}`, each problem one sentence.
  """
  @spec verify(Path.t(), keyword()) :: :ok | {:error, [String.t()]}
  def verify(dir, config) do
    case read_lock(dir) do
      {:error, message} ->
        {:error, [message]}

      {:ok, lock} ->
        problems = hash_problems(dir, lock) ++ reproduction_problems(dir, config, lock)
        if problems == [], do: :ok, else: {:error, problems}
    end
  end

  defp hash_problems(dir, lock) do
    locked = lock["files"] || %{}
    present = hashes(dir)

    missing =
      for file <- [@schema_file, @catalog_file],
          not Map.has_key?(present, file),
          do: "#{file} is missing"

    mismatched =
      for {file, hash} <- Enum.sort(present), Map.get(locked, file) != hash do
        case Map.fetch(locked, file) do
          :error -> "#{file} is not in the lock; re-derive"
          {:ok, _other} -> "#{file} does not match its hash in the lock"
        end
      end

    unlocked =
      for {file, _hash} <- Enum.sort(locked),
          not Map.has_key?(present, file),
          do: "the lock names #{file}, which does not exist"

    missing ++ mismatched ++ unlocked
  end

  defp reproduction_problems(dir, config, lock) do
    committed = File.read(Path.join(dir, @catalog_file))

    case {committed, derive_catalog(dir, config, lock["schemas"] || [])} do
      {{:ok, same}, {:ok, {same, _server}}} ->
        []

      {_committed, {:error, message}} ->
        ["re-deriving the catalog failed: #{message}"]

      {{:ok, bytes}, {:ok, {derived, _server}}} ->
        with {:ok, old} <- Catalog.decode(bytes), {:ok, new} <- Catalog.decode(derived) do
          case Catalog.diff(old, new) do
            [] ->
              ["catalog.json is not in canonical form; re-derive"]

            differences ->
              Enum.map(differences, &"catalog.json disagrees with schema.sql: #{describe(&1)}")
          end
        else
          {:error, message} -> ["catalog.json does not decode: #{message}"]
        end

      {{:error, _reason}, _derived} ->
        []
    end
  end

  # --- drift (G-DRIFT) ---------------------------------------------------

  @doc """
  G-DRIFT: the catalog of the database `config` points at, against
  `catalog.json`, over the locked schemas.

  `allow` is a list of patterns matched against each difference's id
  (`"relation shop.audit_*"`, `"column shop.orders.*"`); `*` matches any run of
  characters. Returns `{:ok, %{differences: [...], allowed: [...]}}`; the gate
  passes when `differences` is empty.
  """
  @spec drift(Path.t(), keyword(), [String.t()]) ::
          {:ok, %{differences: [Catalog.difference()], allowed: [Catalog.difference()]}}
          | {:error, String.t()}
  def drift(dir, config, allow \\ []) do
    with {:ok, locked} <- read_catalog(Path.join(dir, @catalog_file)) do
      live = with_connection(config, &Catalog.introspect(&1, locked["schemas"]))
      patterns = Enum.map(allow, &pattern/1)

      {allowed, differences} =
        locked
        |> Catalog.diff(live)
        |> Enum.split_with(fn difference ->
          Enum.any?(patterns, &Regex.match?(&1, difference.id))
        end)

      {:ok, %{differences: differences, allowed: allowed}}
    end
  end

  defp pattern(glob) do
    ~r/^#{glob |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)}$/
  end

  @doc "One line describing a difference, for reports and errors."
  @spec describe(Catalog.difference()) :: String.t()
  def describe(%{change: :added, id: id}), do: "#{id} added"
  def describe(%{change: :removed, id: id}), do: "#{id} removed"

  def describe(%{change: :changed, id: id, locked: locked, live: live})
      when is_map(locked) and is_map(live) do
    fields =
      (Map.keys(locked) ++ Map.keys(live))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(Map.get(locked, &1) == Map.get(live, &1)))
      |> Enum.map_join(
        ", ",
        &"#{&1} #{inspect(Map.get(locked, &1))} -> #{inspect(Map.get(live, &1))}"
      )

    "#{id} changed: #{fields}"
  end

  def describe(%{change: :changed, id: id, locked: locked, live: live}),
    do: "#{id} changed: #{inspect(locked)} -> #{inspect(live)}"

  # --- reading -----------------------------------------------------------

  @doc "Reads and decodes a `catalog.json`."
  @spec read_catalog(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read_catalog(path) do
    case File.read(path) do
      {:ok, json} ->
        case Catalog.decode(json) do
          {:ok, catalog} -> {:ok, catalog}
          {:error, message} -> {:error, "#{path}: #{message}"}
        end

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Reads the snapshot's `lock.json`."
  @spec read_lock(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read_lock(dir) do
    path = Path.join(dir, @lock_file)

    with {:ok, json} <- File.read(path),
         {:ok, %{"format" => @lock_format} = lock} <- Jason.decode(json) do
      {:ok, lock}
    else
      {:ok, _other} -> {:error, "#{path} is not an #{@lock_format} lock"}
      {:error, %Jason.DecodeError{} = error} -> {:error, "#{path}: #{Exception.message(error)}"}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  # --- connections -------------------------------------------------------

  @doc """
  Runs `fun` with a dedicated, unpooled `Postgrex` connection built from
  `config`, and closes it afterwards.

  Dedicated on purpose: introspection runs with an empty `search_path`, and
  the host's pool (or its test sandbox) must not lend or receive that
  connection.
  """
  @spec with_connection(keyword(), (DBConnection.conn() -> result)) :: result when result: term()
  def with_connection(config, fun) do
    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    {:ok, conn} =
      config
      |> Keyword.drop([:name, :log, :pool, :pool_size, :repo, :otp_app, :telemetry_prefix])
      |> Keyword.merge(pool_size: 1, backoff_type: :stop, max_restarts: 0)
      |> Postgrex.start_link()

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  @doc """
  Runs `fun` with the configuration of a fresh database created from
  `template0` on `config`'s server, and drops the database afterwards.
  """
  @spec with_scratch_database(keyword(), (keyword() -> result)) :: result when result: term()
  def with_scratch_database(config, fun) do
    name = "ash_strangler_scratch_#{System.unique_integer([:positive])}"
    admin = &with_connection(config, fn conn -> Postgrex.query!(conn, &1, []) end)

    admin.(~s(CREATE DATABASE "#{name}" TEMPLATE template0))

    try do
      fun.(Keyword.put(config, :database, name))
    after
      admin.(~s[DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)])
    end
  end

  defp split_column(path) do
    case AshStrangler.Sql.Relation.parse_column(path) do
      {:ok, {schema, table, column}} -> {{schema, table}, column}
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp quote_relation({schema, table}), do: "#{quote_ident(schema)}.#{quote_ident(table)}"

  defp quote_ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
