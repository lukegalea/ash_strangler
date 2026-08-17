# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyNotRedundant do
  @moduledoc """
  A declared transform that is the identity is refused.

  This is pgroll's `ColumnMigrationRedundantError`, and it is the **direct
  anti-restatement check** — the one obligation aimed at the defect the whole
  redesign is about rather than at data loss.

  A redundant transform is not harmless. It is a claim that something happens,
  written where a reader will believe it, and it costs a real mechanism:
  `AshStrangler.Mechanism` classifies a `decode` as `:base_trigger` rather than
  `:plain`, which is the difference between a resource that keeps upserts and one
  that does not. So an identity `decode` buys a trigger and changes nothing.

  Four shapes are caught, each with a stated reason:

  | Shape | Why it is the identity |
  |---|---|
  | `decode` whose value table maps every key to itself | the table *is* `fn x -> x end` |
  | `affine` with `multiply: 1, add: 0` | `1 * x + 0` |
  | `concat` over a single column | there is nothing to join it to |
  | `map` with `zone:` on a column that is already `timestamptz` | `AT TIME ZONE` on an aware value converts it to a naive one, which is the opposite of the intent |

  The last one is the valuable one, and it is not merely redundant — it is *wrong*.
  `AT TIME ZONE 'UTC'` applied to a `timestamptz` yields a `timestamp without time
  zone`, so a mapping that added `zone:` to an already-aware column would silently
  strip the zone it was trying to establish.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Affine, Concat, Decode, Info}
  alias AshStrangler.Map, as: MapEntry
  alias Spark.Dsl.Verifier

  @aware_types [Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec]

  @impl true
  def verify(dsl) do
    if Info.strangled?(dsl) do
      twin = Info.twin(dsl)

      dsl
      |> Info.mappings()
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case check(entry, twin) do
          :ok -> {:cont, :ok}
          {:error, message} -> {:halt, {:error, error(dsl, entry, message)}}
        end
      end)
    else
      :ok
    end
  end

  defp check(%Decode{values: values}, _twin) do
    if map_size(values) > 0 and Enum.all?(values, fn {legacy, modern} -> legacy == modern end) do
      {:error,
       """
       every entry in its `values:` table maps a value to itself, so the decode is
       the identity function written out longhand.

       It is not free: `AshStrangler.Mechanism` classifies a `decode` as
       `:base_trigger` rather than `:plain`, which is the difference between a
       resource that keeps upserts and one that does not. Use a plain rename:

           map :attribute, from: :legacy_column
       """}
    else
      :ok
    end
  end

  defp check(%Affine{multiply: 1, add: 0}, _twin) do
    {:error,
     """
     `multiply: 1, add: 0` is `1 * x + 0`, which is `x`.

     Use a plain rename:

         map :attribute, from: :legacy_column
     """}
  end

  defp check(%Concat{from: [_single]}, _twin) do
    {:error,
     """
     it concatenates one column, which joins it to nothing.

     A `concat` also costs invertibility: its reverse is `split_part`, which is only
     correct while the separator is provably absent from every operand — a condition
     `mix ash_strangler.check` has to measure against real data. Paying that for a
     single column buys nothing. Use a plain rename:

         map :attribute, from: :legacy_column
     """}
  end

  defp check(%MapEntry{from: column, zone: zone}, twin)
       when is_atom(column) and is_binary(zone) and not is_nil(column) do
    case Ash.Resource.Info.attribute(twin, column) do
      %{type: type} when type in @aware_types ->
        {:error,
         """
         `zone: #{inspect(zone)}` is applied to #{inspect(column)}, which the twin
         already declares as an aware timestamp (#{inspect(type)}).

         This is worse than redundant. `AT TIME ZONE` on a `timestamptz` yields a
         `timestamp WITHOUT time zone` — it converts an aware value back to a naive
         one, which is the opposite of what `zone:` is for. The mapping would strip
         the zone it was trying to establish.

         Drop the `zone:`. It exists for a naive legacy `timestamp` column, where the
         zone is a fact about the old application that cannot be inferred.
         """}

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp check(_entry, _twin), do: :ok

  defp error(dsl, entry, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, entry_name(entry), entry.attribute],
      message: """
      The mapping for #{inspect(entry.attribute)} declares a transform that is not one: \
      #{String.trim(message)}
      """
    )
  end

  defp entry_name(entry),
    do:
      entry.__struct__ |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
end
