# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Obligations do
  @moduledoc """
  The obligation registry of an estate, and the report that measures it.

  An obligation is a statement about legacy *rows* (`AshStrangler.Estate.Obligation`).
  The registry is everything an estate can be asked to prove at run time:

    * every assertion `AshStrangler.Obligations` could not decide at compile
      time, for each strangled resource of the estate;
    * a census of the elements an `element` source of an `AshStrangler.Derived`
      refuses (see the integer guard), one per source;
    * for each group of union branches that share a key namespace
      (`shares_key_with`), `key-disjoint:<view>:<a>+<b>`: the ids of the view that
      more than one of them produces. Its severity is `:error`: such an id is
      two rows a write cannot tell apart;
    * whatever each plug-in returns from `c:AshStrangler.Estate.Plugin.obligations/1`.

  `report/3` measures them and returns the report below. `mix ash_strangler.check
  --estate` writes it as JSON.

  ## The report (format `ash_strangler.obligations/1`)

      %{
        "format" => "ash_strangler.obligations/1",
        "estate" => "MyApp.Legacy.Estate",
        "catalog" => %{"path" => "...", "sha256" => "..."},   # the snapshot the run is keyed by
        "measured" => true,                # false when no database was read
        "summary" => %{"total" => 3, "pass" => 1, "warn" => 1, "fail" => 1, "error" => 0, "skipped" => 0},
        "problems" => [%{"check" => "tenant", "subject" => "...", "message" => "..."}],
        "obligations" => [
          %{
            "id" => "element:clinic.properties.listed",
            "source" => "MyApp.Properties",
            "summary" => "...",
            "denominator" => "elements of visits.metadata -> propertyIds",
            "severity" => "warning",       # "error" | "warning"
            "status" => "warn",            # "pass" | "warn" | "fail" | "error" | "skipped"
            "violations" => 4,             # null unless measured
            "total" => 120,                # null unless the obligation has a denominator count
            "detail" => null               # the error message, or the offending rows (at most 10)
          }
        ]
      }

  `problems` are the estate's own checks (`AshStrangler.Estate.evaluate/1`).
  Obligations are sorted by `id`, problems by `check`, `subject` and
  `message`, and the report holds no timestamp, so the same estate over the same
  rows gives the same bytes. Encode with `AshStrangler.Snapshot.Catalog.encode/1`.

  `status`: `pass` (no violation), `warn` (violations of a `:warning`), `fail`
  (violations of an `:error`), `error` (the query could not run) or `skipped`
  (`measure?: false`). `failed?/1` is true for `fail` and `error` and for any
  estate problem: an obligation that could not be measured is not green.
  """

  alias AshStrangler.{Derived, Estate, Info, Migration, Obligations, Union}
  alias AshStrangler.Estate.Obligation

  @format "ash_strangler.obligations/1"

  @doc "Every obligation of `estate`, in id order."
  @spec registry(module()) :: [Obligation.t()]
  def registry(estate) do
    modules = Estate.resources(estate)

    (resource_obligations(modules) ++
       element_obligations(modules) ++
       key_disjoint_obligations(modules) ++ plugin_obligations(estate))
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Measures `estate`.

  Options: `repo` (default: the repo of the first twin of the estate's
  resources, else `config :ash_strangler, repo: MyApp.Repo`) and `measure?` (default `true`; `false` skips every query).
  """
  @spec report(module(), keyword()) :: map()
  def report(estate, opts \\ []) do
    evaluated = Estate.evaluate(estate)
    obligations = registry(estate)
    measure? = Keyword.get(opts, :measure?, true) and obligations != []
    repo = Keyword.get_lazy(opts, :repo, fn -> repo(estate) end)

    rows =
      for obligation <- obligations do
        result = if measure?, do: measure(repo, obligation), else: :skipped
        row(obligation, result)
      end

    %{
      "format" => @format,
      "estate" => inspect(estate),
      "catalog" => %{"path" => evaluated.catalog_path, "sha256" => evaluated.catalog_sha256},
      "measured" => measure? and Enum.any?(rows, &(&1["status"] != "error")),
      "summary" => summary(rows),
      "problems" =>
        evaluated.problems
        |> Enum.map(
          &%{"check" => to_string(&1.check), "subject" => &1.subject, "message" => &1.message}
        )
        |> Enum.sort_by(&{&1["check"], &1["subject"] || "", &1["message"]}),
      "obligations" => rows
    }
  end

  @doc "Whether the report fails a gate: a failed or unmeasurable obligation, or an estate problem."
  @spec failed?(map()) :: boolean()
  def failed?(%{"summary" => summary, "problems" => problems}),
    do: summary["fail"] + summary["error"] > 0 or problems != []

  # --- the registry ------------------------------------------------------------

  defp resource_obligations(modules) do
    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :spark_dsl_config, 0),
        Info.strangled?(module),
        finding <- Obligations.assertions(module) do
      %Obligation{
        id: "#{finding.obligation}:#{inspect(module)}.#{finding.attribute}",
        summary: finding.message,
        denominator: "the rows the assertion returns",
        sql: finding.assertion,
        shape: Obligations.assertion_shape(finding.assertion),
        severity: finding.severity,
        source: inspect(module)
      }
    end
  end

  defp element_obligations(modules) do
    for module <- modules,
        Migration.derived?(module),
        source <- Derived.Info.elements(module) do
      view = "#{Derived.Info.schema(module)}.#{Derived.Info.view(module)}"

      %Obligation{
        id: "element:#{view}.#{source.name}",
        summary:
          "elements of #{inspect(source.from)} the #{source.type} guard refuses yield no row in #{view}",
        denominator:
          "elements of #{inspect(source.from)} #{inspect(source.path)} of every live row",
        sql: Derived.Sql.element_census_sql(module, source),
        shape: :census,
        severity: :warning,
        source: inspect(module)
      }
    end
  end

  defp key_disjoint_obligations(modules) do
    for module <- modules,
        Migration.union?(module),
        group <- Union.Info.key_sharing_groups(module) do
      view = "#{Union.Info.schema(module)}.#{Union.Info.view(module)}"
      names = Enum.map_join(group, ", ", &inspect/1)

      %Obligation{
        id: "key-disjoint:#{Union.Info.view(module)}:#{Enum.join(group, "+")}",
        summary:
          "branches #{names} share a key namespace (`shares_key_with`): no id of #{view} comes from more than one of them",
        denominator: "distinct ids branches #{names} put in #{view}",
        sql: Union.Sql.key_disjoint_census_sql(module, group),
        shape: :census,
        severity: :error,
        source: inspect(module)
      }
    end
  end

  defp plugin_obligations(estate) do
    for plugin <- Estate.plugins(estate),
        Code.ensure_loaded?(plugin) and function_exported?(plugin, :obligations, 1),
        obligation <- plugin.obligations(estate) do
      %{obligation | source: obligation.source || inspect(plugin)}
    end
  end

  # --- measuring ---------------------------------------------------------------

  defp repo(estate) do
    twin =
      Enum.find_value(Estate.resources(estate), fn module ->
        cond do
          Migration.derived?(module) ->
            Derived.Info.twin(module)

          Migration.union?(module) ->
            module |> AshStrangler.Union.Info.branches() |> List.first() |> then(&(&1 && &1.twin))

          Info.strangled?(module) ->
            Info.twin(module)

          true ->
            module
        end
      end)

    if twin,
      do: AshPostgres.DataLayer.Info.repo(twin, :read),
      else: Application.get_env(:ash_strangler, :repo)
  end

  defp measure(nil, _obligation),
    do:
      {:error,
       "no repo: pass `repo:`, list a twin in the estate or set `config :ash_strangler, repo:`"}

  defp measure(repo, %Obligation{sql: sql, shape: shape}) do
    run = fn -> repo.query(sql, []) end

    case if(Process.whereis(repo), do: run.(), else: with_repo(repo, run)) do
      {:ok, result} -> interpret(shape, result)
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp with_repo(repo, fun) do
    case Ecto.Migrator.with_repo(repo, fn _ -> fun.() end) do
      {:ok, result, _apps} -> result
      {:error, reason} -> {:error, %RuntimeError{message: "repo unavailable: #{inspect(reason)}"}}
    end
  end

  defp interpret(:census, %{rows: [[violations, total]]}), do: {:ok, violations, total, nil}

  defp interpret(:census, other),
    do: {:error, "a census returns one row of two integers, got #{inspect(other.rows)}"}

  defp interpret(:count, %{rows: [[n]]}) when is_integer(n), do: {:ok, n, nil, nil}

  defp interpret(:count, other),
    do: {:error, "a count returns one row of one integer, got #{inspect(other.rows)}"}

  defp interpret(:rows, %{rows: []}), do: {:ok, 0, nil, nil}
  defp interpret(:rows, %{rows: [[0]]}), do: {:ok, 0, nil, nil}

  defp interpret(:rows, %{rows: rows}),
    do:
      {:ok, length(rows), nil,
       rows |> Enum.take(10) |> Enum.map(&Enum.map(&1, fn v -> detail(v) end))}

  defp detail(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: if(is_binary(value) and not String.valid?(value), do: inspect(value), else: value)

  defp detail(value), do: inspect(value)

  # --- the report --------------------------------------------------------------

  defp row(obligation, result) do
    {status, violations, total, detail} =
      case result do
        :skipped ->
          {"skipped", nil, nil, nil}

        {:error, message} ->
          {"error", nil, nil, message}

        {:ok, 0, total, detail} ->
          {"pass", 0, total, detail}

        {:ok, n, total, detail} ->
          {(obligation.severity == :error && "fail") || "warn", n, total, detail}
      end

    %{
      "id" => obligation.id,
      "source" => obligation.source,
      "summary" => obligation.summary,
      "denominator" => obligation.denominator,
      "severity" => to_string(obligation.severity),
      "status" => status,
      "violations" => violations,
      "total" => total,
      "detail" => detail
    }
  end

  defp summary(rows) do
    counts = Enum.frequencies_by(rows, & &1["status"])

    for status <- ~w(pass warn fail error skipped), into: %{"total" => length(rows)} do
      {status, Map.get(counts, status, 0)}
    end
  end
end
