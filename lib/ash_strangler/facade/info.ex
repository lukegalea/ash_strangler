# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.Info do
  @moduledoc """
  Introspection of an `AshStrangler.Facade`. Works on a compiled module or a
  `Spark.Dsl` state, so the transformers and the verifiers can use it the way
  `AshStrangler.Info` does.

  Runtime readers — the manual read, the write implementation, a hop chain —
  take the compiled module. Compile-time readers take `dsl`, where the source
  may not be a compiled module yet; `lenses/1` is the one function that needs
  the source compiled, because a lens is built against the source's fields.
  """

  alias AshStrangler.{
    Facade.Defer,
    Facade.Hide,
    Facade.Hop,
    Facade.WriteSpec,
    Lens,
    Lineage,
    MappingVersion
  }

  @spec source(module() | Spark.Dsl.t()) :: Ash.Resource.t() | nil
  def source(resource_or_dsl),
    do: Spark.Dsl.Extension.get_opt(resource_or_dsl, [:facade], :source, nil)

  @spec read_action(module() | Spark.Dsl.t()) :: atom()
  def read_action(resource_or_dsl),
    do: Spark.Dsl.Extension.get_opt(resource_or_dsl, [:facade], :read_action, :read)

  # The mapping entries, in declaration order: the nine entity structs the
  # facade's DSL shares with `AshStrangler.Dsl`.
  @mapping_structs [
    AshStrangler.Map,
    AshStrangler.Decode,
    AshStrangler.Collapse,
    AshStrangler.Coalesce,
    AshStrangler.Concat,
    AshStrangler.Negate,
    AshStrangler.Affine,
    AshStrangler.Constant,
    AshStrangler.Unmapped
  ]

  @doc "Every mapping entry in the facade section, in declaration order."
  @spec entries(module() | Spark.Dsl.t()) :: [struct()]
  def entries(resource_or_dsl),
    do: Enum.filter(facade_entities(resource_or_dsl), &struct_of?(&1, @mapping_structs))

  @doc "Every `write`, in declaration order."
  @spec writes(module() | Spark.Dsl.t()) :: [WriteSpec.t()]
  def writes(resource_or_dsl), do: entities(resource_or_dsl, WriteSpec)

  @doc "Every `hide`, in declaration order."
  @spec hidden(module() | Spark.Dsl.t()) :: [Hide.t()]
  def hidden(resource_or_dsl), do: entities(resource_or_dsl, Hide)

  @doc "Every `defer`, in declaration order."
  @spec deferred(module() | Spark.Dsl.t()) :: [Defer.t()]
  def deferred(resource_or_dsl), do: entities(resource_or_dsl, Defer)

  @doc """
  The lenses of the facade's entries over its source, keyed by the attribute
  each produces.

  Built by `AshStrangler.Lens.over/3` with the facade as target, so a facade
  reads the same lens a view does. Raises `ArgumentError` when an entry reads
  something the source does not have — `VerifySource` turns that into a
  `Spark.Error.DslError` at compile time.
  """
  @spec lenses(module() | Spark.Dsl.t()) :: %{atom() => Lens.t()}
  def lenses(resource_or_dsl) do
    Lens.over(source(resource_or_dsl), resource_or_dsl, entries(resource_or_dsl))
  end

  defp entities(resource_or_dsl, type) do
    resource_or_dsl
    |> Spark.Dsl.Extension.get_entities([:facade])
    |> Enum.filter(&is_struct(&1, type))
  end

  defp struct_of?(value, types) when is_struct(value), do: value.__struct__ in types
  defp struct_of?(_, _), do: false

  defp facade_entities(resource_or_dsl),
    do: Spark.Dsl.Extension.get_entities(resource_or_dsl, [:facade])

  @doc """
  The estate of the source's attributes: what happened to each of them.

  * `exposed` — some lens reads it;
  * `hidden` — `hide ... because:` named it;
  * `deferred` — `defer` named it;
  * `unplaced` — none of the above, which `VerifyEstate` refuses.

  Every attribute of the source is in exactly one list. A source attribute
  that no facade mentions is not a detail: reads would silently not answer it,
  which is the failure the estate check exists to make impossible.
  """
  @spec estate(module() | Spark.Dsl.t()) :: %{
          exposed: [atom()],
          hidden: [atom()],
          deferred: [atom()],
          unplaced: [atom()]
        }
  def estate(resource_or_dsl) do
    source = source(resource_or_dsl)

    read =
      resource_or_dsl
      |> lenses()
      |> Map.values()
      |> source_attributes()

    hidden_names = Enum.map(hidden(resource_or_dsl), & &1.attribute)
    deferred_names = Enum.map(deferred(resource_or_dsl), & &1.attribute)

    source_attributes =
      source
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    %{
      exposed: Enum.filter(source_attributes, &(&1 in read)),
      hidden: hidden_names,
      deferred: deferred_names,
      unplaced:
        Enum.reject(
          source_attributes,
          &(&1 in read or &1 in hidden_names or &1 in deferred_names)
        )
    }
  end

  @doc """
  The SHA-256 over the facade's whole declaration: the canonical lens entries,
  plus the source, the read action and the writes.

  Computed the way `AshStrangler.MappingVersion.hash/1` is, with the shared
  canonical helper, so a facade hop's version is comparable with a strangled
  hop's. Collections with no semantic order are sorted; the mapping entries
  keep declaration order where order is meaning (a collapse's clauses).
  """
  @spec mapping_version(module() | Spark.Dsl.t()) :: String.t()
  def mapping_version(resource_or_dsl) do
    writes =
      resource_or_dsl
      |> writes()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(fn write ->
        {write.name, write.via, Enum.sort(write.sets), Enum.sort(write.accepts)}
      end)

    canonical =
      {
        source(resource_or_dsl),
        read_action(resource_or_dsl),
        entries(resource_or_dsl)
        |> Enum.sort_by(&mapping_sort_key/1)
        |> Enum.map(&MappingVersion.canonical_entity/1),
        writes
      }

    MappingVersion.hash_term(canonical)
  end

  @doc """
  The versions of every hop in `hops/1`, in hop order.

  One entry per hop down the chain: the facade's own first, then its source's,
  and so on. A consumer walking the chain can tell "the row changed" from "the
  meaning of the row changed" at every step, not only at the top.
  """
  @spec mapping_versions(module() | Spark.Dsl.t()) :: [String.t()]
  def mapping_versions(resource_or_dsl),
    do: Enum.map(hops(resource_or_dsl), & &1.mapping_version)

  @doc """
  The hop chain from this facade down: one `%AshStrangler.Facade.Hop{}` per hop.

  A facade hop carries the facade's mapping version and its edges; the chain
  then continues into the source. A strangled source adds a `:strangled` hop
  (`AshStrangler.MappingVersion.hash/1`, the legacy twin as its own source); an
  owned source ends the chain; a facade source adds its own `:facade` hop and
  the chain continues through it — read hop by hop.
  """
  @spec hops(module() | Spark.Dsl.t()) :: [Hop.t()]
  def hops(resource_or_dsl), do: Hop.chain(resource_or_dsl)

  # Matched as atoms rather than module references: ash_events is an optional
  # dependency, and matching a name is not a dependency on the module.
  @replay_wrapper :"Elixir.AshEvents.Events.ReplayChangeWrapper"
  @set_attribute :"Elixir.Ash.Resource.Change.SetAttribute"

  @doc """
  The changes of a source action as `{module, options}` pairs, a change wrapped
  for replay (`AshEvents.Events.ReplayChangeWrapper`, when the source carries
  events) shown as the change it wraps.
  """
  @spec changes(Ash.Resource.Actions.action()) :: [{module(), keyword()}]
  def changes(action) do
    Enum.flat_map(action.changes, fn
      %{change: {@replay_wrapper, opts}} when is_list(opts) -> List.wrap(opts[:change])
      %{change: change} -> [change]
      _ -> []
    end)
  end

  @doc """
  What a source action sets to a fixed value or copies from an argument, as
  `{attribute, value}` pairs: its `set_attribute` changes. A copied argument is
  the value `{:_arg, name}`.
  """
  @spec set_attributes(Ash.Resource.Actions.action()) :: [{atom(), term()}]
  def set_attributes(action) do
    for {@set_attribute, opts} <- changes(action),
        is_list(opts) and is_atom(opts[:attribute]) and Keyword.has_key?(opts, :value) do
      {opts[:attribute], opts[:value]}
    end
  end

  @doc """
  The argument a source action copies into `column` with
  `set_attribute(column, arg(name))`, or `nil`. A facade `accepts:` attribute
  whose column the action takes this way is written through that argument.
  """
  @spec argument_for(Ash.Resource.Actions.action(), atom()) :: atom() | nil
  def argument_for(action, column) do
    Enum.find_value(set_attributes(action), fn
      {^column, {:_arg, name}} -> name
      _ -> nil
    end)
  end

  @doc "The source attributes every lens of `lenses` reads, at the top level."
  @spec source_attributes([Lens.t()]) :: MapSet.t(atom())
  def source_attributes(lenses) do
    lenses
    |> Enum.flat_map(& &1.sources)
    |> Enum.filter(&match?({[], _}, &1))
    |> MapSet.new(&elem(&1, 1))
  end

  @doc "The lineage edges one hop contributes for `lenses`, between its own nodes."
  @spec hop_edges(Ash.Resource.t(), Ash.Resource.t(), [Lens.t()]) :: [Lineage.Edge.t()]
  def hop_edges(resource, source, lenses) do
    Enum.flat_map(lenses, fn lens ->
      lens.sources
      |> Enum.filter(&match?({[], _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.map(fn column ->
        Lineage.edge(lens, column_node(source, column), attribute_node(resource, lens.attribute))
      end)
    end)
  end

  defp column_node(source, column) do
    %Lineage.Node{
      id: "s_#{Lineage.slug(source)}__#{Lineage.sanitize(column)}",
      side: :legacy,
      relation: inspect(source),
      column: to_string(column),
      label: to_string(column)
    }
  end

  defp attribute_node(resource, attribute) do
    %Lineage.Node{
      id: "f_#{Lineage.slug(resource)}__#{Lineage.sanitize(attribute)}",
      side: :new,
      relation: inspect(resource),
      column: to_string(attribute),
      label: to_string(attribute)
    }
  end

  defp mapping_sort_key(%{attribute: attribute}) when not is_nil(attribute), do: attribute
  defp mapping_sort_key(%{attributes: [first | _]}), do: first
  defp mapping_sort_key(_entry), do: nil
end
