# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Observation do
  @moduledoc """
  The observation envelope: what one ledger event MEANT for one resource.

  A baseline observation says "this row was seen as executed", never
  "execution happened now" — baselines are never business events. An
  `:observation` carries the projected before/after of the row-local,
  legacy-backed attributes (exact values), the exact changed set, and the
  invalidated set for attributes read through joins whose source row moved.

  `source_event_id` — the ledger's bigserial id — is the dedup key. Delivery
  is at-least-once and never exactly-once, and ledger id order is NOT commit
  order: a consumer reconciles via `source_event_id` and `source`, never by
  comparing ids as timestamps.
  """

  alias AshStrangler.{Info, KeyDerivation, Lens, MappingVersion, Sql.Printer, Twin}

  defstruct [
    :id,
    :source_event_id,
    :baseline_group,
    :category,
    :resource,
    :record_id,
    :operation,
    :before,
    :after,
    :changed_attributes,
    :invalidated_attributes,
    :origin,
    :attribution,
    :correlation_id,
    :causation_id,
    :mapping_version,
    :source,
    :captured_at,
    :recorded_at
  ]

  @type t :: %__MODULE__{}

  @doc """
  Projects one ledger row for `resource` into an observation envelope.

  ONE SELECT per event: the row's `new_row`/`old_row` jsonb images are bound
  as `new`/`old`, and every row-local legacy-backed attribute is rendered
  through the jsonb frame — `(new->>'column')::<pg type>` — by the same
  printer that renders the view. Row-local attributes are exact. Attributes
  whose sources cross a relationship are excluded from before/after (their
  source row is a different row; invalidations own those), as are the
  extension attributes (not legacy storage) and the key (record_id covers
  it).
  """
  @spec project(Ash.Resource.t(), map(), Ecto.Repo.t()) :: t()
  def project(resource, row, repo) do
    key = Info.key(resource)
    {selects, excluded} = projections(resource)

    columns = Enum.map(selects, fn {attribute, _, _} -> attribute end)

    sql = project_sql(selects)

    %Postgrex.Result{columns: returned_columns, rows: [values]} =
      repo.query!(sql, [row.new_row, row.old_row])

    projections = Enum.zip(returned_columns, values) |> Map.new()
    {before, after_image} = split(projections, columns)

    %__MODULE__{
      id: Ash.UUID.generate(),
      source_event_id: row.id,
      baseline_group: nil,
      category: :observation,
      resource: resource,
      record_id: record_id(key, Info.relation(resource), row.primary_key),
      operation: String.to_existing_atom(row.operation),
      before: before,
      after: after_image,
      changed_attributes: changed(projections, columns),
      invalidated_attributes: [],
      origin: origin(row.source_system),
      attribution: %{actor: row.source_user, confidence: confidence(row.actor_confidence)},
      correlation_id: row.source_correlation_id,
      causation_id: row.source_request_id,
      mapping_version: MappingVersion.hash(resource),
      source: %{
        relation: "#{row.source_schema}.#{row.source_table}",
        primary_key: row.primary_key,
        transaction_id: row.transaction_id,
        timestamp: row.transaction_timestamp,
        # Attributes this projection does NOT speak for: joined reads (their
        # source row is elsewhere -- invalidations own those), extension
        # columns (not legacy storage) and the key (record_id covers it).
        unprojected_attributes: Enum.sort(excluded)
      },
      captured_at: row.emitted_at || row.transaction_timestamp,
      recorded_at: DateTime.utc_now()
    }
  end

  @doc """
  The forward mapping evaluated against ONE legacy row's jsonb image —
  row-local legacy-backed attributes only, exactly as the projector would
  read them. The baseline is this, stamped `category: :baseline`.
  """
  @spec evaluate_row(Ash.Resource.t(), map(), Ecto.Repo.t()) :: %{
          attributes: map(),
          unprojected_attributes: [atom()],
          record_id: String.t() | nil
        }
  def evaluate_row(resource, row_json, repo) do
    key = Info.key(resource)
    {included, excluded} = split_projectable(resource)
    frame = jsonb_frame(Info.twin(resource), "row")

    selects =
      Enum.map(included, fn lens ->
        {lens.attribute, Printer.to_sql(lens.forward, ref: frame)}
      end)

    sql =
      "SELECT " <>
        Enum.map_join(selects, ", ", fn {attribute, sql} -> "(#{sql}) AS #{attribute}" end) <>
        " FROM (SELECT $1::jsonb AS row) AS images"

    %Postgrex.Result{columns: returned_columns, rows: [values]} =
      repo.query!(sql, [row_json])

    attributes = Enum.zip(returned_columns, values) |> Map.new()

    %{
      attributes: attributes,
      unprojected_attributes: Enum.sort(Enum.map(excluded, & &1.attribute)),
      record_id:
        record_id(key, Info.relation(resource), %{key.from => row_json[to_string(key.from)]})
    }
  end

  # `{attribute, new_sql, old_sql}` for every attribute the projector can
  # speak about exactly.
  defp projections(resource) do
    twin = Info.twin(resource)
    new_frame = jsonb_frame(twin, "new")
    old_frame = jsonb_frame(twin, "old")

    {included, excluded} = split_projectable(resource)

    selects =
      Enum.map(included, fn lens ->
        new_sql = Printer.to_sql(lens.forward, ref: new_frame)
        old_sql = Printer.to_sql(lens.forward, ref: old_frame)
        {lens.attribute, new_sql, old_sql}
      end)

    {selects, Enum.map(excluded, & &1.attribute)}
  end

  defp split_projectable(resource) do
    projectable? = fn lens ->
      lens.combinator not in [:key, :extension, :tenant] and
        Enum.all?(lens.sources, fn {path, _attr} -> path == [] end) and
        not references_extension?(lens)
    end

    resource |> Lens.for_resource() |> Enum.split_with(projectable?)
  end

  # A collapse with `{:extension, _}` states reads the extension table in its
  # forward direction (`ext."column" = 'state'`) -- the ledger row carries no
  # extension columns, so the projection cannot speak for it. The extension
  # state's own write path is the trigger's; the observation envelope
  # reports the attribute as unprojected rather than guessing.
  defp references_extension?(%Lens{combinator: :collapse, entry: entry}) do
    Lens.extension_state_columns(entry) != []
  end

  defp references_extension?(_lens), do: false

  defp project_sql(selects) do
    cols =
      Enum.map_join(selects, ", ", fn {attribute, new_sql, old_sql} ->
        "(#{new_sql}) AS new_#{attribute}, (#{old_sql}) AS old_#{attribute}, " <>
          "((#{new_sql}) IS DISTINCT FROM (#{old_sql})) AS changed_#{attribute}"
      end)

    "SELECT #{cols} FROM (SELECT $1::jsonb AS new, $2::jsonb AS old) AS images"
  end

  defp split(projections, columns) do
    before = Map.new(columns, fn attribute -> {attribute, projections["old_#{attribute}"]} end)

    after_image =
      Map.new(columns, fn attribute -> {attribute, projections["new_#{attribute}"]} end)

    {before, after_image}
  end

  defp changed(projections, columns) do
    columns |> Enum.filter(&projections["changed_#{&1}"]) |> Enum.sort()
  end

  # `(new->>'column')::<pg type>` — the event's jsonb image read with the same
  # typing the view uses, from the same twin. Row-local only: the projector
  # raises on a joined reference rather than guessing which row it names.
  @doc false
  def jsonb_frame(twin, alias_name) do
    fn
      {[], attribute} ->
        column = Twin.column!(twin, attribute)
        type = attr_type(twin, attribute)
        "(#{alias_name}->>" <> Printer.literal(column) <> ")::" <> type

      {_path, _attribute} ->
        raise ArgumentError,
              "the projector projects row-local attributes only; a joined read belongs to an invalidation"
    end
  end

  defp attr_type(twin, attribute) do
    case Ash.Resource.Info.attribute(twin, attribute) do
      %{type: type} -> Printer.pg_type!(type)
      _ -> "text"
    end
  end

  defp record_id(key, relation, primary_key) do
    legacy_id = Map.get(primary_key, key.from) || Map.get(primary_key, to_string(key.from))
    KeyDerivation.derive(key, relation, legacy_id)
  end

  defp origin(nil), do: :unknown
  defp origin("host"), do: :host
  defp origin("legacy"), do: :legacy
  defp origin(other) when is_binary(other), do: String.to_existing_atom(other)

  defp confidence(nil), do: :unknown
  defp confidence("asserted"), do: :asserted
  defp confidence("verified"), do: :verified
  defp confidence(other) when is_binary(other), do: String.to_existing_atom(other)
end
