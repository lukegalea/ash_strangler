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
  | twin identities | the twin's unique sets against `pg_index` |
  | a relationship-derived join | row counts through the join, for fan-out |

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
  an identity claims.

  ## Exit code

  Non-zero when an assertion fails, so the twin-staleness diff can gate CI —
  without that the typed layer inherits exactly the staleness problem it was built
  to remove. Warnings do not fail: guard overlap that holds for no row the data
  contains is a warning by construction, and refusing on it would refuse correct
  mappings.

  A check that could not *run* — no database reachable — is reported as such and
  does not fail the task. "Could not be measured" and "measured clean" are
  different answers, and collapsing them is how a green build comes to mean
  nothing.

  Run it before every phase change. The phases are one-way in practice: moving to
  `:read_from_new` while the backfill is incomplete produces missing rows, not an
  error.
  """

  use Mix.Task

  alias AshStrangler.{Info, Lens, Mechanism, Obligations, Twin}
  alias AshStrangler.Sql.{Printer, View}

  @requirements ["app.config"]

  @switches [domain: :string, data: :boolean]

  @ok "\e[32mok\e[0m  "
  @fail "\e[31mFAIL\e[0m"
  @warn "\e[33mwarn\e[0m"
  @unrun "\e[33m????\e[0m"

  # The report's label column is thirteen characters wide. Interpolated strings are
  # not de-indented by the heredoc they land in, so a continuation line has to
  # count them out itself.
  @continued "\n             "

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    resources = strangled_resources(opts[:domain])

    if resources == [] do
      Mix.shell().info("No resources use AshStrangler.Resource.")
    else
      Enum.each(resources, &report/1)

      failures =
        if opts[:data] == false do
          Mix.shell().info(skipped_note())
          0
        else
          measure(resources)
        end

      Mix.shell().info(manual_checks())

      if failures > 0 do
        Mix.shell().error("#{failures} assertion(s) failed against the legacy data.")
        exit({:shutdown, 1})
      end
    end
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
    """)
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
    |> Enum.sum()
  end

  defp measure_group(nil, group) do
    Mix.shell().info("""

    #{@unrun}  #{Enum.map_join(group, ", ", &inspect/1)}
          No repo could be resolved from the twin, so nothing was measured.
    """)

    0
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
        {:ok, failures, _apps} -> failures
        {:error, reason} -> unavailable(repo, reason)
      end
    end
  end

  defp run_checks(repo, group) do
    Enum.sum(Enum.map(group, &measure_resource(repo, &1)) ++ measure_twins(repo, group))
  end

  defp unavailable(repo, reason) do
    Mix.shell().info("""

    #{@unrun}  #{inspect(repo)} could not be started: #{inspect(reason)}
          Nothing was measured for it. That is not the same answer as "measured
          clean", so the task does not fail on it -- but a CI run reporting this has
          checked nothing.
    """)

    0
  end

  defp measure_resource(repo, resource) do
    Mix.shell().info("\n  #{inspect(resource)} against #{Info.relation(resource)}")

    [
      &null_checks(repo, &1),
      &identity_checks(repo, &1),
      &cast_check(repo, &1),
      &obligation_checks(repo, &1),
      &fan_out_check(repo, &1)
    ]
    |> Enum.map(& &1.(resource))
    |> Enum.sum()
  end

  # --- allow_nil? false --------------------------------------------------

  defp null_checks(repo, resource) do
    lenses = Lens.by_attribute(resource)
    key = Info.key(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(& &1.allow_nil?)
    |> Enum.map(&null_check(repo, resource, &1, lenses, key))
    |> Enum.sum()
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
        emit(@warn, label, "no mapping accounts for it, so nothing was measured")
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
    |> Enum.sum()
  end

  defp identity_check(repo, resource, identity, lenses) do
    label = "identity #{identity.name} (#{Enum.join(identity.keys, ", ")})"
    expressions = Enum.map(identity.keys, &identity_expression(resource, &1, lenses))

    if Enum.any?(expressions, &is_nil/1) do
      emit(@warn, label, "a key has no mapping to group by, so nothing was measured")
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
  defp cast_check(repo, resource) do
    projections = projections(resource)

    case query(repo, projection_sql(resource, projections)) do
      {:ok, _result} ->
        emit(@ok, "casts", "every mapping projects over all #{length(projections)} column(s)")

      {:error, _message} ->
        Enum.sum(Enum.map(projections, &cast_check_one(repo, resource, &1)))
    end
  end

  defp cast_check_one(repo, resource, {attribute, expression}) do
    case query(repo, projection_sql(resource, [{attribute, expression}])) do
      {:ok, _result} ->
        0

      {:error, message} ->
        emit(@fail, "cast  #{attribute}", "#{expression} — #{message}")
    end
  end

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

  # --- the obligations that could not be decided -------------------------

  defp obligation_checks(repo, resource) do
    resource
    |> Obligations.assertions()
    |> Enum.map(&obligation_check(repo, &1))
    |> Enum.sum()
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
      [] -> 0
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
    resources
    |> Enum.map(&Info.twin/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
    |> Enum.map(&measure_twin(repo, &1))
  end

  defp measure_twin(repo, twin) do
    Mix.shell().info("\n  #{inspect(twin)} against #{Twin.relation(twin)}")

    twin_freshness(repo, twin) + twin_identities(repo, twin)
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

  # `indpred IS NULL` because a partial unique index does not make the column
  # unique -- it makes it unique among the rows matching the predicate -- and an
  # Ash identity claims the unconditional thing.
  @unique_indexes """
  SELECT array_agg(a.attname ORDER BY a.attname)
    FROM pg_index x
    JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = ANY(x.indkey)
   WHERE x.indrelid = $1::text::regclass
     AND x.indisunique
     AND x.indpred IS NULL
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
    case repo.query(sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp emit(marker, label, detail) do
    Mix.shell().info("    #{marker}  #{label}\n              #{detail}")

    if marker == @fail, do: 1, else: 0
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
