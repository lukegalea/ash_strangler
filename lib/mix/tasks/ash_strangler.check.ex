# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Check do
  @shortdoc "Runs the new model's assertions against the legacy data"

  @moduledoc """
  Reports the strangler mapping for every resource that has one, and **runs the
  assertions the new model implies against the rows the legacy application
  actually wrote**.

      mix ash_strangler.check
      mix ash_strangler.check --domain MyApp.Accounts
      mix ash_strangler.check --no-data
      mix ash_strangler.check --strict
      mix ash_strangler.check --estate MyApp.Legacy.Estate --report obligations.json

  ## Proven, or measured — never asserted

  The compile-time verifiers decide what is decidable from the declaration. This
  task answers what is not, and the distinction is the whole design: an obligation
  with an unbounded value space, a `fragment` the BEAM cannot evaluate, a
  `coalesce` default that may also be a legal stored value, a `concat` separator
  that may occur inside an operand. `AshStrangler.Obligations` emits each of those
  as SQL rather than guessing, and this is what runs it.

  The rule those obligations follow from is worth restating, because it is the
  reason this task exists rather than a longer property test: **round-tripping has
  to be checked over the legacy value space, because that is the only space
  containing rows the tool did not create.** This package's own 0.1 fixtures
  round-tripped perfectly over `state_code <- member_of([0, 1])` — the one value
  set on which the mapping was a bijection — while the legacy column ranged over
  five values and three of them were destroyed by any write.

  ## What it runs

  Each assertion is an ordinary read over the twin, which is why they can exist at
  all: 0.1 had no typed legacy relation, so there was nothing for a query to be
  built against and this task could only print a list of checks it told you to make
  yourself.

  | Model assertion | Measured as |
  |---|---|
  | `allow_nil? false` on a mapped attribute | rows whose source expression is NULL |
  | an Ash `identity` | duplicate groups over the *normalised* legacy expression |
  | a cast | the mapping projected over the twin, and the rows that will not cast |
  | every `AshStrangler.Obligations` assertion | run verbatim, result reported |
  | twin freshness | the twin's columns against `information_schema.columns` |
  | twin columns | each column the twin declares against what `gen.twin` would write for it today: a widened `one_of` fails, a changed coarse type fails |
  | column types | the type each mapping yields against the type its attribute stores, with no row read |
  | twin identities | the twin's unique sets against `pg_index` |
  | a relationship-derived join | row counts through the join, for fan-out |
  | a `ledger?` source | unprocessed `legacy_change_events` rows per relation |

  Two of those deserve their own note.

  **Normalisation is the type, not a parameter.** An identity on a `:ci_string`
  attribute means the uniqueness Ash believes in is case-insensitive, while the
  legacy unique index over a `text` column is not. So the duplicate check groups by
  the mapping's *forward expression* — which already carries the derived
  `::citext` — rather than by the raw column. In 0.1 the same fact was written a
  third time, as the reconciler's `normalize: %{email: :ci_string}`.

  **A twin identity Postgres does not enforce is worse than no identity.** Ash
  plans upserts against it and reports "has already been taken" from a `SELECT`,
  while duplicates continue to be accepted by the write path. So the twin's unique
  sets are compared against `pg_index`, and a partial unique index does not count:
  it makes a column unique among the rows matching its predicate, which is not what
  an identity claims. Nor does an expression index: `UNIQUE (tenant_id, lower(email))`
  is not a unique `tenant_id`. Only an index's key columns count, never its
  `INCLUDE` columns.

  ## What the twin is held to

  Freshness answers whether the twin has the right *columns*. **Twin columns**
  answers whether the columns it has still mean what it says. For every column the
  twin declares, `AshStrangler.Twin.Introspection` re-derives what
  `mix ash_strangler.gen.twin` would write against the live catalog (read through
  `pg_catalog`, by schema and name, so a relation that has gone is an absent
  relation and never a raised cast), and the two are compared:

  | The catalog now says | Result |
  |---|---|
  | an enum label or `CHECK` value the twin's `one_of` lacks | **FAIL**, naming the mappings that read the column |
  | a different coarse Ash type | **FAIL** |
  | the twin's `one_of` lists a value the column no longer admits | warn |
  | a `one_of` on the twin, and no value set in the catalog | warn |
  | `allow_nil?` differs | warn: the null checks count the NULLs the rows really hold |

  The widened set is the finding that matters. With a `one_of` present and every
  value decoded, `AshStrangler.Obligations` proves `GetTotal` at compile time and
  emits no assertion, so a label added to the enum afterwards is a value that
  nothing re-checks. Value sets are compared as sets. Types are compared coarsely
  (`int4` and `int8` are one integer, `timestamp` and `timestamptz` are not),
  and `citext` is not `text`.

  A hand-written twin is accepted, so only what the twin declares is compared,
  under the column name its `source:` gives. A column it leaves out is the
  freshness check's to report, and a value set it does not state is not asked for.
  A relation that is absent stays a **FAIL** of the freshness check and adds
  nothing here.

  **Column types** is a warning-level step per resource. For each projection the
  cast check runs, it asks Postgres for the type of the expression without
  executing it, and compares with what the attribute stores. A Postgres enum and a
  type with no Ash type are reported as such, never read as a match. Typmods
  (`numeric(10, 2)`, `varchar(20)`) are not compared. **A pass is not a statement
  about the rows**: a matching type does not show that every row casts, and that
  is a question about data the cast check puts to the data.

  ## The estate obligation report

  `--estate [Estate ...]` measures the obligations of an estate
  (`AshStrangler.Estate.Obligations`) instead of the per-resource report, and
  `--report FILE` writes the result as canonical JSON (format
  `ash_strangler.obligations/1`, keyed by the sha256 of the snapshot catalog,
  ordered, with no timestamp). With no estate named it uses the
  application's `:ash_strangler_estates`. `--no-data` skips the queries: every
  obligation is then `skipped`. Exits 1 when an obligation fails or cannot be
  measured, or when the estate has a problem.

  ## Exit code

  Non-zero when an assertion fails (a widened value set and a changed coarse type
  are assertions; the rest of the twin comparison, and the column types, are
  warnings), so the twin-staleness diff can gate CI —
  without that the typed layer inherits exactly the staleness problem it was built
  to remove. Warnings do not fail: guard overlap that holds for no row the data
  contains is a warning by construction, and refusing on it would refuse correct
  mappings.

  A check that could not *run* is reported as `????`, which is not a failure by
  default: "could not be measured" and "measured clean" are different answers, and
  the report says which one each line is. That covers a query the database
  rejected and a repo that could not be resolved or started. A `warn` line that
  says nothing was measured is the same answer, and does not fail by default either.

  The cast check is the exception, because a cast failure can only show up as a
  query error. A query it cannot run is a `FAIL`, so a legacy relation this
  environment does not have fails the task here, and in the twin freshness check,
  even though other checks print `????` for it. The one case it separates out is a
  database that cannot be reached: a connection error is reported as
  `database could not be reached`, once per resource rather than once per
  attribute because it says nothing about any attribute, and **fails the task**. A
  gate that stayed green because the database was down would have measured nothing.
  The other checks against that database still print their own `????` lines.

  ## `--strict`

  `--strict` makes the task exit non-zero on every outcome that could not be
  measured, because collapsing "could not be measured" into "passed" is how a
  green build comes to mean nothing:

    * every `????` line, including a repo that could not be resolved or started;
    * a warning whose message says nothing was measured: a required attribute no
      mapping accounts for, an identity key with no mapping to group by, a mapping
      that yields a Postgres enum or a type with no Ash type, and a twin column that
      could not be compared with the catalog;
    * no resources found, which includes a `--domain` that names no domain.

  The count of such checks is printed before the task exits. `--no-data` is a
  request not to measure and is not counted, and `--estate` already fails when an
  obligation cannot be measured, so `--strict` changes nothing there.

      mix ash_strangler.check --domain MyApp.Accounts --strict

  Run it before every phase change. The phases are one-way in practice: moving to
  `:read_from_new` while the backfill is incomplete produces missing rows, not an
  error.
  """

  use Mix.Task

  alias AshStrangler.{Info, Lens, Mechanism, Obligations, Sql.Ledger, Twin}
  alias AshStrangler.Sql.{Printer, View}
  alias AshStrangler.Twin.Introspection

  @requirements ["app.config"]

  @switches [domain: :string, data: :boolean, estate: :boolean, report: :string, strict: :boolean]

  @ok "\e[32mok\e[0m  "
  @fail "\e[31mFAIL\e[0m"
  @warn "\e[33mwarn\e[0m"
  @unrun "\e[33m????\e[0m"

  # The report's label column is thirteen characters wide. Interpolated strings are
  # not de-indented by the heredoc they land in, so a continuation line has to
  # count them out itself.
  @continued "\n             "

  # What a check reports back: assertions that failed, and checks that could not
  # be measured. They are separate counts because only the first fails the task
  # by default, and `--strict` is the switch that makes the second fail it too.
  @none {0, 0}

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)

    if opts[:estate], do: estate_report(rest, opts), else: resource_report(opts)
  end

  defp estate_report(names, opts) do
    Mix.Task.run("compile")

    reports =
      for estate <- Mix.Tasks.AshStrangler.Estate.estates(names) do
        report = AshStrangler.Estate.Obligations.report(estate, measure?: opts[:data] != false)
        {estate, report}
      end

    if path = opts[:report] do
      if length(reports) != 1,
        do: Mix.raise("--report needs exactly one estate, got #{length(reports)}")

      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        reports |> hd() |> elem(1) |> AshStrangler.Snapshot.Catalog.encode()
      )
    end

    for {estate, report} <- reports do
      s = report["summary"]

      Mix.shell().info(
        "#{inspect(estate)}: #{s["total"]} obligations: #{s["pass"]} pass, #{s["warn"]} warn, " <>
          "#{s["fail"]} fail, #{s["error"]} error, #{s["skipped"]} skipped; #{length(report["problems"])} estate problems"
      )

      for row <- report["obligations"], row["status"] in ["fail", "error", "warn"] do
        Mix.shell().info(
          "  #{row["status"]}  #{row["id"]}  #{row["violations"] || row["detail"]}"
        )
      end
    end

    if Enum.any?(reports, fn {_, report} -> AshStrangler.Estate.Obligations.failed?(report) end),
      do: exit({:shutdown, 1})
  end

  defp resource_report(opts) do
    resources = strangled_resources(opts[:domain])

    if resources == [] do
      no_resources(opts)
    else
      Enum.each(resources, &report/1)

      # Target declarations live outside the DSL's reach — Spark does not
      # persist which fragments a resource attached — so this is where the
      # `use AshStrangler.Mapping, resource: ...` promise is held to. See
      # `AshStrangler.Mapping.verify_target/1` for why it cannot be a verifier.
      target_failures = Enum.count(resources, &report_target_mismatch/1)

      {failures, unmeasured} =
        if opts[:data] == false do
          Mix.shell().info(skipped_note())
          @none
        else
          measure(resources)
        end

      Mix.shell().info(manual_checks())

      conclude(target_failures + failures, unmeasured, opts[:strict] == true)
    end
  end

  # Zero resources is not "measured clean". A mistyped `--domain` lands here as
  # well, and a gate that goes green on it has checked nothing.
  defp no_resources(opts) do
    Mix.shell().info("No resources use AshStrangler.Resource.")

    if opts[:strict] do
      Mix.shell().error(
        "--strict: nothing was measured, because no resource was found" <>
          if(opts[:domain], do: " in #{opts[:domain]}.", else: ".")
      )

      exit({:shutdown, 1})
    end
  end

  defp conclude(failures, unmeasured, strict?) do
    if failures > 0,
      do: Mix.shell().error("#{failures} assertion(s) failed against the legacy data.")

    if strict? and unmeasured > 0 do
      Mix.shell().error(
        "#{unmeasured} check(s) could not be measured, and --strict does not count " <>
          "a check that did not run as one that passed."
      )
    end

    if failures > 0 or (strict? and unmeasured > 0), do: exit({:shutdown, 1})
  end

  defp strangled_resources(domain_filter) do
    domains =
      Application.get_env(:ash, :ash_domains, []) ++
        Enum.flat_map(Application.loaded_applications(), fn {app, _, _} ->
          Application.get_env(app, :ash_domains, [])
        end)

    domains
    |> Enum.uniq()
    |> filter_domains(domain_filter)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&(AshStrangler.Resource in Spark.extensions(&1)))
    |> Enum.sort_by(&inspect/1)
  end

  defp filter_domains(domains, nil), do: domains

  defp filter_domains(domains, filter) do
    Enum.filter(domains, &(inspect(&1) == filter))
  end

  # --- the declaration ---------------------------------------------------

  # One line per mapping fragment attached to the wrong resource, and a failure
  # count so the exit code covers the declaration as well as the data.
  defp report_target_mismatch(resource) do
    case AshStrangler.Mapping.verify_target(resource) do
      :ok ->
        false

      {:error, message} ->
        Mix.shell().error("#{@fail} #{message}")
        true
    end
  end

  defp report(resource) do
    source = Info.source(resource)
    mappings = Info.mappings(resource)
    read_only = Enum.filter(Lens.for_resource(resource), &(&1.type == :masked))

    Mix.shell().info("""

    #{inspect(resource)}
      twin       #{inspect(source.twin)} — #{Info.relation(resource)}
      phase      #{inspect(Info.strangler_phase!(resource))}
      writes     #{inspect(Info.writes(resource))}#{derived_note(source)}
      mappings   #{length(mappings)} mapped, #{length(Info.constants(resource))} constant, #{unmapped_count(resource)} unmapped
      read-only  #{read_only_summary(read_only)}#{joins_summary(resource)}
      mechanism  #{mechanism_summary(resource)}#{upsert_warning(resource, Info.writes(resource))}\
      #{tenant_summary(resource)}\
      #{declared_losses(resource)}\
    """)
  end

  # A declared loss is a decision, and this is where it stays visible: every
  # `{:lossy, to:, loss:}` state prints its reason verbatim, so a check run is
  # the record of what a read will quietly collapse. A loss nobody can see is
  # a loss somebody will rediscover in production.
  defp declared_losses(resource) do
    losses =
      resource
      |> Info.mappings()
      |> Enum.filter(&is_struct(&1, AshStrangler.Collapse))
      |> Enum.flat_map(fn collapse ->
        for %{representation: {:lossy, to, loss}} <- collapse.states do
          "  #{inspect(collapse.attribute)} #{inspect(to)} — #{loss}"
        end
      end)

    case losses do
      [] ->
        ""

      losses ->
        "\n  declared losses\n" <> Enum.join(losses, "\n")
    end
  end

  # An exemption is a decision on the record. The verifier carries it; this is
  # where it is said out loud, because a check run that stays silent about the
  # relationships a resource declined to prove is a check that cannot be used
  # to audit them.
  defp tenant_summary(resource) do
    case Info.tenant(resource) do
      nil ->
        ""

      %{allow_unproven: []} ->
        ""

      %{attribute: attribute, allow_unproven: allow_unproven} ->
        "#{@continued}tenant      #{attribute}, unproven: #{Enum.map_join(allow_unproven, ", ", &":#{&1}")}"
    end
  end

  defp joins_summary(resource) do
    case Info.joins(resource) do
      [] ->
        ""

      joins ->
        # Always `LEFT`, and structurally so rather than by default: a join is
        # derived from a relationship, which says which rows *relate* rather than
        # which rows survive. An author who means to drop unmatched rows writes a
        # filter, where it is visible as one.
        "\n  joins      " <>
          Enum.map_join(joins, @continued, fn join ->
            "LEFT JOIN #{join.relation} AS #{join.alias} ON #{join.on}"
          end)
    end
  end

  # Both columns, because one would either overstate what the generator emits or
  # hide what the schema could support. `AshStrangler.Mechanism`'s two unemitted
  # tiers need DDL against a table this package does not own, so the gap between
  # the columns is a decision waiting for an operator rather than a defect.
  defp mechanism_summary(resource) do
    case Mechanism.report(resource) do
      [] ->
        "nothing to write"

      report ->
        width =
          report |> Enum.map(&(&1 |> elem(0) |> to_string() |> String.length())) |> Enum.max()

        Enum.map_join(report, @continued, fn {attribute, ideal, emitted} ->
          gap = if ideal != emitted, do: "  <- cheaper than what is emitted", else: ""

          "#{String.pad_trailing(to_string(attribute), width)}  ideal #{pad(ideal)} emitted #{pad(emitted)}#{gap}"
        end)
    end
  end

  defp pad(mechanism), do: mechanism |> inspect() |> String.pad_trailing(14)

  defp derived_note(%{writes: nil}), do: "  (derived from the mapping shape)"
  defp derived_note(_), do: "  (declared)"

  defp unmapped_count(resource) do
    resource
    |> Info.unmapped()
    |> Enum.flat_map(& &1.attributes)
    |> length()
  end

  defp read_only_summary([]), do: "none"

  defp read_only_summary(lenses) do
    Enum.map_join(lenses, @continued, fn lens ->
      "#{lens.attribute} — #{lens.because || "no reverse could be constructed"}"
    end)
  end

  # The compile-time verifier only refuses this combination when `writes` is
  # `:triggers`. Reporting it here as well means somebody reading the pre-flight
  # output learns why the resource cannot move to a trigger-based mapping later,
  # rather than discovering it when the move fails.
  defp upsert_warning(resource, :auto) do
    upserts =
      resource
      |> Ash.Resource.Info.actions()
      |> Enum.filter(&Map.get(&1, :upsert?, false))
      |> Enum.map(& &1.name)

    case upserts do
      [] ->
        ""

      names ->
        "\n  NOTE       upsert actions #{inspect(names)} require writes: :auto." <>
          "#{@continued}This resource cannot move to INSTEAD OF triggers."
    end
  end

  defp upsert_warning(_resource, _writes), do: ""

  # --- measuring ---------------------------------------------------------

  defp measure(resources) do
    resources
    |> Enum.group_by(&repo(&1))
    |> Enum.map(fn {repo, group} -> measure_group(repo, group) end)
    |> tally()
  end

  defp tally(results) do
    Enum.reduce(results, @none, fn {failed, unmeasured}, {total_failed, total_unmeasured} ->
      {total_failed + failed, total_unmeasured + unmeasured}
    end)
  end

  defp measure_group(nil, group) do
    Mix.shell().info("""

    #{@unrun}  #{Enum.map_join(group, ", ", &inspect/1)}
          No repo could be resolved from the twin, so nothing was measured.
    """)

    {0, 1}
  end

  # `Ecto.Migrator.with_repo/2` rather than `app.start`, because a repo is not
  # necessarily in the application's supervision tree at all -- and starting it
  # for the duration of the checks is what `mix ecto.migrate` does for the same
  # reason.
  #
  # Only when it is not already running, though. `with_repo/2` restarts the
  # connection pool of a repo it found already started, which is correct for a
  # migration and wrong here: whoever started it -- a release console, a test
  # holding a sandbox connection -- did not ask for their pool to be recycled by a
  # read-only report.
  defp measure_group(repo, group) do
    if Process.whereis(repo) do
      run_checks(repo, group)
    else
      case Ecto.Migrator.with_repo(repo, &run_checks(&1, group)) do
        {:ok, tally, _apps} -> tally
        {:error, reason} -> unavailable(repo, reason)
      end
    end
  end

  defp run_checks(repo, group) do
    tally(
      Enum.map(group, &measure_resource(repo, &1)) ++
        measure_twins(repo, group) ++ [ledger_backlog(repo, group)]
    )
  end

  defp unavailable(repo, reason) do
    Mix.shell().info("""

    #{@unrun}  #{inspect(repo)} could not be started: #{inspect(reason)}
          Nothing was measured for it. That is not the same answer as "measured
          clean", so the task does not fail on it unless `--strict` is given -- but
          a CI run reporting this has checked nothing.
    """)

    {0, 1}
  end

  defp measure_resource(repo, resource) do
    Mix.shell().info("\n  #{inspect(resource)} against #{Info.relation(resource)}")

    [
      &null_checks(repo, &1),
      &identity_checks(repo, &1),
      &cast_check(repo, &1),
      &type_checks(repo, &1),
      &obligation_checks(repo, &1),
      &fan_out_check(repo, &1)
    ]
    |> Enum.map(& &1.(resource))
    |> tally()
  end

  # --- allow_nil? false --------------------------------------------------

  defp null_checks(repo, resource) do
    lenses = Lens.by_attribute(resource)
    key = Info.key(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(& &1.allow_nil?)
    |> Enum.map(&null_check(repo, resource, &1, lenses, key))
    |> tally()
  end

  defp null_check(repo, resource, attribute, lenses, key) do
    label = "allow_nil? false  #{attribute.name}"

    cond do
      key && key.attribute == attribute.name ->
        # The key expression is a hash of the legacy key, and it is NULL exactly
        # when the legacy key is -- so the column is the honest thing to count, and
        # it reads as the question somebody actually has.
        count_null(repo, resource, label, column_sql(resource, key.from))

      lens = lenses[attribute.name] ->
        null_check_lens(repo, resource, label, lens)

      true ->
        not_measured(label, "no mapping accounts for it, so nothing was measured")
    end
  end

  # Decided from the declaration, not the data. `unmapped ..., as: :null` projects
  # NULL for every row by construction, so an attribute that forbids NULL and is
  # unmapped is not a data problem to be measured -- it is a mapping that cannot
  # produce a valid row, and no state of the legacy table changes that.
  defp null_check_lens(_repo, _resource, label, %Lens{forward: nil}) do
    emit(
      @fail,
      label,
      "the mapping projects NULL for every row (`unmapped ..., as: :null`), so no row can satisfy it"
    )
  end

  defp null_check_lens(repo, resource, label, lens) do
    count_null(repo, resource, label, forward_sql(resource, lens))
  end

  defp count_null(repo, resource, label, expression) do
    sql = """
    SELECT count(*) FROM #{View.from_clause(resource)}
    WHERE (#{expression}) IS NULL
    """

    case query(repo, sql) do
      {:ok, %{rows: [[0]]}} -> emit(@ok, label, "no legacy row projects NULL")
      {:ok, %{rows: [[count]]}} -> emit(@fail, label, "#{count} legacy row(s) project NULL")
      {:error, message} -> emit(@unrun, label, message)
    end
  end

  # --- identities --------------------------------------------------------

  defp identity_checks(repo, resource) do
    lenses = Lens.by_attribute(resource)

    resource
    |> Ash.Resource.Info.identities()
    |> Enum.map(&identity_check(repo, resource, &1, lenses))
    |> tally()
  end

  defp identity_check(repo, resource, identity, lenses) do
    label = "identity #{identity.name} (#{Enum.join(identity.keys, ", ")})"
    expressions = Enum.map(identity.keys, &identity_expression(resource, &1, lenses))

    if Enum.any?(expressions, &is_nil/1) do
      not_measured(label, "a key has no mapping to group by, so nothing was measured")
    else
      count_duplicates(repo, resource, identity, label, expressions)
    end
  end

  defp identity_expression(resource, key, lenses) do
    case {Info.key(resource), lenses[key]} do
      {%{attribute: ^key} = declared, _} -> column_sql(resource, declared.from)
      {_, %Lens{forward: nil}} -> nil
      {_, %Lens{} = lens} -> forward_sql(resource, lens)
      _ -> nil
    end
  end

  defp count_duplicates(repo, resource, identity, label, expressions) do
    grouped = Enum.join(expressions, ", ")

    # Ash's `nils_distinct?` decides whether two NULLs collide, and PostgreSQL's
    # default unique index says they do not. `GROUP BY` says they do, so the NULL
    # rows are excluded to match whichever semantics the identity declares --
    # otherwise every legacy row with an unset column reports as a duplicate of
    # every other, which is noise that hides the real ones.
    where =
      if Map.get(identity, :nils_distinct?, true) do
        "WHERE " <> Enum.map_join(expressions, " AND ", &"(#{&1}) IS NOT NULL")
      else
        ""
      end

    sql = """
    SELECT count(*) FROM (
      SELECT 1 FROM #{View.from_clause(resource)}
      #{where}
      GROUP BY #{grouped}
      HAVING count(*) > 1
    ) duplicate_groups
    """

    case query(repo, sql) do
      {:ok, %{rows: [[0]]}} ->
        emit(@ok, label, "no duplicate groups over #{grouped}")

      {:ok, %{rows: [[count]]}} ->
        emit(
          @fail,
          label,
          "#{count} duplicate group(s) over #{grouped}. Ash will plan upserts against " <>
            "this identity and report \"has already been taken\" for rows that already exist."
        )

      {:error, message} ->
        emit(@unrun, label, message)
    end
  end

  # --- casts -------------------------------------------------------------

  # One projection first, and a per-attribute retry only when it fails. A cast
  # failure in PostgreSQL raises rather than returning a row count -- `SELECT
  # 'abc'::integer` is an error, not a NULL -- so the count of failing rows is not
  # a number a query can return. What matters is which attribute cannot be
  # projected, and the retry is what names it.
  #
  # A connection error is not a cast failure, and retrying it per attribute would
  # report the database being down as a problem with every column. It is reported
  # once, as the database not being reachable, and it is still a failure: a gate
  # that went green because the database was down would measure nothing and say so
  # only in a line nobody reads.
  defp cast_check(repo, resource) do
    projections = projections(resource)

    case run_query(repo, projection_sql(resource, projections), []) do
      {:ok, _result} ->
        emit(@ok, "casts", "every mapping projects over all #{length(projections)} column(s)")

      {:error, error} ->
        if connection_error?(error) do
          unreachable(error)
        else
          cast_checks_each(repo, resource, projections, Exception.message(error))
        end
    end
  end

  # Every attribute passing alone leaves the projection as a whole unexplained, and
  # the check still did not run, so that is reported rather than left as silence.
  defp cast_checks_each(repo, resource, projections, whole_failure) do
    projections
    |> Enum.reduce_while(@none, fn projection, total ->
      {direction, result} = cast_check_one(repo, resource, projection)
      {direction, tally([total, result])}
    end)
    |> case do
      @none ->
        emit(
          @unrun,
          "casts",
          "the whole projection failed though each attribute projects alone: #{whole_failure}"
        )

      result ->
        result
    end
  end

  defp cast_check_one(repo, resource, {attribute, expression}) do
    case run_query(repo, projection_sql(resource, [{attribute, expression}]), []) do
      {:ok, _result} ->
        {:cont, @none}

      {:error, error} ->
        if connection_error?(error) do
          {:halt, unreachable(error)}
        else
          {:cont,
           emit(@fail, "cast  #{attribute}", "#{expression} — #{Exception.message(error)}")}
        end
    end
  end

  defp unreachable(error) do
    emit(
      @fail,
      "database could not be reached",
      "#{Exception.message(error)}\n              The casts could not be run, and this is not a statement about any attribute."
    )
  end

  defp connection_error?(%DBConnection.ConnectionError{}), do: true
  defp connection_error?(_error), do: false

  defp projection_sql(resource, projections) do
    selected =
      Enum.map_join(projections, ",\n         ", fn {attribute, expression} ->
        "#{expression} AS #{attribute}"
      end)

    """
    SELECT count(*) FROM (
      SELECT #{selected}
      FROM #{View.from_clause(resource)}
    ) projection
    """
  end

  defp projections(resource) do
    key =
      case Info.key(resource) do
        nil -> []
        key -> [{key.attribute, key_sql(resource, key)}]
      end

    mapped =
      resource
      |> Lens.by_attribute()
      |> Enum.reject(fn {_attribute, lens} -> is_nil(lens.forward) end)
      |> Enum.map(fn {attribute, lens} -> {attribute, forward_sql(resource, lens)} end)
      |> Enum.sort_by(fn {attribute, _} -> attribute end)

    key ++ mapped
  end

  # --- column types ------------------------------------------------------

  # The type each mapping *yields*, against the type its attribute stores. The
  # cast check above proves every row projects; it cannot say that what comes out
  # is what the attribute expects, because Postgres is happy to project an `int4`
  # where Ash will read a string. A twin whose column changed type is the usual
  # way to get there: the mapping carries no cast, because the twin said the two
  # were already the same.
  #
  # The type is read, not computed from rows. `ON false` joins nothing, so the
  # projection is parsed and typed and never executed -- a row that cannot be cast
  # makes no difference to this question, and the cast check is where it fails.
  # `pg_typeof` of the (NULL) joined column is the type of the expression.
  @projected_type """
  SELECT t.typname, t.typtype::text, t.typcategory::text, e.typname, b.typname
    FROM (SELECT 1) one
    LEFT JOIN (SELECT %EXPRESSION% AS attr FROM %FROM%) p ON false
    JOIN pg_type t ON t.oid = pg_typeof(p.attr)::oid
    LEFT JOIN pg_type e ON t.typcategory = 'A' AND e.oid = t.typelem
    LEFT JOIN pg_type b ON t.typtype = 'd' AND b.oid = t.typbasetype
  """

  # A warning, never a failure: a matching type is not a statement about any row,
  # a typmod (`numeric(10, 2)`, `varchar(20)`) is not compared, and a mapping that
  # reads a Postgres enum or a type with no Ash type cannot be compared at all --
  # which is reported rather than passed.
  defp type_checks(repo, resource) do
    from = View.from_clause(resource)

    resource
    |> projections()
    |> Enum.reduce_while({0, @none}, fn {attribute, expression}, {matched, total} ->
      sql =
        @projected_type
        |> String.replace("%EXPRESSION%", expression)
        |> String.replace("%FROM%", from)

      case run_query(repo, sql, []) do
        {:ok, %{rows: [row]}} ->
          case compare_projected(resource, attribute, row) do
            :ok ->
              {:cont, {matched + 1, total}}

            {finding, detail} ->
              {:cont, {matched, tally([total, flag(finding, "column types  #{attribute}", detail)])}}
          end

        {:ok, _other} ->
          {:halt,
           {matched, tally([total, emit(@unrun, "column types", "the query returned no type")])}}

        {:error, error} ->
          {:halt,
           {matched, tally([total, emit(@unrun, "column types", Exception.message(error))])}}
      end
    end)
    |> then(fn {matched, total} ->
      if matched > 0 do
        tally([
          total,
          emit(
            @ok,
            "column types",
            "#{matched} projection(s) yield the type their attribute stores. Typmods are not " <>
              "compared, and a matching type does not show that every row casts: the cast " <>
              "check does that."
          )
        ])
      else
        total
      end
    end)
  end

  # A warning that compared the two and found them different is a measurement. One
  # that could not compare them is not, and `--strict` counts it.
  defp flag(:not_measured, label, detail), do: not_measured(label, detail)
  defp flag(marker, label, detail), do: emit(marker, label, detail)

  defp compare_projected(resource, attribute, [typname, typtype, category, element, base]) do
    case {Ash.Resource.Info.attribute(resource, attribute),
          yielded(typname, typtype, category, element, base)} do
      {nil, _yielded} ->
        :ok

      {_attribute, {:enum, name}} ->
        {:not_measured,
         "the mapping yields the Postgres enum `#{name}`, which is not compared with the " <>
           "attribute's type: its labels are a value set, and the twin column check " <>
           "holds the twin's `one_of` to them. Nothing was measured here."}

      {attribute, {:unknown, name}} ->
        {:not_measured,
         "the mapping yields `#{name}`, which has no Ash type, so it was not compared with " <>
           "what the attribute stores (#{inspect(Introspection.coarse(attribute.type, attribute.constraints))}). " <>
           "Nothing was measured here: check the cast by hand."}

      {attribute, {:ok, name, ash_type}} ->
        stored = Introspection.coarse(attribute.type, attribute.constraints)
        yielded = Introspection.coarse(ash_type)

        if stored == yielded do
          :ok
        else
          {@warn,
           "the mapping yields `#{name}` (#{inspect(yielded)}); the attribute stores " <>
             "#{inspect(stored)}. Rows will not read back as the attribute expects. " <>
             "Typmods are not compared."}
        end
    end
  end

  # An enum is not a type this table can name, a domain is the type it is over, an
  # array is its element's, and a pseudo-type (`unknown`, `record`) is not a type
  # a column can be compared on.
  defp yielded(name, "e", _category, _element, _base), do: {:enum, name}

  defp yielded(_name, "d", category, element, base) when is_binary(base),
    do: yielded(base, "b", category, element, nil)

  defp yielded(name, "d", _category, _element, _base), do: {:unknown, name}
  defp yielded(name, "p", _category, _element, _base), do: {:unknown, name}

  defp yielded(name, _typtype, "A", element, _base) do
    case element && Introspection.pg_type(element) do
      nil -> {:unknown, name}
      type -> {:ok, name, {:array, type}}
    end
  end

  defp yielded(name, _typtype, _category, _element, _base) do
    case Introspection.pg_type(name) do
      nil -> {:unknown, name}
      type -> {:ok, name, type}
    end
  end

  # --- the obligations that could not be decided -------------------------

  defp obligation_checks(repo, resource) do
    resource
    |> Obligations.assertions()
    |> Enum.map(&obligation_check(repo, &1))
    |> tally()
  end

  defp obligation_check(repo, finding) do
    label = "#{finding.obligation}  #{finding.attribute}"
    severity = if finding.severity == :error, do: @fail, else: @warn

    case query(repo, finding.assertion) do
      {:ok, %{rows: []}} ->
        emit(@ok, label, "no rows")

      {:ok, %{rows: [[0]]}} ->
        emit(@ok, label, "0")

      {:ok, result} ->
        emit(severity, label, describe(result))

      {:error, message} ->
        emit(@unrun, label, message)
    end
  end

  defp describe(%{columns: columns, rows: rows}) do
    heading = Enum.join(columns, ", ")

    body =
      rows
      |> Enum.take(10)
      |> Enum.map_join("\n              ", fn row -> Enum.map_join(row, ", ", &inspect/1) end)

    elided = if length(rows) > 10, do: "\n              … #{length(rows) - 10} more", else: ""

    "#{heading}\n              #{body}#{elided}"
  end

  # --- fan-out -----------------------------------------------------------

  # The hazard a join introduces that no compile-time check can see: if the joined
  # relation has more than one row per primary row, the view returns several rows
  # for one primary key. `Ash.get/2` then finds duplicates, counts inflate, and
  # nothing raises -- the view is perfectly valid SQL. It depends entirely on the
  # data, which is why it belongs here rather than in a verifier.
  #
  # `AshStrangler.Twin.joins_for/2` refuses a `has_many` by name, so the remaining
  # way to reach fan-out is a `has_one` or `belongs_to` the database does not
  # actually enforce as unique -- which is exactly the sort of thing a legacy schema
  # has.
  defp fan_out_check(repo, resource) do
    case Info.joins(resource) do
      [] -> @none
      _joins -> measure_fan_out(repo, resource)
    end
  end

  defp measure_fan_out(repo, resource) do
    relation = Info.relation(resource)

    with {:ok, %{rows: [[base]]}} <- query(repo, "SELECT count(*) FROM #{relation}"),
         {:ok, %{rows: [[joined]]}} <-
           query(repo, "SELECT count(*) FROM #{View.from_clause(resource)}") do
      compare_fan_out(relation, base, joined)
    else
      {:error, message} -> emit(@unrun, "join fan-out", message)
    end
  end

  defp compare_fan_out(relation, base, joined) when joined > base do
    emit(
      @fail,
      "join fan-out",
      "#{base} rows in #{relation}, #{joined} through the joins. A joined relation has " <>
        "more than one row per primary row, so the view returns duplicates for a single " <>
        "primary key: Ash.get/2 will find more than one record and counts will be wrong."
    )
  end

  defp compare_fan_out(relation, base, joined) when joined < base do
    emit(
      @fail,
      "join fan-out",
      "#{base} rows in #{relation}, only #{joined} through the joins — rows the legacy " <>
        "application can still see are missing. Joins are LEFT, so this should not be " <>
        "reachable from the DSL; check the join condition the relationship produced."
    )
  end

  defp compare_fan_out(_relation, _base, _joined),
    do: emit(@ok, "join fan-out", "one row in, one row out")

  # --- the twins themselves ----------------------------------------------

  defp measure_twins(repo, resources) do
    twins =
      resources
      |> Enum.map(&Info.twin/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort_by(&inspect/1)

    # One catalog read for every twin on the repo, not one per twin: the catalog
    # is read by schema.
    catalog = read_catalog(repo, twins)

    Enum.map(twins, &measure_twin(repo, &1, resources, catalog))
  end

  defp read_catalog(repo, twins) do
    schemas = twins |> Enum.map(&(&1 |> relation_parts() |> elem(0))) |> Enum.uniq()

    Introspection.read(&run_query(repo, &1, &2), schemas)
  end

  defp measure_twin(repo, twin, resources, catalog) do
    Mix.shell().info("\n  #{inspect(twin)} against #{Twin.relation(twin)}")

    tally([
      twin_freshness(repo, twin),
      twin_identities(repo, twin),
      twin_columns(twin, resources, catalog)
    ])
  end

  @information_schema_columns """
  SELECT column_name
    FROM information_schema.columns
   WHERE table_schema = $1 AND table_name = $2
  """

  # The twin is generated by introspection, so it is a snapshot, and a column the
  # legacy application's next migration adds is invisible to every mapping until it
  # is regenerated. Without this diff the typed layer inherits precisely the
  # staleness problem it was built to remove -- the difference being that a stale
  # twin fails quietly, where a hand-written SQL string at least failed loudly.
  defp twin_freshness(repo, twin) do
    {schema, table} = relation_parts(twin)

    case query(repo, @information_schema_columns, [schema, table]) do
      {:ok, %{rows: rows}} ->
        actual = MapSet.new(rows, fn [column] -> column end)
        declared = MapSet.new(Twin.columns(twin), &Twin.column!(twin, &1))

        compare_columns(declared, actual, twin)

      {:error, message} ->
        emit(@unrun, "twin freshness", message)
    end
  end

  defp compare_columns(declared, actual, twin) do
    missing = MapSet.difference(actual, declared)
    stale = MapSet.difference(declared, actual)

    cond do
      MapSet.size(actual) == 0 ->
        emit(
          @fail,
          "twin freshness",
          "`#{Twin.relation(twin)}` has no columns in information_schema. It does not exist, " <>
            "or this role cannot see it."
        )

      MapSet.size(stale) > 0 ->
        emit(
          @fail,
          "twin freshness",
          "the twin declares column(s) the relation does not have: " <>
            "#{list(stale)}. Every mapping reading one of them projects against nothing. " <>
            "Regenerate: mix ash_strangler.gen.twin --relation #{Twin.relation(twin)}"
        )

      MapSet.size(missing) > 0 ->
        emit(
          @warn,
          "twin freshness",
          "the relation has column(s) the twin does not declare: #{list(missing)}. " <>
            "They are invisible to every mapping, and to lineage. Either regenerate the " <>
            "twin, or accept them as columns this application deliberately does not read."
        )

      true ->
        emit(@ok, "twin freshness", "#{MapSet.size(declared)} column(s), all present")
    end
  end

  # --- the twin's columns against what the generator writes today ---------

  # Freshness above asks whether the twin has the right *columns*. This asks
  # whether the columns it has still mean what it says: it re-derives, from the
  # live catalog, what `mix ash_strangler.gen.twin` would write for each column
  # the twin declares, and compares.
  #
  # A twin is accepted however it was written, so only what it declares is held
  # to the catalog: a column it leaves out is the freshness check's to report, a
  # value set it does not state is not asked for, and an attribute is found by the
  # column its `source:` names.
  #
  # The widened value set is the one that fails, and it is the finding worth the
  # step. With a `one_of` present and every value decoded, `GetTotal` is proven
  # total at compile time and no assertion is emitted, so a label added to the
  # enum later is a value nothing re-checks.
  defp twin_columns(twin, resources, {:ok, catalog}) do
    {schema, table} = relation_parts(twin)

    # An absent relation has been reported as a failure by the freshness check, and
    # says nothing here: there is nothing to compare, and a second failure for one
    # missing table would only hide that it is one.
    case Introspection.relation(catalog, "#{schema}.#{table}") do
      {:ok, relation} -> compare_twin(twin, relation, catalog, resources)
      :error -> @none
    end
  end

  defp twin_columns(_twin, _resources, {:error, error}) do
    emit(
      @unrun,
      "twin columns",
      "the catalog could not be read: #{Exception.message(error)}. The twin's types and " <>
        "value sets were not compared."
    )
  end

  defp compare_twin(twin, relation, catalog, resources) do
    secrets = Twin.secrets(twin)
    wrote = relation |> Introspection.columns(catalog, secrets) |> Map.new(&{&1.column, &1})

    findings =
      twin
      |> Ash.Resource.Info.attributes()
      |> Enum.flat_map(fn attribute ->
        column = Twin.column!(twin, attribute.name)

        if column in secrets or not Map.has_key?(wrote, column) do
          []
        else
          compare_attribute(twin, attribute, wrote[column], resources)
        end
      end)

    case findings do
      [] ->
        emit(
          @ok,
          "twin columns",
          "#{length(Twin.columns(twin))} column(s) match what gen.twin writes today"
        )

      findings ->
        findings
        |> Enum.map(fn {finding, attribute, detail} ->
          flag(finding, "twin column  #{attribute}", detail)
        end)
        |> tally()
    end
  end

  defp compare_attribute(twin, attribute, wrote, resources) do
    type_findings(twin, attribute, wrote) ++
      value_set_findings(twin, attribute, wrote, resources) ++
      nullability_findings(attribute, wrote)
  end

  # A type the generator cannot give an Ash type is not declared by it, so there
  # is nothing to compare: the twin declares one anyway, which is a hand edit worth
  # a line and not a failure.
  defp type_findings(_twin, attribute, %{type: nil, name: name, note: note})
       when not is_nil(name) do
    [
      {:not_measured, attribute.name,
       note
       |> String.split("\n", parts: 2)
       |> hd()
       |> String.trim()
       |> Kernel.<>(
         " The twin declares #{inspect(attribute.name)} anyway, and it was not compared."
       )}
    ]
  end

  defp type_findings(_twin, _attribute, %{type: nil}), do: []

  defp type_findings(twin, attribute, wrote) do
    declared = Introspection.coarse(attribute.type, attribute.constraints)
    written = Introspection.coarse(wrote.type)

    if declared == written do
      []
    else
      [
        {@fail, attribute.name,
         "the twin declares #{inspect(declared)}; the column is " <>
           "now #{inspect(written)}. A mapping that reads it casts and compares as the wrong " <>
           "type. Regenerate: mix ash_strangler.gen.twin #{inspect(twin)}"}
      ]
    end
  end

  defp value_set_findings(_twin, _attribute, %{type: nil}, _resources), do: []

  defp value_set_findings(twin, attribute, wrote, resources) do
    case Keyword.get(attribute.constraints, :one_of) do
      declared when is_list(declared) ->
        compare_value_sets(twin, attribute, MapSet.new(declared, &to_string/1), wrote, resources)

      _none ->
        []
    end
  end

  defp compare_value_sets(twin, attribute, declared, %{one_of: nil}, _resources) do
    [
      {@warn, attribute.name,
       "the twin declares one_of #{values(declared)}, but the catalog no longer yields a " <>
         "value set for the column: its CHECK is gone, or its enum is now text. The compiler " <>
         "still enumerates a domain the column does not enforce. Regenerate: " <>
         "mix ash_strangler.gen.twin #{inspect(twin)}"}
    ]
  end

  defp compare_value_sets(twin, attribute, declared, %{one_of: one_of}, resources) do
    actual = MapSet.new(one_of)
    widened = MapSet.difference(actual, declared)
    narrowed = MapSet.difference(declared, actual)

    widened_finding =
      if MapSet.size(widened) > 0 do
        [
          {@fail, attribute.name,
           "the column now admits #{values(widened)}, which the twin's one_of does not list. " <>
             "#{readers(twin, attribute.name, resources)} A decode that never meant to handle " <>
             "it is not caught: with a one_of present and every listed value decoded, " <>
             "`GetTotal` is proven at compile time and emits no assertion, so nothing re-checks " <>
             "this value. Regenerate, then read each decode again: " <>
             "mix ash_strangler.gen.twin #{inspect(twin)}"}
        ]
      else
        []
      end

    narrowed_finding =
      if MapSet.size(narrowed) > 0 do
        [
          {@warn, attribute.name,
           "the twin's one_of lists #{values(narrowed)}, which the column no longer admits. " <>
             "A decode for it is dead code, and a mapping that writes it will be refused " <>
             "by the database."}
        ]
      else
        []
      end

    widened_finding ++ narrowed_finding
  end

  defp nullability_findings(attribute, wrote) do
    if attribute.allow_nil? == wrote.allow_nil? do
      []
    else
      [
        {@warn, attribute.name,
         "the twin says allow_nil? #{attribute.allow_nil?}; the column " <>
           if(wrote.allow_nil?, do: "allows NULL", else: "is NOT NULL") <>
           ". That is a warning only: the null checks count the NULLs the rows really hold."}
      ]
    end
  end

  defp values(set), do: set |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

  # The mappings that read the column, found the way the lineage graph finds them:
  # each lens lists the `{relationship path, attribute}` pairs it reads, and a path
  # that leaves the primary twin is followed to the twin it lands on.
  defp readers(twin, attribute, resources) do
    names =
      for resource <- resources,
          lens <- Lens.for_resource(resource),
          reads?(Info.twin(resource), lens, twin, attribute),
          uniq: true,
          do: "#{inspect(resource)}.#{lens.attribute}"

    case Enum.sort(names) do
      [] -> "No mapping reads it."
      names -> "Read by #{Enum.join(names, ", ")}."
    end
  end

  defp reads?(root, lens, twin, attribute) do
    Enum.any?(lens.sources || [], fn {path, name} ->
      name == attribute and Twin.resource_at(root, path) == {:ok, twin}
    end)
  end

  # `indpred IS NULL` because a partial unique index does not make the column
  # unique -- it makes it unique among the rows matching the predicate -- and an
  # Ash identity claims the unconditional thing.
  #
  # `indexprs IS NULL` for the same reason: an expression key has attnum 0, which
  # the join to `pg_attribute` drops, so `UNIQUE (tenant_id, lower(email))` would
  # otherwise read as a unique `tenant_id`.
  #
  # `k.ord <= x.indnkeyatts` keeps the key columns and drops `INCLUDE` ones, which
  # are payload and constrain nothing. `indkey` is an `int2vector`, 0-based, so it
  # is unnested rather than sliced; `WITH ORDINALITY` numbers from 1, as
  # `indnkeyatts` counts.
  @unique_indexes """
  SELECT array_agg(a.attname ORDER BY a.attname)
    FROM pg_index x
    CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum
   WHERE x.indrelid = $1::text::regclass
     AND x.indisunique
     AND x.indpred IS NULL
     AND x.indexprs IS NULL
     AND k.ord <= x.indnkeyatts
   GROUP BY x.indexrelid
  """

  # An identity Postgres does not enforce is worse than no identity at all: Ash
  # uses it to plan upserts and to report "has already been taken" from a `SELECT`,
  # while the write path keeps accepting duplicates. The failure is therefore
  # silent on the way in and confusing on the way out.
  defp twin_identities(repo, twin) do
    declared = Twin.unique_column_sets(twin)

    if MapSet.size(declared) == 0 do
      emit(@ok, "twin identities", "none declared")
    else
      case query(repo, @unique_indexes, [Twin.relation(twin)]) do
        {:ok, %{rows: rows}} ->
          enforced = MapSet.new(rows, fn [columns] -> MapSet.new(columns) end)
          compare_identities(declared, enforced, twin)

        {:error, message} ->
          emit(@unrun, "twin identities", message)
      end
    end
  end

  defp compare_identities(declared, enforced, twin) do
    unbacked = declared |> Enum.reject(&MapSet.member?(enforced, &1)) |> Enum.sort_by(&inspect/1)

    if unbacked == [] do
      emit(
        @ok,
        "twin identities",
        "#{MapSet.size(declared)} set(s), each backed by a unique index"
      )
    else
      emit(
        @fail,
        "twin identities",
        "#{inspect(twin)} declares unique set(s) Postgres does not enforce: " <>
          "#{Enum.map_join(unbacked, "; ", &list/1)}. Ash will plan upserts against them " <>
          "and report conflicts from a SELECT, while duplicates keep being accepted."
      )
    end
  end

  defp relation_parts(twin) do
    case String.split(Twin.relation(twin), ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end

  defp list(columns), do: columns |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

  # --- the ledger ---------------------------------------------------------

  # Informational, and deliberately never a failure: a backlog between drains
  # is the ledger working as designed, not an assertion that failed. What the
  # number is for is noticing the drain has stopped keeping up — which is why
  # it is reported per relation, where "which legacy table is piling up" is
  # readable, rather than as one global count that hides the pile-up behind
  # the quiet relations. A backlog that could not be read at all is `????`, which
  # like any other only fails the task under `--strict`.
  defp ledger_backlog(repo, group) do
    group
    |> Enum.filter(&Info.ledger?/1)
    |> Enum.map(&Info.relation/1)
    |> Enum.uniq()
    |> Enum.map(&ledger_backlog_for(repo, &1))
    |> tally()
  end

  defp ledger_backlog_for(repo, relation) do
    {schema, table} = relation_parts_of(relation)

    sql = """
    SELECT count(*) FROM #{Ledger.events_table()}
    WHERE processed_at IS NULL AND source_schema = $1 AND source_table = $2
    """

    case query(repo, sql, [schema, table]) do
      {:ok, %{rows: [[count]]}} ->
        emit(@ok, "ledger backlog", "#{relation} — #{count} unprocessed event(s)")

      {:error, message} ->
        emit(
          @unrun,
          "ledger backlog",
          "#{relation} — #{message}. The events table does not exist yet, or the " <>
            "migration that creates it has not run."
        )
    end
  end

  defp relation_parts_of(relation) do
    case String.split(relation, ".", parts: 2) do
      [schema, table] -> {schema, table}
      [table] -> {"public", table}
    end
  end

  # --- rendering and running ---------------------------------------------

  # One printer, the same one the view, the triggers, the reverse view and the
  # expression index read through. That is not tidiness: two renderings of one
  # expression can drift, and when the index expression drifts from the query
  # expression the planner stops using the index with nothing reporting it. An
  # assertion built by a second path could pass against SQL the view never runs.
  defp forward_sql(resource, %Lens{forward: forward}) do
    Printer.to_sql(forward, ref: View.read_frame(resource))
  end

  defp key_sql(resource, key) do
    View.key_expression(resource, key, View.read_frame(resource))
  end

  defp column_sql(resource, column) do
    View.read_frame(resource).({[], column})
  end

  defp repo(resource) do
    twin = Info.twin(resource)

    case AshPostgres.DataLayer.Info.repo(twin, :read) do
      repo when is_function(repo) -> repo.(twin, :read)
      repo -> repo
    end
  rescue
    _ -> nil
  end

  # A failing assertion aborts its transaction, so each runs in its own -- and the
  # error is returned rather than raised, because one relation this environment
  # does not have is not a reason to stop reporting the rest.
  defp query(repo, sql, params \\ []) do
    case run_query(repo, sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # The exception itself, for the one caller that needs to tell a connection error
  # from a query the database understood and rejected.
  defp run_query(repo, sql, params) do
    case repo.query(sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  # A failed assertion counts as a failure; a check that did not run counts as
  # unmeasured, which fails the task only under `--strict`.
  defp emit(marker, label, detail) do
    Mix.shell().info("    #{marker}  #{label}\n              #{detail}")

    case marker do
      @fail -> {1, 0}
      @unrun -> {0, 1}
      _ -> @none
    end
  end

  # A warning whose message says nothing was measured is a could-not-measure
  # outcome like `????`, and counted as one.
  defp not_measured(label, detail) do
    emit(@warn, label, detail)
    {0, 1}
  end

  defp skipped_note do
    """

    Nothing was measured: `--no-data` was given.

    The declaration above is what the compiler can see. The assertions this task
    exists for -- NULLs where `allow_nil? false`, duplicates under a new identity,
    values that will not cast, and every obligation that could not be decided at
    compile time -- are answers about the legacy rows, and there is no way to reach
    them without reading the legacy rows.
    """
  end

  defp manual_checks do
    """

    Checks this task still cannot make for you
    -----------------------------------------
      1. Is the backfill complete?  Compare row counts between the legacy relation
         and the strangler view. `:read_from_new` with an incomplete backfill
         produces MISSING ROWS, not an error.

      2. Is the legacy write path dead?  Before `:decommissioned`, confirm nothing
         outside this application still writes to the legacy table. This package
         does not answer that: `pg_notify` collapses duplicate notifications within
         a transaction, so notifications cannot count writes, and there is no usage
         counter. Use Postgres's own `pg_stat_user_tables`
         (`n_tup_ins`/`n_tup_upd`/`n_tup_del`) or an audit trigger you install
         yourself.

      3. Does the reconciler report drift?  Run it, and read the output rather than
         the exit code.

    Phase changes are one-way in practice. Run this before each one.
    """
  end
end
