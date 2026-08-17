# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshStrangler.Gen.Twin do
    @shortdoc "Generates a twin resource by introspecting a live legacy relation"

    @example "mix ash_strangler.gen.twin --relation legacy.users --module MyApp.Legacy.Users"

    @moduledoc """
    Reads a legacy relation out of the database and writes it back as an Ash
    resource — a *twin*. See `AshStrangler.Twin` for what one is and why the
    mapping needs it.

        #{@example}
        mix ash_strangler.gen.twin --relation legacy.users --relation legacy.addresses
        mix ash_strangler.gen.twin --relation legacy.users --dry-run

    ## The legacy schema is read, never retyped

    A `strangler` mapping says `expr(first_name)`, and `first_name` has to resolve
    against something. The alternative to a twin — declaring the legacy columns
    inline in the mapping — restates by hand a schema the database already knows,
    which is the defect the whole typed layer exists to remove. So the columns,
    their types, the primary key, the unique indexes and the foreign keys all come
    from `pg_attribute`, `pg_index` and `pg_constraint`, and this task is the only
    place they are written down.

    The twin is therefore a **snapshot**, and snapshots go stale: a column the
    legacy application's next migration adds is invisible until this task is run
    again. `mix ash_strangler.check` diffs every twin against
    `information_schema.columns` and reports the difference, which is the honest
    mitigation. Run it in CI.

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

    ## Why this introspects directly rather than wrapping `mix ash_postgres.gen.resources`

    `ash_postgres` ships a resource generator, and reusing it was the first thing
    tried. It generates resources for a schema an application is *adopting* — so it
    emits no `migrate? false`, it derives no `one_of`, and it wires the result into
    migration snapshot generation, which is exactly the opposite of what a twin
    wants: Ash must never own this table.

    Reaching that output and then rewriting it — deleting the snapshot task,
    inserting `migrate? false`, retyping the columns that carry a `CHECK` — is more
    code than reading `pg_attribute` directly, and it is code that breaks whenever
    the other generator's output shape changes. The `one_of` inference needs
    `pg_constraint` regardless, so the connection and the queries exist either way.

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
        schema: [relation: :keep, module: :string, repo: :string, domain: :string],
        aliases: [r: :relation, m: :module, d: :domain]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Mix.Task.run("compile")

      options = igniter.args.options

      case resolve(igniter.args.positional[:module], options) do
        {:ok, targets, repo} -> generate(igniter, targets, repo)
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

    defp generate(igniter, targets, repo) do
      case introspect(repo, targets) do
        {:ok, twins} ->
          twins
          |> Enum.reduce(ensure_domains(igniter, twins), &write(&2, &1, repo))

        {:error, message} ->
          Igniter.add_issue(igniter, message)
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

    defp introspect(repo, targets) do
      Ecto.Migrator.with_repo(repo, fn repo ->
        Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
          case read_relation(repo, target, targets) do
            {:ok, twin} -> {:cont, {:ok, acc ++ [twin]}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)
      end)
      |> case do
        {:ok, result, _apps} ->
          result

        {:error, reason} ->
          {:error,
           """
           Could not start #{inspect(repo)} to introspect the legacy schema: #{inspect(reason)}

           This task reads the live database. There is no offline mode, deliberately:
           a twin written from anything other than the schema that actually exists is
           the hand-restatement the typed layer was built to delete.
           """}
      end
    end

    defp write(igniter, twin, repo) do
      contents = render(twin, repo)
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

    # --- introspection -----------------------------------------------------

    @columns_query """
    SELECT a.attname,
           t.typname,
           t.typtype,
           t.typcategory,
           (SELECT et.typname FROM pg_type et WHERE et.oid = t.typelem),
           (SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
              FROM pg_enum e WHERE e.enumtypid = t.oid),
           a.attnotnull,
           format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE a.attrelid = $1::text::regclass
       AND a.attnum > 0
       AND NOT a.attisdropped
     ORDER BY a.attnum
    """

    # `WITH ORDINALITY` rather than `= ANY(indkey)`, because a composite key's
    # column ORDER is part of the key and `= ANY` discards it.
    @primary_key_query """
    SELECT a.attname
      FROM pg_index x
     CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum
     WHERE x.indrelid = $1::text::regclass AND x.indisprimary
     ORDER BY k.ord
    """

    # `indpred IS NULL` excludes partial unique indexes. A partial index does not
    # make the column unique -- it makes it unique among the rows matching the
    # predicate -- and an Ash identity means unconditional uniqueness. Declaring
    # one from a partial index would be a claim Postgres does not back, which is
    # the exact thing `mix ash_strangler.check` exists to catch.
    @unique_query """
    SELECT i.relname,
           array_agg(a.attname ORDER BY k.ord),
           x.indisprimary
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
     CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum
     WHERE x.indrelid = $1::text::regclass
       AND x.indisunique
       AND x.indpred IS NULL
     GROUP BY i.relname, x.indisprimary
     ORDER BY i.relname
    """

    @foreign_keys_query """
    SELECT con.conname,
           array_agg(sa.attname ORDER BY k.ord),
           fn.nspname,
           fc.relname,
           array_agg(ta.attname ORDER BY k.ord)
      FROM pg_constraint con
     CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(src, tgt, ord)
      JOIN pg_attribute sa ON sa.attrelid = con.conrelid AND sa.attnum = k.src
      JOIN pg_class fc ON fc.oid = con.confrelid
      JOIN pg_namespace fn ON fn.oid = fc.relnamespace
      JOIN pg_attribute ta ON ta.attrelid = con.confrelid AND ta.attnum = k.tgt
     WHERE con.conrelid = $1::text::regclass AND con.contype = 'f'
     GROUP BY con.conname, fn.nspname, fc.relname
     ORDER BY con.conname
    """

    @checks_query """
    SELECT a.attname, pg_get_constraintdef(con.oid)
      FROM pg_constraint con
      JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
     WHERE con.conrelid = $1::text::regclass
       AND con.contype = 'c'
       AND array_length(con.conkey, 1) = 1
    """

    defp read_relation(repo, target, all_targets) do
      %{rows: column_rows} = repo.query!(@columns_query, [target.relation])
      %{rows: pk_rows} = repo.query!(@primary_key_query, [target.relation])
      %{rows: unique_rows} = repo.query!(@unique_query, [target.relation])
      %{rows: fk_rows} = repo.query!(@foreign_keys_query, [target.relation])
      %{rows: check_rows} = repo.query!(@checks_query, [target.relation])

      if column_rows == [] do
        {:error, "`#{target.relation}` has no columns. Is it the relation you meant?"}
      else
        checks = Map.new(check_rows, fn [column, definition] -> {column, definition} end)
        primary_key = Enum.map(pk_rows, fn [column] -> column end)
        columns = Enum.map(column_rows, &column(&1, checks, primary_key))

        {:ok,
         Map.merge(target, %{
           columns: columns,
           identities: identities(unique_rows, columns),
           relationships: relationships(fk_rows, columns, all_targets)
         })}
      end
    rescue
      error in [Postgrex.Error] ->
        {:error,
         """
         Could not read `#{target.relation}`: #{Exception.message(error)}

         The relation is resolved with `::regclass`, so it must exist and be visible
         to #{inspect(repo)}'s role.
         """}
    end

    # --- columns -----------------------------------------------------------

    @types %{
      "int2" => ":integer",
      "int4" => ":integer",
      "int8" => ":integer",
      "float4" => ":float",
      "float8" => ":float",
      "numeric" => ":decimal",
      "bool" => ":boolean",
      "text" => ":string",
      "varchar" => ":string",
      "bpchar" => ":string",
      "citext" => ":ci_string",
      "uuid" => ":uuid",
      "date" => ":date",
      "time" => ":time",
      "timestamp" => ":naive_datetime",
      "timestamptz" => ":utc_datetime_usec",
      "json" => ":map",
      "jsonb" => ":map",
      "bytea" => ":binary"
    }

    @textual ~w(text varchar bpchar citext)

    defp column(
           [name, typname, typtype, typcategory, element, enum_labels, not_null, formatted],
           checks,
           primary_key
         ) do
      base = %{
        column: name,
        name: attribute_name(name),
        allow_nil?: not (not_null or name in primary_key),
        primary_key?: name in primary_key,
        pg_type: formatted,
        type: nil,
        one_of: nil,
        note: nil
      }

      cond do
        is_nil(base.name) ->
          %{base | type: nil, note: unnameable_note(name)}

        typtype == "e" ->
          %{base | type: ":atom", one_of: Enum.map(enum_labels, &String.to_atom/1)}

        typcategory == "A" ->
          array_column(base, element)

        typname in @textual ->
          textual_column(base, checks[name])

        type = @types[typname] ->
          %{base | type: type}

        true ->
          %{base | type: nil, note: untyped_note(name, formatted)}
      end
    end

    defp array_column(base, element) do
      case @types[element] do
        nil -> %{base | type: nil, note: untyped_note(base.column, base.pg_type)}
        type -> %{base | type: "{:array, #{type}}"}
      end
    end

    defp textual_column(base, nil), do: %{base | type: ":string"}

    defp textual_column(base, definition) do
      case value_set(definition, base.column) do
        {:ok, values} ->
          %{base | type: ":atom", one_of: values}

        :error ->
          %{
            base
            | type: ":string",
              note: """
              `#{base.column}` carries a CHECK constraint this generator did not parse:

                #{definition}

              Only `CHECK (col IN (...))` -- which PostgreSQL stores as `= ANY (ARRAY[...])`
              -- yields a value set. Without one there is no domain to enumerate, so a
              `decode` over this column cannot be proven total at compile time and
              `mix ash_strangler.check` measures it against the rows instead.

              If the column really does range over a fixed set, adding
              `constraints one_of: [...]` here by hand is a claim about the legacy data
              that nothing checks -- prefer the CHECK constraint, or leave it measured.
              """
          }
      end
    end

    defp untyped_note(column, formatted) do
      """
      `#{column}` is `#{formatted}`, which has no Ash type, so it is not declared here.

      A mapping cannot read it as a typed reference. It is reachable only through
      `expr(fragment("..."))`, which classifies opaque -- no derived inverse, no
      lineage, `because:` required. `mix ash_strangler.check` will report it as a
      column the twin does not declare, which is the truth rather than drift.
      """
    end

    defp unnameable_note(column) do
      """
      `#{column}` has no name Elixir will accept as an attribute, so it is not
      declared here. Ash's `source:` carries a column whose name merely differs from
      its attribute's -- it cannot supply a name where none can be formed.
      """
    end

    # A column name Elixir would not want as an atom keeps its real name in Ash's
    # `source:`, which is what `AshStrangler.Twin.column!/2` reads.
    defp attribute_name(column) do
      underscored = Macro.underscore(column)

      if underscored =~ ~r/^[a-z][a-z0-9_]*$/, do: String.to_atom(underscored), else: nil
    end

    # --- the CHECK parse ---------------------------------------------------

    # PostgreSQL rewrites `IN (...)` into `= ANY (ARRAY[...])` and prints the
    # result, so that is the only shape worth matching. Both variants appear: a
    # `text` column gives `(col = ANY (ARRAY['a'::text, ...]))` and a `varchar` one
    # gives `((col)::text = ANY ((ARRAY['a'::character varying, ...])::text[]))`.
    #
    # The whole expression must match. A constraint that merely CONTAINS a value
    # set -- `col = ANY(...) AND other IS NOT NULL` -- is refused, because the
    # extra conjunct may exclude values from the set and a `one_of` that is too
    # wide is as wrong as one that is too narrow.
    defp value_set(definition, column) do
      body = strip_check(definition)

      with true <- any_form?(body, column),
           [_ | _] = literals <- literals(body) do
        {:ok, Enum.map(literals, &String.to_atom/1)}
      else
        _ -> equality_form(body, column)
      end
    end

    defp strip_check(definition) do
      definition
      |> String.replace(~r/^CHECK\s*\(/, "")
      |> String.replace(~r/\)$/, "")
      |> String.trim()
      |> unwrap_parens()
    end

    defp unwrap_parens("(" <> rest = body) do
      if String.ends_with?(rest, ")") and balanced?(String.slice(rest, 0..-2//1)) do
        rest |> String.slice(0..-2//1) |> String.trim() |> unwrap_parens()
      else
        body
      end
    end

    defp unwrap_parens(body), do: body

    defp balanced?(body) do
      body
      |> String.graphemes()
      |> Enum.reduce_while(0, fn
        _grapheme, depth when depth < 0 -> {:halt, -1}
        "(", depth -> {:cont, depth + 1}
        ")", depth -> {:cont, depth - 1}
        _grapheme, depth -> {:cont, depth}
      end)
      |> Kernel.==(0)
    end

    defp any_form?(body, column) do
      Regex.match?(~r/^\(?"?#{Regex.escape(column)}"?\)?(::[a-z ]+)?\s*=\s*ANY\s*\(/i, body) and
        String.contains?(body, "ARRAY[")
    end

    # Quoted literals are scanned rather than the ARRAY body split on commas: a
    # value may contain a comma, and `''` is how a quote is escaped inside one.
    defp literals(body) do
      ~r/'((?:[^']|'')*)'/
      |> Regex.scan(body)
      |> Enum.map(fn [_match, literal] -> String.replace(literal, "''", "'") end)
    end

    # `CHECK (col IN ('only'))` collapses to a plain equality, and a one-value
    # domain is still a domain.
    defp equality_form(body, column) do
      case Regex.run(
             ~r/^\(?"?#{Regex.escape(column)}"?\)?(?:::[a-z ]+)?\s*=\s*'((?:[^']|'')*)'(?:::[a-z \[\]]+)?$/i,
             body
           ) do
        [_match, literal] -> {:ok, [literal |> String.replace("''", "'") |> String.to_atom()]}
        _ -> :error
      end
    end

    # --- identities and relationships --------------------------------------

    # The primary key index is skipped: it is already stated as `primary_key? true`,
    # and `AshStrangler.Twin.unique_column_sets/1` folds the primary key in, so
    # declaring it again as an identity would double-count it.
    defp identities(unique_rows, columns) do
      declared = Map.new(columns, &{&1.column, &1})

      unique_rows
      |> Enum.reject(fn [_name, _columns, primary?] -> primary? end)
      |> Enum.flat_map(fn [name, index_columns, _primary?] ->
        keys = Enum.map(index_columns, fn column -> declared[column] end)

        if Enum.all?(keys, &(not is_nil(&1) and not is_nil(&1.name))) do
          [%{name: String.to_atom(name), keys: Enum.map(keys, & &1.name)}]
        else
          []
        end
      end)
    end

    # A foreign key is what replaced the v1 `join ... on: "raw sql"`: the join
    # condition is a property of a declared relationship rather than of an opaque
    # predicate, so `AshStrangler.Info.joins/1` can discover it and
    # `AshStrangler.Twin.joins_for/2` can refuse the ones that fan out.
    defp relationships(fk_rows, columns, all_targets) do
      declared = Map.new(columns, &{&1.column, &1})

      Enum.flat_map(fk_rows, fn
        [name, [source_column], schema, table, [destination_column]] ->
          source = declared[source_column]
          destination = destination_module(schema, table, all_targets)

          if source && source.name && destination && attribute_name(destination_column) do
            [
              %{
                name: relationship_name(source_column, table),
                constraint: name,
                destination: destination,
                source_attribute: source.name,
                destination_attribute: attribute_name(destination_column)
              }
            ]
          else
            []
          end

        # A composite foreign key. `belongs_to` carries one `source_attribute` and
        # one `destination_attribute`, so there is no shape to emit -- and inventing
        # a single-column approximation would produce a join condition weaker than
        # the constraint, which is how a mapping starts returning the wrong row.
        _composite ->
          []
      end)
    end

    # Resolvable only against a twin that will exist. Pointing a `belongs_to` at a
    # module nobody generated produces a resource that does not compile, which is a
    # worse outcome than a missing relationship -- and the missing one is visible,
    # because the mapping that wanted it fails with the path it could not resolve.
    defp destination_module(schema, table, all_targets) do
      relation = "#{schema}.#{table}"

      case Enum.find(all_targets, &(&1.relation == relation)) do
        %{module: module} ->
          module

        nil ->
          Enum.find(existing_twins(), fn twin ->
            AshStrangler.Twin.relation(twin) == relation
          end)
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
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.filter(&AshStrangler.Twin.twin?/1)
    end

    defp relationship_name(source_column, table) do
      case String.replace_suffix(source_column, "_id", "") do
        ^source_column -> attribute_name(table)
        stripped -> attribute_name(stripped)
      end
    end

    # --- rendering ---------------------------------------------------------

    defp render(twin, repo) do
      """
      defmodule #{inspect(twin.module)} do
        #{moduledoc(twin, repo)}

        use Ash.Resource,
          domain: #{inspect(twin.domain)},
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Twin]

        postgres do
          table #{inspect(twin.table)}
          schema #{inspect(twin.schema)}
          repo #{inspect(repo)}
          # Ash does not own this table and never will.
          migrate? false
        end

        attributes do
      #{indent(attributes(twin), 4)}
        end
      #{identities_block(twin)}#{relationships_block(twin)}
        actions do
          defaults [:read]
        end
      end
      """
    end

    defp moduledoc(twin, repo) do
      """
      @moduledoc \"\"\"
      The twin for `#{twin.relation}` — the legacy relation, declared as an
      ordinary Ash resource so a mapping can name its columns and have them mean
      something. See `AshStrangler.Twin`.

      Generated by:

          mix ash_strangler.gen.twin#{command(twin, repo)}

      Hand edits are lost the next time that runs. It is a snapshot of a schema
      this application does not own, so it goes stale silently — `mix
      ash_strangler.check` diffs it against `information_schema.columns` and says
      so.
      \"\"\"
      """
      |> String.trim_trailing()
    end

    # Every option spelled out rather than only the ones that were typed, so the
    # line reproduces the file. A provenance comment that leans on today's defaults
    # stops reproducing it the day a default changes, and nothing reports that.
    defp command(twin, repo) do
      " --relation #{twin.relation}" <>
        " --module #{inspect(twin.module)}" <>
        " --domain #{inspect(twin.domain)}" <>
        " --repo #{inspect(repo)}"
    end

    defp attributes(twin), do: Enum.map_join(twin.columns, "\n\n", &attribute/1)

    defp attribute(%{type: nil} = column), do: comment(column.note)

    defp attribute(column) do
      declaration =
        if column.one_of do
          block_attribute(column)
        else
          inline_attribute(column)
        end

      case column.note do
        nil -> declaration
        note -> comment(note) <> "\n" <> declaration
      end
    end

    defp inline_attribute(column) do
      "attribute #{inspect(column.name)}, #{column.type}, " <>
        Enum.join(options(column), ", ")
    end

    # The block form only when there is a `constraints` to carry. `constraints` in
    # the keyword form takes a nested list, which reads worse than the block for the
    # one case that needs it, and every other attribute is a single line.
    defp block_attribute(column) do
      body =
        options(column)
        |> Enum.map(&String.replace(&1, ": ", " ", global: false))
        |> Kernel.++(["constraints one_of: #{inspect(column.one_of)}"])
        |> Enum.join("\n")

      """
      attribute #{inspect(column.name)}, #{column.type} do
      #{indent(body, 2)}
      end
      """
      |> String.trim_trailing()
    end

    defp options(column) do
      [
        if(column.primary_key?, do: "primary_key?: true"),
        if(not column.allow_nil?, do: "allow_nil?: false"),
        "public?: true",
        if(to_string(column.name) != column.column,
          do: "source: #{inspect(String.to_atom(column.column))}"
        )
      ]
      |> Enum.reject(&is_nil/1)
    end

    defp identities_block(%{identities: []}), do: ""

    defp identities_block(twin) do
      """

        identities do
      #{Enum.map_join(twin.identities, "\n", &"    identity #{inspect(&1.name)}, #{inspect(&1.keys)}")}
        end
      """
    end

    defp relationships_block(%{relationships: []}), do: ""

    defp relationships_block(twin) do
      """

        relationships do
      #{Enum.map_join(twin.relationships, "\n\n", &indent(relationship(&1), 4))}
        end
      """
    end

    # `define_attribute? false` because the foreign key column is already declared
    # in `attributes` from `pg_attribute`. Letting the relationship define it too
    # gives two declarations of one column, and Ash refuses the resource.
    defp relationship(relationship) do
      """
      belongs_to #{inspect(relationship.name)}, #{inspect(relationship.destination)} do
        source_attribute #{inspect(relationship.source_attribute)}
        destination_attribute #{inspect(relationship.destination_attribute)}
        define_attribute? false
        public? true
      end
      """
      |> String.trim_trailing()
    end

    defp comment(text) do
      text
      |> String.trim_trailing()
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> "#"
        line -> "# " <> line
      end)
    end

    defp indent(text, spaces) do
      padding = String.duplicate(" ", spaces)

      text
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> padding <> line
      end)
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
