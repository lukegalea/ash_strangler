# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyDerivedWritability do
  @moduledoc """
  `read_only?` and `because:` must agree with each other and with what the grammar
  can actually prove.

  ## What this replaces, and why the old check was not one

  `VerifyWritableMappingsReversible` checked that a computed writable mapping
  supplied `to:` and `into:`. It never related them to `from:`. So this compiled:

      map :state_code do
        from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
        to   "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END"
        into "state"
      end

  — and it shipped, in this package's own fixtures, silently rewriting three of five
  lifecycle states on an `UPDATE` that assigned only an email. A check that two
  strings are *present* is not a check that they are inverses.

  There is no `to:`/`into:` to check any more. The reverse is **constructed** from
  the combinator by `AshStrangler.Lens`, so the only things left to verify are the
  two ways the author's prose can disagree with it.

  ## The three rules

  **A mapping with no constructible reverse must say so.** This is the rule the old
  check was reaching for and missed. A free-form `expr(...)` that is not a simple
  reference has no reverse — the grammar does not attempt to invert an arbitrary
  expression, because every result in reversible computing says invertibility has to
  be guaranteed by construction rather than recovered by analysis. So such a mapping
  must carry `read_only?: true` and a `because:`, and the alternative offered is a
  combinator, not a hand-written inverse.

  **`read_only? true` requires `because:`.** That text is quoted verbatim in the
  runtime trigger error, which is the reason it was ever mandatory: "not writable"
  tells the person nothing, and "Password changes must not be written back into a
  SHA1 scheme — cut over first" tells them what to do.

  **`because:` without `read_only? true` is refused.** Prose asserting a limitation
  the mapping does not have is exactly the drift this design exists to remove, and
  it is the direction the drift actually took in 0.1 — a mapping claiming "not
  decomposable" about something perfectly decomposable, with nothing objecting.

  ## What is deliberately *not* refused

  `read_only? true` on a mapping whose reverse the grammar could have built. That
  is a legitimate policy decision rather than a factual claim — "do not write
  password hashes back into the old scheme" is about the migration, not about
  invertibility — so refusing it would refuse correct mappings.

  Instead the fact is **computed and reported next to the prose**:
  `mix ash_strangler.check` prints `reverse available but declined` for exactly
  these mappings, and `AshStrangler.Lineage` draws them as `MASKED` rather than as
  opaque. That is the anti-drift mechanism — the claim and the derived fact sit
  side by side where they can be compared — and it is stronger than a refusal that
  would have to guess at intent.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Info, Lens}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if Info.strangled?(dsl) do
      source = Info.source(dsl)

      dsl
      |> Info.mappings()
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case check(entry, Lens.of(entry, source, dsl)) do
          :ok -> {:cont, :ok}
          {:error, message} -> {:halt, {:error, error(dsl, entry, message)}}
        end
      end)
    else
      :ok
    end
  end

  defp check(%AshStrangler.Unmapped{}, _lens), do: :ok
  defp check(%AshStrangler.Constant{}, _lens), do: :ok

  defp check(entry, lens) do
    read_only? = Map.get(entry, :read_only?, false)
    because = Map.get(entry, :because)
    given? = is_binary(because) and String.trim(because) != ""

    cond do
      not read_only? and lens.invertible == :no ->
        {:error, no_reverse_message(lens)}

      read_only? and not given? ->
        {:error,
         """
         it is `read_only?: true` but gives no `because:`.

         That text is not documentation -- it is quoted verbatim in the runtime
         error raised when something tries to write the attribute, so it has to
         exist before the write path does.
         """}

      given? and not read_only? ->
        {:error,
         """
         it gives a `because:` but is not `read_only?: true`.

         `because:` explains an absent write direction. This mapping has one --
         #{inspect(entry.__struct__ |> Module.split() |> List.last())} carries its own
         reverse -- so the prose is asserting a limitation the mapping does not
         have. That is the drift this verifier exists to refuse: in 0.1 a mapping
         could say "not decomposable" about something perfectly decomposable and
         nothing objected.

         Either drop the `because:`, or add `read_only?: true` if the write really
         should not happen.
         """}

      true ->
        :ok
    end
  end

  defp no_reverse_message(lens) do
    """
    it has no constructible reverse, and does not say so.

    `from:` is #{if lens.opaque?, do: "a `fragment(...)`", else: "an expression that is not a simple column reference"},
    and the grammar does not attempt to invert an arbitrary expression -- every
    result in reversible computing says invertibility has to be guaranteed by
    construction rather than recovered by analysis, which is why there is no `to:`
    slot to fill in.

    Two ways forward.

    If the transform *is* invertible, say which combinator it is, and both
    directions come from that one declaration:

        decode #{inspect(lens.attribute)}, from: :legacy_column, values: %{"a" => 1, "b" => 2}
        negate #{inspect(lens.attribute)}, from: :legacy_column
        affine #{inspect(lens.attribute)}, from: :legacy_column, multiply: 100
        coalesce #{inspect(lens.attribute)}, from: :legacy_column, default: 0
        concat #{inspect(lens.attribute)}, from: [:first_name, :last_name], separator: " "
        collapse #{inspect(lens.attribute)} do ... end

    If it genuinely is not, declare that, with a reason the person attempting the
    write will read:

        read_only?: true,
        because: "..."
    """
  end

  defp error(dsl, entry, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :map, entry.attribute],
      message: """
      Mapping for #{inspect(entry.attribute)}: #{String.trim(message)}

      Writability is derived here, not declared. `AshStrangler.Lens` classifies this
      mapping as #{describe(dsl, entry)}.
      """
    )
  end

  defp describe(dsl, entry) do
    source = Info.source(dsl)
    lens = Lens.of(entry, source, dsl)
    {type, invertible: invertible} = Lens.classify(lens)

    "`#{lens.combinator}` — #{type}, invertible: #{invertible}"
  rescue
    _ -> "a mapping whose classification could not be computed"
  end
end
