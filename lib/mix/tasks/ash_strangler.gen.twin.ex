# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshStrangler.Gen.Twin do
    @shortdoc "Generates a twin resource from a live legacy relation or a pinned snapshot"

    @example "mix ash_strangler.gen.twin --relation legacy.users --module MyApp.Legacy.Users"

    @moduledoc """
    Reads a legacy relation out of the database and writes it back as an Ash
    resource — a *twin*. See `AshStrangler.Twin` for what one is and why the
    mapping needs it.

        #{@example}
        mix ash_strangler.gen.twin --relation legacy.users --relation legacy.addresses
        mix ash_strangler.gen.twin --relation legacy.users --dry-run
        mix ash_strangler.gen.twin --from-snapshot priv/legacy/snapshot/catalog.json \\
          --relation legacy.users --secret legacy.users.crypted_password

    ## The legacy schema is read, never retyped

    A `strangler` mapping says `expr(first_name)`, and `first_name` has to resolve
    against something. The alternative to a twin — declaring the legacy columns
    inline in the mapping — restates by hand a schema the database already knows,
    which is the defect the whole typed layer exists to remove. So the columns,
    their types, the primary key, the unique indexes and the foreign keys all come
    from a catalog (`AshStrangler.Snapshot.Catalog`): read from `pg_catalog`
    through the repo, or, with `--from-snapshot`, from a pinned `catalog.json`
    with no database at all. Both modes go through the same catalog and the same
    `AshStrangler.Twin.Generator`, so they write the same twin for the same schema.

    The twin is therefore a **snapshot**, and snapshots go stale. A twin
    generated `--from-snapshot` is pinned to its catalog (`twin do snapshot
    ... end`), and `AshStrangler.Verifiers.VerifySnapshot` fails compilation
    when they disagree; `mix ash_strangler.snapshot drift` holds the catalog to
    the live database. A twin generated live has `mix ash_strangler.check`,
    which diffs it against `information_schema.columns` and compares each column
    it declares with what this task would write for it today. What this task reads
    from the catalog is `AshStrangler.Twin.Introspection`, which `check` calls too.

    ## Secrets

    `--secret schema.table.column` (repeatable) leaves a column off the twin and
    records it in `twin do secrets [...] end`, so no mapping, view, ledger image
    or notification can carry it. Secrets already declared in an existing twin's
    source are kept on regeneration, read from the file rather than the compiled
    module: the twin being regenerated may be the one that does not compile.

    ## `CHECK (col IN (...))` becomes `:atom` with `one_of`, and that is load-bearing

    A `text` column with a `CHECK` constraint naming its values, or a column of a
    Postgres enum type, is emitted as `:atom` with `constraints one_of: [...]`
    rather than as `:string`.

    That is not a cosmetic preference. `AshStrangler.Obligations` decides
    `GetTotal` — *is there a legacy value the forward direction cannot turn into a
    valid attribute value* — by enumerating the legacy column's domain. With
    `one_of` the domain exists and a `decode` that forgets `passive` fails the
    build. Without it there is nothing to enumerate, the obligation degrades to a
    SQL assertion, and the answer arrives from `mix ash_strangler.check` against
    real rows instead of from the compiler. Both answers are honest; only one of
    them arrives before the migration ships.

    The parse is deliberately conservative. PostgreSQL normalises `IN (...)` to
    `= ANY (ARRAY[...])`, and only that shape — the whole constraint, over one
    column, with literal operands — is read. A `CHECK (length(weird) > 3)`, or a
    value set combined with anything else, produces a `:string` attribute and a
    comment in the generated file saying which constraint was not understood.
    Guessing at a partially-parsed constraint would produce a `one_of` that is
    *wrong*, and a wrong `one_of` makes the compiler refuse mappings that are
    correct.

    ## Why this does not wrap `mix ash_postgres.gen.resources`

    `ash_postgres` ships a resource generator, and reusing it was the first thing
    tried. It generates resources for a schema an application is *adopting* — so it
    emits no `migrate? false`, it derives no `one_of`, and it wires the result into
    migration snapshot generation, which is exactly the opposite of what a twin
    wants: Ash must never own this table.

    Reaching that output and then rewriting it — deleting the snapshot task,
    inserting `migrate? false`, retyping the columns that carry a `CHECK` — is more
    code than reading the catalog directly, and it is code that breaks whenever
    the other generator's output shape changes. It also needs a live database,
    which a pinned snapshot exists to do without.

    ## Regenerating an existing twin

    An existing twin already knows its relation, its repo and its domain — they are
    in its `postgres` block. So it can be named on its own:

        mix ash_strangler.gen.twin MyApp.Legacy.Users

    That is the form every error message in this package reaches for, because the
    thing somebody has in hand when a twin has gone stale is the module. Requiring
    them to look up the relation to refresh a snapshot of it would be a rule with
    nothing behind it.

    ## Options

      * `--relation` — the relation to introspect, schema-qualified
        (`legacy.users`). Repeatable: a foreign key becomes a `belongs_to` only
        when its target is also being generated in this run or already exists as a
        twin, so generating a cluster of related tables together is what resolves
        them.
      * `--module` — the module to write. Only valid with a single `--relation`;
        otherwise each module is derived from `--domain` and the table name.
      * `--repo` — the repo to introspect through. Defaults to the application's
        single configured `ecto_repos` entry.
      * `--domain` — the domain the twins belong to. Defaults to
        `<App>.Legacy`, and is created if it does not exist. Twins are kept out of
        the application's own domains on purpose: they are the old schema, not part
        of the model.
      * `--from-snapshot` — a `catalog.json` to generate from instead of the
        database, and to pin the twin to. See `AshStrangler.Snapshot`.
      * `--secret` — `schema.table.column`, repeatable: a column to leave off.
      * `--system-actor` — a policy check module matching the host's system
        actor. The twin gets `authorizers: [Ash.Policy.Authorizer]` and
        `twin do system_actor Check end`, so only that actor reads it. Kept on
        regeneration.
      * `--dry-run` — print the diff and write nothing.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        positional: [{:module, [optional: true]}],
        composes: ["ash.gen.domain"],
        schema: [
          relation: :keep,
          module: :string,
          repo: :string,
          domain: :string,
          from_snapshot: :string,
          secret: :keep,
          system_actor: :string
        ],
        aliases: [r: :relation, m: :module, d: :domain]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      # `--return-errors`: the twin being regenerated is often the one that no
      # longer compiles (its snapshot moved), and refusing to run until it
      # compiles would leave no way to fix it.
      Mix.Task.run("compile", ["--return-errors"])

      options = igniter.args.options

      with {:ok, targets, repo} <- resolve(igniter.args.positional[:module], options),
           {:ok, secrets} <- secrets(options) do
        generate(igniter, targets, repo, secrets, options)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # --- regenerating a twin that already exists --------------------------

    defp resolve(nil, options) do
      options |> Keyword.get(:relation, []) |> List.wrap() |> validate(options)
    end

    defp resolve(name, options) do
      module = Igniter.Project.Module.parse(name)

      if AshStrangler.Twin.twin?(module) do
        {:ok, [existing_target(module, options)], existing_repo(module, options)}
      else
        {:error,
         """
         #{inspect(module)} is not a compiled twin, so there is nothing to read its relation off.

         Name the relation instead:

             mix ash_strangler.gen.twin --relation legacy.users --module #{inspect(module)}
         """}
      end
    end

    defp existing_target(module, options) do
      relation =
        case options |> Keyword.get(:relation, []) |> List.wrap() do
          [override | _] -> override
          [] -> AshStrangler.Twin.relation(module)
        end

      {schema, table} = split_relation(relation)

      %{
        relation: "#{schema}.#{table}",
        schema: schema,
        table: table,
        module: module,
        domain: domain_of(module, options)
      }
    end

    defp existing_repo(module, options) do
      case options[:repo] do
        nil -> AshPostgres.DataLayer.Info.repo(module, :read)
        name -> Igniter.Project.Module.parse(name)
      end
    end

    defp domain_of(module, options) do
      case options[:domain] do
        nil -> Ash.Resource.Info.domain(module)
        name -> Igniter.Project.Module.parse(name)
      end
    end

    # --- argument resolution ----------------------------------------------

    defp validate([], _options) do
      {:error,
       """
       No `--relation` given, and there is nothing to introspect without one.

           #{@example}

       The relation is schema-qualified because a legacy schema almost never lives
       in `public`, and relying on `search_path` to find it makes the generated
       twin depend on the session that generated it.
       """}
    end

    defp validate(relations, options) do
      with {:ok, repo} <- resolve_repo(options),
           {:ok, domain} <- resolve_domain(options),
           {:ok, targets} <- resolve_targets(relations, domain, options) do
        {:ok, targets, repo}
      end
    end

    defp resolve_repo(options) do
      case options[:repo] do
        nil ->
          case Application.get_env(Mix.Project.config()[:app], :ecto_repos, []) do
            [repo] ->
              {:ok, repo}

            [] ->
              {:error,
               "No `ecto_repos` configured and no `--repo` given. Pass `--repo MyApp.Repo`."}

            repos ->
              {:error,
               "Several repos are configured (#{Enum.map_join(repos, ", ", &inspect/1)}). " <>
                 "Pass `--repo` to say which one holds the legacy schema."}
          end

        name ->
          {:ok, Igniter.Project.Module.parse(name)}
      end
    end

    defp resolve_domain(options) do
      case options[:domain] do
        nil ->
          app = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
          {:ok, Module.concat([app, "Legacy"])}

        name ->
          {:ok, Igniter.Project.Module.parse(name)}
      end
    end

    defp resolve_targets(relations, domain, options) do
      case {relations, options[:module]} do
        {[_relation], nil} ->
          {:ok, Enum.map(relations, &target(&1, domain))}

        {[relation], module} ->
          {:ok, [%{target(relation, domain) | module: Igniter.Project.Module.parse(module)}]}

        {_several, nil} ->
          {:ok, Enum.map(relations, &target(&1, domain))}

        {_several, _module} ->
          {:error,
           "`--module` names one module, but several `--relation`s were given. " <>
             "Drop `--module` and each twin is named `#{inspect(domain)}.<Table>`, or run the task once per relation."}
      end
    end

    defp target(relation, domain) do
      {schema, table} = split_relation(relation)

      %{
        relation: "#{schema}.#{table}",
        schema: schema,
        table: table,
        module: Module.concat(domain, Macro.camelize(table)),
        domain: domain
      }
    end

    # An unqualified relation is taken as `public`, and said out loud in the
    # generated `schema "public"` rather than left to `search_path`.
    defp split_relation(relation) do
      case String.split(relation, ".", parts: 2) do
        [schema, table] -> {schema, table}
        [table] -> {"public", table}
      end
    end

    # --- generation --------------------------------------------------------

    defp generate(igniter, targets, repo, secrets, options) do
      snapshot = options[:from_snapshot]

      with {:ok, catalog} <- catalog(targets, repo, snapshot),
           :ok <- present(targets, catalog, snapshot) do
        Enum.reduce(
          targets,
          ensure_domains(igniter, targets),
          &write(&2, &1, %{
            repo: repo,
            catalog: catalog,
            targets: targets,
            secrets: Map.get(secrets, &1.relation, []),
            snapshot: snapshot,
            system_actor: options[:system_actor]
          })
        )
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp secrets(options) do
      options
      |> Keyword.get(:secret, [])
      |> List.wrap()
      |> Enum.reduce_while({:ok, %{}}, fn secret, {:ok, acc} ->
        case String.split(secret, ".") do
          [schema, table, column] ->
            {:cont, {:ok, Map.update(acc, "#{schema}.#{table}", [column], &[column | &1])}}

          _ ->
            {:halt, {:error, "`--secret` takes schema.table.column, got #{inspect(secret)}"}}
        end
      end)
    end

    # Every twin is written from a catalog. `--from-snapshot` reads the pinned
    # one; otherwise the live database is introspected into one, by the same
    # code `mix ash_strangler.snapshot` uses, so the two modes cannot disagree.
    defp catalog(_targets, _repo, path) when is_binary(path),
      do: AshStrangler.Snapshot.read_catalog(path)

    defp catalog(targets, repo, nil) do
      schemas = targets |> Enum.map(& &1.schema) |> Enum.uniq()

      {:ok,
       AshStrangler.Snapshot.with_connection(
         repo.config(),
         &AshStrangler.Snapshot.Catalog.introspect(&1, schemas)
       )}
    rescue
      error ->
        {:error,
         """
         Could not introspect the legacy schema through #{inspect(repo)}: #{Exception.message(error)}

         Without a live database, generate from a pinned snapshot instead:

             mix ash_strangler.gen.twin --from-snapshot priv/legacy/snapshot/catalog.json --relation ...
         """}
    end

    defp present(targets, catalog, snapshot) do
      case Enum.reject(targets, &Map.has_key?(catalog["relations"], &1.relation)) do
        [] ->
          :ok

        missing ->
          {:error,
           "#{Enum.map_join(missing, ", ", &"`#{&1.relation}`")} is not a relation in " <>
             if(snapshot,
               do: "the snapshot #{snapshot}.",
               else: "the database (or not visible to its role)."
             )}
      end
    end

    # A twin in a domain that does not exist is a resource nothing can read
    # through: `Ash.Domain.Info.resources/1` never returns it, so
    # `mix ash_strangler.check` cannot find it and neither can a mapping. And the
    # first run of this task is exactly the run where the domain does not exist
    # yet, because twins belong in a domain of their own.
    defp ensure_domains(igniter, twins) do
      twins
      |> Enum.map(& &1.domain)
      |> Enum.uniq()
      |> Enum.reduce(igniter, fn domain, igniter ->
        Igniter.compose_task(igniter, "ash.gen.domain", [inspect(domain), "--ignore-if-exists"])
      end)
    end

    defp write(igniter, twin, run) do
      {igniter, existing} = existing_options(igniter, twin.module)
      snapshot = run.snapshot || existing.snapshot

      contents =
        AshStrangler.Twin.Generator.render(%{
          relation: twin.relation,
          catalog: run.catalog,
          module: twin.module,
          domain: twin.domain,
          repo: run.repo,
          destination: &destination_module(&1, run.targets),
          secrets: Enum.uniq(existing.secrets ++ run.secrets),
          snapshot: snapshot,
          watch: existing.watch,
          system_actor: run.system_actor || existing.system_actor,
          command: command(twin, run.repo, snapshot)
        })

      {igniter, path} = location(igniter, twin.module)

      igniter
      |> Igniter.create_new_file(path, contents, on_exists: :overwrite)
      |> wire_domain(twin.domain, twin.module)
      |> Igniter.add_notice("""
      #{inspect(twin.module)} is the twin for `#{twin.relation}`. Point a resource at it:

          strangler do
            phase :read_from_legacy

            source #{inspect(twin.module)} do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "..."}
              map :login, from: :login
            end
          end

      Then `mix ash_strangler.check`, which measures against the legacy rows what
      the compiler could not decide from the declaration.
      """)
    end

    # Regeneration writes over the twin wherever it already lives, because the
    # whole point of the task is that it can be run again -- a twin that could
    # only be generated once would be a schema snapshot nobody dares refresh.
    #
    # The exception is a file holding more than one module: the twin is rewritten
    # wholesale, so overwriting a file the generator does not own would delete
    # somebody else's code. That case gets the module's canonical location and a
    # warning naming both, rather than a silent choice either way.
    defp location(igniter, module) do
      case Igniter.Project.Module.find_module(igniter, module) do
        {:ok, {igniter, source, _zipper}} ->
          path = Rewrite.Source.get(source, :path)

          if sole_module?(source) do
            {igniter, path}
          else
            proper = Igniter.Project.Module.proper_location(igniter, module)

            {Igniter.add_warning(igniter, """
             #{inspect(module)} is already defined in #{path}, alongside other modules,
             so this run wrote #{proper} instead of replacing it.

             A generated twin is rewritten in full on every run. Overwriting a file that
             also holds hand-written modules would delete them, so the two definitions now
             coexist. Move the twin into a file of its own -- #{proper} is where the
             generator will keep it -- and delete the old definition.
             """), proper}
          end

        {:error, igniter} ->
          {igniter, Igniter.Project.Module.proper_location(igniter, module)}
      end
    end

    defp sole_module?(source) do
      source
      |> Rewrite.Source.get(:content)
      |> then(&Regex.scan(~r/^defmodule /m, &1))
      |> length()
      |> Kernel.<=(1)
    end

    # `Ash.Domain.Igniter.add_resource_reference/3` reaches for its
    # create-the-domain path whenever the module is not in the application's
    # `ash_domains` config, which is not the same question as whether it is a
    # domain -- and answering the wrong one appends a second `use Ash.Domain` to a
    # file that already has one. So an existing module is edited directly, and the
    # helper is used only for the case it is right about: no module at all.
    defp wire_domain(igniter, domain, module) do
      case Igniter.Project.Module.find_and_update_module(
             igniter,
             domain,
             &declare_resource(&1, module)
           ) do
        {:ok, igniter} -> igniter
        {:error, igniter} -> Ash.Domain.Igniter.add_resource_reference(igniter, domain, module)
      end
    end

    defp declare_resource(zipper, module) do
      case Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :resources, 1) do
        :error ->
          {:ok,
           Igniter.Code.Common.add_code(zipper, """
           resources do
             resource #{inspect(module)}
           end
           """)}

        {:ok, resources} ->
          with {:ok, body} <- Igniter.Code.Common.move_to_do_block(resources),
               :error <- find_resource(body, module) do
            {:ok, Igniter.Code.Common.add_code(body, "resource #{inspect(module)}")}
          else
            _already_declared -> {:ok, zipper}
          end
      end
    end

    defp find_resource(zipper, module) do
      Igniter.Code.Function.move_to_function_call_in_current_scope(
        zipper,
        :resource,
        [1, 2],
        &Igniter.Code.Function.argument_equals?(&1, 0, module)
      )
    end

    # --- foreign key targets ------------------------------------------------

    # Resolvable only against a twin that will exist. Pointing a `belongs_to` at a
    # module nobody generated produces a resource that does not compile, which is a
    # worse outcome than a missing relationship -- and the missing one is visible,
    # because the mapping that wanted it fails with the path it could not resolve.
    defp destination_module(relation, targets) do
      case Enum.find(targets, &(&1.relation == relation)) do
        %{module: module} ->
          module

        nil ->
          Enum.find(existing_twins(), fn twin -> AshStrangler.Twin.relation(twin) == relation end)
      end
    end

    defp existing_twins do
      Application.get_env(:ash, :ash_domains, [])
      |> Kernel.++(
        Enum.flat_map(Application.loaded_applications(), fn {app, _, _} ->
          Application.get_env(app, :ash_domains, [])
        end)
      )
      |> Enum.uniq()
      |> Enum.filter(&Code.ensure_loaded?/1)
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.filter(&AshStrangler.Twin.twin?/1)
    end

    # Every option spelled out rather than only the ones that were typed, so the
    # line reproduces the file. A provenance comment that leans on today's defaults
    # stops reproducing it the day a default changes, and nothing reports that.
    defp command(twin, repo, snapshot) do
      " --relation #{twin.relation}" <>
        " --module #{inspect(twin.module)}" <>
        " --domain #{inspect(twin.domain)}" <>
        " --repo #{inspect(repo)}" <>
        if(snapshot, do: " --from-snapshot #{snapshot}", else: "")
    end

    # --- existing twin options --------------------------------------------

    # Read from the twin's SOURCE, not its compiled module: the twin being
    # regenerated is often the one that no longer compiles, because the
    # snapshot moved and `VerifySnapshot` refused it. Losing its `secrets` on
    # regeneration would put a secret column back on the twin, so they are
    # carried over from the file whatever state the build is in.
    defp existing_options(igniter, module) do
      case Igniter.Project.Module.find_module(igniter, module) do
        {:ok, {igniter, _source, zipper}} ->
          {igniter,
           %{
             secrets: zipper |> literal(:secrets) |> List.wrap() |> Enum.map(&to_string/1),
             watch: literal(zipper, :watch),
             snapshot: literal(zipper, :snapshot),
             system_actor: source_text(zipper, :system_actor)
           }}

        {:error, igniter} ->
          {igniter, %{secrets: [], watch: nil, snapshot: nil, system_actor: nil}}
      end
    end

    # A module alias is not a literal, so it is carried over as source text.
    defp source_text(zipper, name) do
      with {:ok, call} <- Igniter.Code.Function.move_to_function_call(zipper, name, 1),
           {:ok, argument} <- Igniter.Code.Function.move_to_nth_argument(call, 0) do
        argument |> Sourceror.Zipper.node() |> Sourceror.to_string()
      else
        _ -> nil
      end
    end

    defp literal(zipper, name) do
      with {:ok, call} <- Igniter.Code.Function.move_to_function_call(zipper, name, 1),
           {:ok, argument} <- Igniter.Code.Function.move_to_nth_argument(call, 0),
           {:ok, value} <- Igniter.Code.Common.expand_literal(argument) do
        value
      else
        _ -> nil
      end
    end
  end
else
  defmodule Mix.Tasks.AshStrangler.Gen.Twin do
    @shortdoc "Generates a twin resource | Install `igniter` to use"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_strangler.gen.twin' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
