# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshStrangler.Observations do
  @shortdoc "Inspects and replays the observation store"

  @moduledoc """
  Lists, inspects and replays observations and their receipts.

      mix ash_strangler.observations                                   # recent, all
      mix ash_strangler.observations --resource MyApp.Clm.Contract
      mix ash_strangler.observations --consumer MyApp.MyObserver
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
    observation_id: :string,
    limit: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    repo = repo!()

    with_repo(repo, fn repo ->
      cond do
        opts[:inspect] -> inspect_observation(repo, opts[:inspect])
        opts[:replay] -> replay(repo, opts)
        true -> list(repo, opts)
      end
    end)
  end

  defp repo! do
    case strangled_resources() do
      [] ->
        Mix.raise("no strangled resources found -- nothing observes anything")

      [resource | _] ->
        AshPostgres.DataLayer.Info.repo(resource)
    end
  end

  defp with_repo(repo, fun) do
    if Process.whereis(repo) do
      fun.(repo)
    else
      case Ecto.Migrator.with_repo(repo, fun) do
        {:ok, result, _apps} -> result
        {:error, reason} -> Mix.raise("could not start #{inspect(repo)}: #{inspect(reason)}")
      end
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
    {filters, params} = list_filters(opts)
    where = if filters == [], do: "", else: "WHERE " <> Enum.join(filters, " AND ")
    limit = opts[:limit] || 25

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
            "#{record_id || "-"} origin=#{origin} #{if corr, do: "corr=" <> corr, else: ""} " <>
            "v=#{String.slice(version || "", 0, 8)} #{id}"
        )
      end)
    end

    print_quarantines(repo, opts[:consumer])
  end

  defp list_filters(opts) do
    {filters, params} =
      if opts[:resource] do
        {["resource = $1"], [opts[:resource]]}
      else
        {[], []}
      end

    cond do
      opts[:quarantined] && opts[:consumer] ->
        n = length(params) + 1

        {filters ++
           [
             "id IN (SELECT observation_id FROM \"strangler_receipts\" WHERE state = 'quarantined' AND consumer = $#{n})"
           ], params ++ [opts[:consumer]]}

      opts[:quarantined] ->
        {filters ++
           [
             "id IN (SELECT observation_id FROM \"strangler_receipts\" WHERE state = 'quarantined')"
           ], params}

      opts[:consumer] ->
        n = length(params) + 1

        {filters ++
           ["id IN (SELECT observation_id FROM \"strangler_receipts\" WHERE consumer = $#{n})"],
         params ++ [opts[:consumer]]}

      true ->
        {filters, params}
    end
  end

  defp scope_note(opts) do
    if opts[:resource], do: " for #{opts[:resource]}", else: ""
  end

  defp print_quarantines(repo, consumer) do
    {where, params} =
      if consumer do
        {"WHERE state = 'quarantined' AND consumer = $1", [consumer]}
      else
        {"WHERE state = 'quarantined'", []}
      end

    %Postgrex.Result{rows: rows} =
      repo.query!(
        """
        SELECT consumer, observation_id, last_error, recorded_at
          FROM "strangler_receipts" #{where}
         ORDER BY recorded_at DESC LIMIT 25
        """,
        params
      )

    if rows != [] do
      Mix.shell().info("\nquarantined:")

      Enum.each(rows, fn [consumer, observation_id, last_error, at] ->
        Mix.shell().info("#{at} #{consumer} #{observation_id} #{last_error || ""}")
      end)
    end
  end

  defp inspect_observation(repo, id) do
    case repo.query!(
           "SELECT * FROM \"strangler_observations\" WHERE id = $1",
           [Ecto.UUID.dump!(id)]
         ) do
      %Postgrex.Result{columns: columns, rows: [values]} ->
        envelope = Enum.zip(columns, values) |> Map.new()

        Mix.shell().info(
          inspect(envelope, pretty: true, limit: :infinity, printable_limit: :infinity)
        )

      _ ->
        Mix.raise("no observation #{id}")
    end
  end

  defp replay(repo, opts) do
    {where, params} = replay_filter(opts)

    %Postgrex.Result{num_rows: deleted} =
      repo.query!("DELETE FROM \"strangler_receipts\" #{where}", params)

    Mix.shell().info(
      "#{deleted} receipt(s) deleted -- the next drain re-delivers those observations."
    )
  end

  defp replay_filter(opts) do
    filters = []
    params = []

    {filters, params} =
      if opts[:consumer] do
        {filters ++ ["consumer = $#{length(params) + 1}"], params ++ [opts[:consumer]]}
      else
        {filters, params}
      end

    {filters, params} =
      if opts[:observation_id] do
        {filters ++ ["observation_id = $#{length(params) + 1}"],
         params ++ [Ecto.UUID.dump!(opts[:observation_id])]}
      else
        {filters, params}
      end

    case filters do
      [] -> {"", []}
      filters -> {"WHERE " <> Enum.join(filters, " AND "), params}
    end
  end
end
