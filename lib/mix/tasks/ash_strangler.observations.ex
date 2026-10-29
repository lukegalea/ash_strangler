# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Observations do
  @shortdoc "Inspects and replays the observation store"

  @moduledoc """
  Lists, inspects and replays observations and their receipts.

      mix ash_strangler.observations                                   # recent, all
      mix ash_strangler.observations --resource MyApp.Clm.Contract
      mix ash_strangler.observations --quarantined                     # one consumer
      mix ash_strangler.observations --inspect <observation-uuid>      # full envelope
      mix ash_strangler.observations --replay                          # reset all receipts
      mix ash_strangler.observations --replay --consumer MyApp.MyObserver
      mix ash_strangler.observations --replay --observation-id <uuid>

  Replay deletes receipts, never observations: the next drain re-delivers
  every observation the deleted receipt covered to that consumer. Idempotence
  is the consumer's contract (`AshStrangler.Observer`), and replay is how a
  fixed consumer catches up.
  """

  use Mix.Task


  @requirements ["app.config"]

  @switches [
    resource: :string,
    quarantined: :boolean,
    consumer: :string,
    inspect: :string,
    replay: :boolean,
    limit: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    repo = repo!()

    cond do
      opts[:inspect] ->
        inspect_observation(repo, opts[:inspect])

      opts[:replay] ->
        replay(repo, opts)

      true ->
        list(repo, opts)
    end
  end

  defp repo! do
    case strangled_resources() do
      [] ->
        Mix.raise("no strangled resources found -- nothing observes anything")

      [resource | _] ->
        repo = AshPostgres.DataLayer.Info.repo(resource)
        {:ok, _} = repo.start_link([])
        repo
    end
  end

  defp strangled_resources do
    (Application.get_env(:ash, :ash_domains, []) ++
       Enum.flat_map(Application.loaded_applications(), fn {app, _, _} ->
         Application.get_env(app, :ash_domains, [])
       end))
    |> Enum.uniq()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&AshStrangler.Info.strangled?/1)
  end

  defp list(repo, opts) do
    clauses = []

    clauses =
      if opts[:resource],
        do: [{"resource = $#{length(clauses) + 1}", opts[:resource]} | clauses],
        else: clauses

    clauses =
      if opts[:quarantined],
        do: [
          {"id IN (SELECT observation_id FROM \"strangler_receipts\" WHERE state = 'quarantined')" <>
             consumer_clause(opts, clauses), nil}
          | clauses
        ],
        else: clauses

    where =
      clauses
      |> Enum.reverse()
      |> Enum.map_join(" AND ", fn
        {text, nil} -> text
        {text, _value} -> text
      end)

    where = if where == "", do: "", else: "WHERE " <> where
    limit = opts[:limit] || 25

    params = clauses |> Enum.reverse() |> Enum.map(fn {_t, v} -> v end) |> Enum.reject(&is_nil/1)

    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT id, category, resource, record_id, operation, origin,
               correlation_id, mapping_version, captured_at
          FROM "strangler_observations"
          #{where}
         ORDER BY captured_at DESC
         LIMIT #{limit}
        """,
        params
      )

    if rows == [] do
      Mix.shell().info("no observations#{scope_note(opts)}.")
    else
      Enum.each(rows, fn [id, category, resource, record_id, operation, origin, corr, version, at] ->
        Mix.shell().info(
          "#{at} #{category} #{operation} #{resource} " <>
            "#{record_id || "-"} origin=#{origin} #{corr && "corr=" <> corr} " <>
            "v=#{String.slice(version || "", 0, 8)} #{id}"
        )
      end)
    end

    print_quarantines(repo)
  end

  defp consumer_clause(opts, _clauses) do
    if opts[:consumer], do: " AND consumer = '" <> opts[:consumer] <> "'", else: ""
  end

  defp scope_note(opts) do
    if opts[:resource], do: " for #{opts[:resource]}", else: ""
  end

  defp print_quarantines(repo) do
    %Postgrex.Result{rows: rows} =
      repo.query!("""
      SELECT consumer, observation_id, last_error, recorded_at
        FROM "strangler_receipts" WHERE state = 'quarantined'
       ORDER BY recorded_at DESC LIMIT 25
      """)

    if rows != [] do
      Mix.shell().info("\nquarantined:")

      Enum.each(rows, fn [consumer, observation_id, last_error, at] ->
        Mix.shell().info("#{at} #{consumer} #{observation_id} #{last_error || ""}")
      end)
    end
  end

  defp inspect_observation(repo, id) do
    case repo.query!("SELECT * FROM \"strangler_observations\" WHERE id = $1", [id]) do
      %Postgrex.Result{columns: columns, rows: [[values]]} ->
        envelope = Enum.zip(columns, values) |> Map.new()

        Mix.shell().info(
          inspect(envelope, pretty: true, limit: :infinity, printable_limit: :infinity)
        )

      _ ->
        Mix.raise("no observation #{id}")
    end
  end

  defp replay(repo, opts) do
    {sql, params} = replay_sql(opts)

    %Postgrex.Result{num_rows: deleted} = repo.query!(sql, params)

    Mix.shell().info(
      "#{deleted} receipt(s) deleted -- the next drain re-delivers those observations."
    )
  end

  defp replay_sql(opts) do
    clauses =
      [
        if(opts[:consumer], do: {"consumer = $1", opts[:consumer]}),
        if(opts[:"observation-id"], do: {"observation_id = $2", opts[:"observation-id"]})
      ]
      |> Enum.reject(&is_nil/1)

    case clauses do
      [] ->
        {"DELETE FROM \"strangler_receipts\"", []}

      clauses ->
        where =
          clauses
          |> Enum.with_index(1)
          |> Enum.map_join(" AND ", fn {{text, _}, i} ->
            String.replace(text, "$1", "$#{i}") |> String.replace("$2", "$#{i}")
          end)

        {"DELETE FROM \"strangler_receipts\" WHERE " <> where, Enum.map(clauses, &elem(&1, 1))}
    end
  end
end
