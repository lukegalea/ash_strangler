# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Mapping do
  @moduledoc """
  Declares a strangler mapping **outside** the resource it maps.

  The mapping body is the identical `strangler do ... end` grammar — there is no
  second grammar, and nothing is kept in sync by hand. What this module adds is
  the wiring: the mapping lives in its own module as a `Spark.Dsl.Fragment`,
  and the resource attaches it with `fragments:`.

      defmodule VendorpmKeystone.Legacy.ContractMapping do
        use AshStrangler.Mapping, resource: VendorpmKeystone.Clm.Contract

        strangler do
          phase :dual_write

          source VendorpmKeystone.Legacy.ClmContracts do
            key :id, from: :id, strategy: :identity
            map :name, from: :name
          end
        end
      end

      defmodule VendorpmKeystone.Clm.Contract do
        use Ash.Resource,
          data_layer: AshPostgres.DataLayer,
          fragments: [VendorpmKeystone.Legacy.ContractMapping]
      end

  The fragment carries the extension (`AshStrangler.Resource`) with it, so a
  resource whose entire mapping is external needs no `extensions:` and no
  `strangler` block at all — which is the point. The resource file says what the
  resource *is*; the mapping module says how it strangles.

  Spark merges a fragment's sections into the parent's DSL config before any
  transformer or verifier runs, so an attached mapping is indistinguishable in
  kind from an inline one — same verifiers, same obligations, same generated
  SQL. `AshStrangler.Verifiers.VerifySingleSource` enforces that this stays to
  ONE mapping per resource, however many places it was declared in.

  ## Target declaration, and where it is checked

  `resource:` names the resource the mapping is written for, exposed as
  `target/0`. Spark persists which extensions a fragment carries but **not**
  which fragments a parent attached, so a parent-side verifier cannot see the
  fragment module to compare its target against. The check therefore lives where
  both halves are reachable — `mix ash_strangler.check`, via `verify_target/1`.
  It correlates the mapping module with the mapping's own declaration site
  (`__spark_metadata__`), so it is exact whenever the mapping module is compiled
  from the same file its `strangler` block was written in, which is the shape
  this DSL creates. A resource whose fragment lives in the same file as itself
  is skipped: the correlation cannot distinguish it from an inline mapping, and
  inventing a weaker signal to guess with would be exactly the failure mode
  `what-it-refuses.md` is about.
  """

  defmacro __using__(opts) do
    target = Keyword.fetch!(opts, :resource)

    quote do
      use Spark.Dsl.Fragment, of: Ash.Resource, extensions: [AshStrangler.Resource]

      @ash_strangler_mapping_target unquote(target)

      @doc false
      def target, do: @ash_strangler_mapping_target
    end
  end

  alias AshStrangler.Info

  @doc """
  `:ok` when every external mapping attached to `resource` declares it as its
  target, `{:error, message}` when one does not.

  This is the `mix ash_strangler.check` side of the target declaration — see the
  moduledoc for why it cannot be a Spark verifier. The message names the
  mapping, its declared target and the resource that attached it:

      mapping X declares target Y but is attached to Z
  """
  @spec verify_target(Ash.Resource.t()) :: :ok | {:error, String.t()}
  def verify_target(resource) do
    resource
    |> attached_mapping()
    |> case do
      :inline ->
        :ok

      :ambiguous ->
        :ok

      nil ->
        :ok

      mapping ->
        declared = mapping.target()

        if declared == resource do
          :ok
        else
          {:error,
           "mapping #{inspect(mapping)} declares target #{inspect(declared)} but is attached to #{inspect(resource)}"}
        end
    end
  end

  # The mapping fragment whose `strangler` block produced this resource's source
  # entity, found by correlating the entity's declaration site with the files
  # mapping fragments were compiled from.
  #
  # `:inline` — the source was declared in the resource's own file: either an
  # inline mapping, or a fragment that shares the resource's file. Both are out
  # of this check's reach, for the reason the moduledoc gives.
  # `:ambiguous` — several mapping fragments were compiled from that one file;
  # nothing here can say which one is attached, and guessing is refused.
  # `nil` — no mapping fragment was compiled from the entity's file, or the
  # metadata needed to correlate is absent.
  defp attached_mapping(resource) do
    case Info.source(resource) do
      nil ->
        nil

      source ->
        entity_file = declaration_file(source)
        resource_file = resource_file(resource)

        cond do
          is_nil(entity_file) -> nil
          entity_file == resource_file -> :inline
          true -> candidate(entity_file)
        end
    end
  end

  defp candidate(entity_file) do
    entity_file
    |> mapping_fragments()
    |> case do
      [mapping] -> mapping
      _ -> :ambiguous
    end
  end

  defp declaration_file(source) do
    case source.__spark_metadata__ do
      %{anno: anno} when is_list(anno) or is_map(anno) ->
        file = if is_list(anno), do: Keyword.get(anno, :file), else: Map.get(anno, :file)

        case file do
          nil -> nil
          file -> file |> IO.iodata_to_binary() |> Path.basename()
        end

      _ ->
        nil
    end
  end

  defp resource_file(resource) do
    resource.module_info(:compile)[:source] |> IO.iodata_to_binary() |> Path.basename()
  end

  # Every loaded module that `use AshStrangler.Mapping` compiled into a mapping
  # fragment. Three facts identify one, and all three are load-bearing: it
  # declares `target/0` (the macro put it there), it is a fragment *of a
  # resource* (`spark_fragment_of` is persisted by Spark for exactly this kind
  # of question), and its compile source is the file being matched.
  defp mapping_fragments(file) do
    for {module, _} <- :code.all_loaded(),
        function_exported?(module, :target, 0),
        fragment_of_resource?(module),
        compiled_from?(module, file) do
      module
    end
  end

  defp fragment_of_resource?(module) do
    module.__info__(:attributes)
    |> Keyword.get(:spark_fragment_of, [])
    |> Enum.any?(&(&1 == Ash.Resource))
  rescue
    _ -> false
  end

  defp compiled_from?(module, file) do
    case module.module_info(:compile)[:source] do
      nil -> false
      source -> IO.iodata_to_binary(source) |> Path.basename() == file
    end
  end
end
