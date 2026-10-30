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
  `target/0`. Spark merges fragment sections before verifiers run but does not
  persist the parent's `fragments:` list. `ResolveMappingTarget` therefore
  matches the merged source entity's Spark declaration site (file + location)
  against the fragment's own source entity and persists the target onto the
  source. `mix ash_strangler.check` compares it with the attaching resource via
  `verify_target/1`.

  The declaration-site match is exact even when the resource and fragment
  modules share a file (the Contract fixture shape). An unresolved site is
  reported by the check; it is never silently skipped.
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
    case Info.source(resource) do
      nil ->
        :ok

      %{mapping_target_unverifiable?: true} ->
        {:error,
         "mapping target for #{inspect(resource)} could not be resolved from the attached fragment's Spark declaration site"}

      %{mapping_target: nil} ->
        # Inline mapping: no fragment target exists to compare.
        :ok

      %{mapping_target: target, mapping_module: mapping} ->
        if target == resource do
          :ok
        else
          {:error,
           "mapping #{inspect(mapping)} declares target #{inspect(target)} but is attached to #{inspect(resource)}"}
        end
    end
  end
end
