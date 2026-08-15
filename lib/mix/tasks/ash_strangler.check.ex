# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Check do
  @shortdoc "Pre-flight checks for strangler-mapped resources"

  @moduledoc """
  Reports the strangler mapping for every resource that has one, and the checks
  that could not be made at compile time.

      mix ash_strangler.check
      mix ash_strangler.check --domain MyApp.Accounts

  ## What this is for

  The compile-time verifiers catch what is knowable from the code. This reports
  what is knowable from the code *plus* what a human has to confirm before a
  phase change — the things that depend on the state of the data rather than the
  state of the source.

  Run it before every phase change. The phases are one-way in practice: moving
  to `:read_from_new` while the backfill is incomplete produces missing rows, not
  an error.
  """

  use Mix.Task

  @requirements ["app.config"]

  @switches [domain: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    resources = strangled_resources(opts[:domain])

    if resources == [] do
      Mix.shell().info("No resources use AshStrangler.Resource.")
    else
      Enum.each(resources, &report/1)
      Mix.shell().info(manual_checks())
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

  defp report(resource) do
    source = AshStrangler.Info.source(resource)
    phase = AshStrangler.Info.strangler_phase!(resource)
    writes = AshStrangler.Info.writes(resource)

    mappings = AshStrangler.Info.mappings(resource)
    read_only = Enum.reject(mappings, & &1.writable?)

    Mix.shell().info("""

    #{inspect(resource)}
      source     #{source.relation}
      phase      #{inspect(phase)}
      writes     #{inspect(writes)}#{derived_note(source)}
      mappings   #{length(mappings)} mapped, #{length(AshStrangler.Info.constants(resource))} constant, #{unmapped_count(resource)} unmapped
      read-only  #{read_only_summary(read_only)}#{joins_summary(resource)}#{upsert_warning(resource, writes)}#{fan_out_warning(resource, source)}
    """)
  end

  defp joins_summary(resource) do
    case AshStrangler.Info.joins(resource) do
      [] ->
        ""

      joins ->
        "\n      joins      " <>
          Enum.map_join(joins, ", ", fn join ->
            "#{join.relation} AS #{AshStrangler.Sql.View.alias_for(join)} (#{join.type})"
          end)
    end
  end

  # The hazard a join introduces that no compile-time check can see: if the
  # joined relation has more than one row per primary row, the view returns
  # several rows for one primary key. `Ash.get/2` then finds duplicates, counts
  # inflate, and nothing raises -- the view is perfectly valid SQL.
  #
  # It depends entirely on the data, which is exactly why it belongs here rather
  # than in a verifier.
  defp fan_out_warning(resource, source) do
    case AshStrangler.Info.joins(resource) do
      [] -> ""
      _ -> measure_fan_out(resource, source)
    end
  end

  defp measure_fan_out(resource, source) do
    repo = AshPostgres.DataLayer.Info.repo(resource)
    from_clause = AshStrangler.Sql.View.from_clause(source)

    %{rows: [[base]]} = repo.query!("SELECT count(*) FROM #{source.relation}", [])
    %{rows: [[joined]]} = repo.query!("SELECT count(*) FROM #{from_clause}", [])

    cond do
      joined > base ->
        """

        \e[31mFAN-OUT\e[0m  the joins multiply rows: #{base} in #{source.relation}, #{joined} through the view.
                A joined relation has more than one row per primary row, so the view
                returns duplicates for a single primary key. Ash.get/2 will find more
                than one record and counts will be wrong. Narrow the join condition,
                or model the joined relation as its own resource.
        """

      joined < base ->
        """

        \e[33mROWS LOST\e[0m  #{base} rows in #{source.relation}, only #{joined} through the view.
                An INNER JOIN is dropping rows the legacy application can still see.
                Use `type: :left` unless the match is genuinely total.
        """

      true ->
        ""
    end
  rescue
    # The check is best-effort: the legacy relations may not exist yet in this
    # environment, and that is not a reason to fail the whole report.
    _ -> ""
  end

  defp derived_note(%{writes: nil}), do: "  (derived from the mapping shape)"
  defp derived_note(_), do: "  (declared)"

  defp unmapped_count(resource) do
    resource
    |> AshStrangler.Info.unmapped()
    |> Enum.flat_map(& &1.attributes)
    |> length()
  end

  defp read_only_summary([]), do: "none"

  defp read_only_summary(mappings) do
    Enum.map_join(mappings, "\n                 ", fn m ->
      "#{m.attribute} — #{m.because}"
    end)
  end

  # The compile-time verifier only rejects this combination when `writes` is
  # :triggers. Reporting it here too means someone reading the pre-flight output
  # sees why they cannot move to a trigger-based mapping later.
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
        "\n      NOTE       upsert actions #{inspect(names)} require writes: :auto." <>
          "\n                 This resource cannot move to INSTEAD OF triggers."
    end
  end

  defp upsert_warning(_resource, _writes), do: ""

  defp manual_checks do
    """

    Checks this task cannot make for you
    ------------------------------------
    These depend on the state of the data, not the state of the code:

      1. Is the backfill complete?  Compare row counts between the legacy
         relation and the strangler view. `:read_from_new` with an incomplete
         backfill produces MISSING ROWS, not an error.

      2. Is the legacy write path dead?  Before `:decommissioned`, confirm
         nothing outside this application still writes to the legacy table.
         This package does not answer that for you: `pg_notify` collapses
         duplicate notifications within a transaction, so notifications cannot
         count writes, and there is no usage counter. Use Postgres's own
         `pg_stat_user_tables` (`n_tup_ins`/`n_tup_upd`/`n_tup_del`) or an audit
         trigger you install yourself.

      3. Does the reconciler report drift?  Run it, and read the output rather
         than the exit code.

    Phase changes are one-way in practice. Run this before each one.
    """
  end
end
