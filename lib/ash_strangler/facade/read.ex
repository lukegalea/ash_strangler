# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Read do
  @moduledoc """
  The manual read behind every facade: it calls the source's read action, as
  the caller.

  ## What travels, and what refuses

  The caller's `actor`, `tenant`, `authorize?` and `as_of` all travel: the
  source's policies and field policies decide, because a facade declares no
  rule about who may see anything. The whole `query.filter` travels too — the
  policy filter included, since Ash calls a manual read even when the policy
  filter is `false` — translated by `AshStrangler.Translate.filter/3`; the
  sort by `Translate.sort/2`; `limit` and `offset` are passed. A translation
  error is returned as an error, never ignored: dropping a filter widens the
  result.

  The filter travels **as the caller's input**: its references are marked
  `input? true` on the source, so the source's own field policies redact it
  the way they redact any caller-supplied filter. A filter on a column the
  caller may not read therefore matches nothing, rather than matching on a
  value they were never shown.

  A sort by a facade attribute whose lens reads a column the caller may not
  read is refused: sorting is reading an order, and an order the caller
  cannot see is a leak, not a convenience.

  ## Two refusals of the read itself

  * **No tenant, no read.** A source with a multitenancy strategy refuses a
    tenant-less call — for a person and for a system actor alike. A `global?
    true` attribute-tenant source would otherwise read every tenant's rows.
  * **`as_of` is read-only where time exists.** Over a temporal source it is
    forwarded, and the rows come back as of that instant. A facade has the
    time of its own source, so a facade over a facade over a temporal source
    forwards it hop by hop (`AshStrangler.Facade.Info.temporal?/1`). Over a
    source with no time, a read that carries `as_of` is refused, never
    dropped: a caller asking for history is asking a question this facade
    cannot answer.

  ## What a read gives back

  Each facade attribute is evaluated with `AshStrangler.Eval.forward/3` over
  the values the source returned. The forward lens is deliberately NOT a
  source calculation: Ash applies no field policy to a column an expression
  reads, so computing there would bypass the source's decisions. A forbidden
  source value becomes a `%Ash.ForbiddenField{}` named for the facade
  attribute — never a value computed from one.

  Ash returns no count for a manual read, and keyset pagination is not
  translated (offset only). The source row's primary key is kept as the
  record's `:source` metadata.
  """

  use Ash.Resource.ManualRead

  alias Ash.Error.Forbidden.ForbiddenField
  alias Ash.Error.Invalid.TenantRequired
  alias Ash.Error.Query.InvalidQuery
  alias AshStrangler.{Facade.Info, Facade.Record, Translate}

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    facade = query.resource
    source = Info.source(facade)
    lenses = Info.lenses(facade)

    with :ok <- tenant_required!(source, query.tenant, facade),
         :ok <- refuse_as_of(source, query.as_of),
         {:ok, filter} <- Translate.filter(lenses, query.filter, source),
         {:ok, sort} <- Translate.sort(lenses, query.sort),
         :ok <- readable_sort!(facade, source, lenses, query.sort, context) do
      facade_query = query
      sorted = Enum.zip(query.sort, sort)

      source
      |> Ash.Query.for_read(Info.read_action(facade), %{}, source_opts(context, query.tenant))
      |> apply_filter(filter)
      |> apply_sort(sorted, facade)
      |> apply_window(facade_query)
      |> load_read_fields(lenses, source)
      |> maybe_as_of(source, query.as_of)
      |> Ash.read(source_opts(context, query.tenant))
      |> case do
        {:ok, rows} -> {:ok, Enum.map(rows, &Record.record(&1, facade, lenses, source))}
        {:ok, rows, _extra} -> {:ok, Enum.map(rows, &Record.record(&1, facade, lenses, source))}
        {:error, error} -> {:error, error}
      end
    end
  end

  # The caller's options, mirrored — the same options go to the source query's
  # `for_read/4` and to `Ash.read/2`: passing `actor:` even as nil turns
  # authorization on, and passing neither `actor` nor `authorize?` runs the
  # source read by the authorization the facade's own domain resolved, which
  # `VerifyAuthorization` holds to be at least as strict as the source's
  # domain's.
  defp source_opts(context, tenant) do
    authorize? = context[:authorize?]

    [tenant: tenant] ++
      if(authorize? != nil || context[:actor], do: [actor: context[:actor]], else: []) ++
      if(authorize? != nil, do: [authorize?: authorize?], else: [])
  end

  # A `global? true` attribute-tenant source reads happily with no tenant —
  # that is what `global?` means — so the facade is the one place a
  # tenant-less call can still be caught, before it spans every tenant.
  defp tenant_required!(source, tenant, facade) do
    if Ash.Resource.Info.multitenancy_strategy(source) && is_nil(tenant) do
      {:error, TenantRequired.exception(resource: facade)}
    else
      :ok
    end
  end

  defp refuse_as_of(source, as_of) do
    if as_of && !Info.temporal?(source) do
      {:error,
       InvalidQuery.exception(
         field: :as_of,
         message:
           "#{inspect(source)} has no time to read as of: it is not a temporal resource, " <>
             "so `as_of` is refused rather than ignored."
       )}
    else
      :ok
    end
  end

  defp apply_filter(query, nil), do: query
  defp apply_filter(query, false), do: Ash.Query.do_filter(query, false)
  defp apply_filter(query, filter), do: Ash.Query.do_filter(query, caller_input(filter))

  # The facade's caller wrote this filter; on the source it is user input, so
  # the source's field policies may redact it.
  defp caller_input(filter) do
    Ash.Filter.map(filter, fn
      %Ash.Query.Ref{} = ref -> %{ref | input?: true}
      other -> other
    end)
  end

  # A rename sorts by the source column; any other lens sorts by its forward
  # expression, which cannot go into `Ash.Query.sort` directly — it becomes an
  # expression calculation, typed as the facade attribute it computes, and the
  # sort carries the calculation struct (a name alone would look it up in the
  # source's own fields).
  defp apply_sort(query, sorted, facade) do
    Enum.reduce(sorted, query, fn
      {{_attribute, _direction}, {column, direction}}, query when is_atom(column) ->
        Ash.Query.sort(query, [{column, direction}])

      {{attribute, _direction}, {expression, direction}}, query ->
        facade_attribute = Ash.Resource.Info.attribute(facade, attribute)

        case Ash.Query.Calculation.new(
               :"facade_sort_#{attribute}",
               Ash.Resource.Calculation.Expression,
               [expr: expression],
               facade_attribute.type,
               facade_attribute.constraints
             ) do
          {:ok, calculation} ->
            Ash.Query.sort(query, [{calculation, direction}])

          {:error, error} ->
            Ash.Query.add_error(query, :sort, error)
        end
    end)
  end

  defp apply_window(query, facade_query) do
    query =
      if facade_query.limit do
        Ash.Query.limit(query, facade_query.limit)
      else
        query
      end

    if facade_query.offset && facade_query.offset != 0 do
      Ash.Query.offset(query, facade_query.offset)
    else
      query
    end
  end

  # Attributes come with the read; a calculation or aggregate a lens reads has
  # to be asked for, or the source row has no value to put through the lens.
  defp load_read_fields(query, lenses, source) do
    Enum.reduce(Record.load_fields(lenses, source), query, &Ash.Query.load(&2, &1))
  end

  defp maybe_as_of(query, source, as_of) do
    if as_of && Info.temporal?(source) do
      Ash.Query.as_of(query, as_of)
    else
      query
    end
  end

  # A read's sort asks for an order over values; a column the caller may not
  # read is an order they may not have. Only the fields the sorted lenses read
  # are in question, and only when the caller asked to be authorized at all:
  # with `authorize? false` the source hides nothing.
  defp readable_sort!(_facade, _source, _lenses, sort, _context) when sort in [nil, []], do: :ok

  defp readable_sort!(facade, source, lenses, sort, context) do
    authorize? = context[:authorize?]
    sorted_attributes = Enum.map(sort, &elem(&1, 0))

    fields =
      lenses
      |> Map.take(sorted_attributes)
      |> Map.values()
      |> Info.source_attributes()
      |> Enum.to_list()

    cond do
      !authorize? ->
        :ok

      fields == [] ->
        :ok

      Ash.can_see_fields?({source, Info.read_action(facade)}, context[:actor], fields) ->
        :ok

      true ->
        {:error, forbidden_sorted_field(facade, source, lenses, sorted_attributes, context)}
    end
  end

  defp forbidden_sorted_field(facade, source, lenses, sorted_attributes, context) do
    hidden =
      sorted_attributes
      |> Enum.map(fn attribute ->
        {attribute,
         lenses
         |> Map.fetch!(attribute)
         |> then(&[&1])
         |> Info.source_attributes()
         |> Enum.to_list()}
      end)
      |> Enum.find_value(fn {attribute, fields} ->
        if fields != [] and
             !Ash.can_see_fields?(
               {source, Info.read_action(facade)},
               context[:actor],
               fields
             ) do
          attribute
        end
      end)

    ForbiddenField.exception(resource: facade, field: hidden || hd(sorted_attributes))
  end
end
