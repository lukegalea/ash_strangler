# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# `ash_provenance` is optional: a package that never asks where a value came
# from is not made to install the contract.
with {:module, AshProvenance.Address} <- Code.ensure_compiled(AshProvenance.Address) do
  defmodule AshStrangler.Facade.Explain do
    @moduledoc """
    Where one facade value came from, on the `ash_provenance` contract: the
    lens that produced it, and the source value it was produced from.

    > #### Mix Dependency {: .warning}
    >
    > This module requires the optional dependency `:ash_provenance`. Without
    > it the module is not compiled at all.

    `value/3` reads nothing. It takes a facade record the caller has already
    read, as the caller, and answers from that record and the facade's
    declaration, so the caller's actor, tenant and field policies decide what
    is passed in and the explanation never widens them. Going further down —
    reading the source row and explaining *its* value — is the caller's walk:
    the answer names each source value it came from as an `antecedent`, and the
    walk asks the source's own explainer about it. A facade over a facade is two
    such hops.

    ## What it answers

    | The facade value | The answer |
    |---|---|
    | read through a lens over source attributes | one `:was_derived_from` step for each source attribute, `plan` the facade's mapping version, each source value an antecedent |
    | a constant, a key or an unmapped attribute (no source attribute) | one `:was_generated_by` step, by the facade's mapping |
    | read-only or non-invertible | the same steps, with the lens's `because:` text in the summary: the forward direction is known, so the value explains through it. This is not a gap |
    | one the caller may not read (`%Ash.ForbiddenField{}`) | an `:unreadable` gap and nothing else: no step, so no source identifier |
    | from a record that carries no source key | a `:failed` gap |

    A refused write is not an explanation: it leaves no value to explain.

    ## Options

      * `:address` - the `AshProvenance.Address` of the facade value. Required.
      * `:source_type` - the address type token of the facade's source resource.
        Required: the host's registry owns the tokens, not this package.
      * `:value` - what a step may show of the facade value (`nil`, `:masked` or
        `{:value, scalar}`). Default `nil`: no value shown.
    """

    alias AshProvenance.{Address, Gap, Plan, Step}
    alias AshStrangler.Facade.Info

    @type answer :: %{
            steps: [Step.t()],
            gaps: [Gap.t()],
            antecedents: [Address.t()]
          }

    @summary_limit 280

    @doc """
    Explains `attribute` of the facade `record`, which a facade read returned.
    """
    @spec value(Ash.Resource.record(), atom(), keyword()) :: answer()
    def value(%facade{} = record, attribute, opts) when is_atom(attribute) do
      address = Keyword.fetch!(opts, :address)
      source_type = Keyword.fetch!(opts, :source_type)
      shown = Keyword.get(opts, :value)

      case Map.fetch(Info.lenses(facade), attribute) do
        :error ->
          gaps_only(Gap.new!(kind: :failed, of: address))

        {:ok, lens} ->
          if match?(%Ash.ForbiddenField{}, Map.get(record, attribute)) do
            gaps_only(Gap.new!(kind: :unreadable, of: address))
          else
            answer(record, lens, address, source_type, shown)
          end
      end
    end

    defp answer(%facade{} = record, lens, address, source_type, shown) do
      {:ok, plan} = Plan.new(key: address.type, version: Info.mapping_version(facade))
      summary = summary(lens)

      case source_columns(lens) do
        [] ->
          generated(address, plan, summary, shown)

        columns ->
          derived(record, columns, address, source_type, plan, summary, shown)
      end
    end

    # No source attribute: nothing was read to produce this value, the facade's
    # own mapping did.
    defp generated(address, plan, summary, shown) do
      step =
        Step.new!(
          relation: :was_generated_by,
          entity: address,
          activity: Address.to_trace_ref(address),
          plan: plan,
          granularity: :value,
          value: shown,
          summary: summary
        )

      %{steps: [step], gaps: [], antecedents: []}
    end

    defp derived(%facade{} = record, columns, address, source_type, plan, summary, shown) do
      case source_id(record, Info.source(facade)) do
        {:ok, id} ->
          antecedents = Enum.map(columns, &source_address(address, source_type, id, &1))

          steps =
            Enum.map(antecedents, fn antecedent ->
              Step.new!(
                relation: :was_derived_from,
                entity: address,
                antecedent: antecedent,
                plan: plan,
                granularity: :value,
                value: shown,
                summary: summary
              )
            end)

          %{steps: steps, gaps: [], antecedents: antecedents}

        :error ->
          gaps_only(Gap.new!(kind: :failed, of: address))
      end
    end

    defp gaps_only(gap), do: %{steps: [], gaps: [gap], antecedents: []}

    # The columns a lens reads at the top level of its source, once each, in
    # the lens's order. A path through a relationship is not a column of the
    # source row and names no value here (the lineage graph draws the same).
    defp source_columns(lens) do
      lens.sources
      |> Enum.flat_map(fn
        {[], column} -> [column]
        _path -> []
      end)
      |> Enum.uniq()
    end

    defp source_address(address, source_type, id, column) do
      Address.new!(
        base: address.base,
        type: source_type,
        id: id,
        as_of: address.as_of,
        attribute: Atom.to_string(column)
      )
    end

    # The source row's primary key, as the facade read kept it (its `:source`
    # metadata), in the source's declared key order: a binary for one key, the
    # pairs of a composite key otherwise.
    defp source_id(record, source) do
      with %{} = key <- Map.get(record.__metadata__, :source),
           fields = Ash.Resource.Info.primary_key(source),
           true <- fields != [] and Enum.all?(fields, &Map.has_key?(key, &1)) do
        case fields do
          [only] -> {:ok, to_string(Map.fetch!(key, only))}
          many -> {:ok, Enum.map(many, &{Atom.to_string(&1), to_string(Map.fetch!(key, &1))})}
        end
      else
        _ -> :error
      end
    end

    # The lens's kind, and the declaration's own words where it carries any: a
    # read-only or non-invertible lens states why. Declaration text only: no
    # row, no value.
    defp summary(lens) do
      base = "through a #{lens.combinator} lens"

      case lens.because do
        because when is_binary(because) and because != "" ->
          clip(base <> ": " <> because)

        _ ->
          base
      end
    end

    defp clip(text) when byte_size(text) <= @summary_limit, do: text

    defp clip(text) do
      text
      |> String.slice(0, @summary_limit - 3)
      |> then(&(&1 <> "..."))
      |> clip_bytes()
    end

    # A multibyte character near the cut can leave the slice over the byte
    # limit; shorten until it fits.
    defp clip_bytes(text) when byte_size(text) <= @summary_limit, do: text

    defp clip_bytes(text) do
      text |> String.slice(0, String.length(text) - 4) |> then(&(&1 <> "...")) |> clip_bytes()
    end
  end
end
