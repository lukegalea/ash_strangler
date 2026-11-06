# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyKeyKinds do
  @moduledoc """
  A key-kind registry is an encoding, so it is checked like one.

  Compilation fails when:

    * the estate tag is outside `0..0xFFFF`;
    * a tag is outside `1..0xFFF`, used by two kinds, or reserved;
    * a kind name is declared twice;
    * a kind has no parts, or its widths sum to more than the 94 payload bits;
    * a part is not written `"schema.table.column"`;
    * with a `snapshot`: a part's relation or column is not in the catalog,
      the column is nullable, it is not `smallint`/`integer`/`bigint`, or it is
      wider than the width the kind packs it in.

  The last rule is why the width is declared rather than read from the
  catalog: a legacy migration that widens `integer` to `bigint` would
  otherwise re-key every row of the kind on the next capture. Declared, it
  fails here instead, naming the column, and re-keying becomes a decision.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{KeyKind, KeyKinds, UuidV8}
  alias Spark.Dsl.Verifier

  @integer_widths %{"pg_catalog.int2" => 16, "pg_catalog.int4" => 32, "pg_catalog.int8" => 64}

  @doc false
  def integer_widths, do: @integer_widths

  @impl true
  def verify(dsl) do
    kinds = KeyKinds.kinds(dsl)
    tagged = kinds ++ KeyKinds.logical_kinds(dsl)

    case catalog(dsl) do
      {:ok, catalog} ->
        problems =
          estate_problems(KeyKinds.estate(dsl)) ++
            tag_problems(tagged, KeyKinds.reserved(dsl)) ++
            Enum.flat_map(kinds, &part_problems(&1, catalog))

        report(dsl, problems)

      {:error, message} ->
        {:error, error(dsl, "  * " <> message)}
    end
  end

  defp report(_dsl, []), do: :ok

  defp report(dsl, problems),
    do: {:error, error(dsl, Enum.map_join(problems, "\n", &"  * #{&1}"))}

  defp catalog(dsl) do
    case KeyKinds.snapshot(dsl) do
      nil -> {:ok, nil}
      path -> AshStrangler.Snapshot.read_catalog(path)
    end
  end

  defp estate_problems(estate) when estate in 0..0xFFFF, do: []
  defp estate_problems(estate), do: ["estate #{inspect(estate)} is not a 16-bit tag (0..0xFFFF)"]

  defp tag_problems(kinds, reserved) do
    range =
      for kind <- kinds, kind.tag not in 1..0xFFF do
        "kind #{inspect(kind.name)}: tag #{hex(kind.tag)} is not a 12-bit tag (0x001..0xFFF)"
      end

    duplicates =
      kinds
      |> Enum.group_by(& &1.tag)
      |> Enum.filter(fn {_tag, kinds} -> length(kinds) > 1 end)
      |> Enum.map(fn {tag, kinds} ->
        "tag #{hex(tag)} is used by #{Enum.map_join(kinds, " and ", &inspect(&1.name))}; " <>
          "two kinds with one tag give one id to two rows"
      end)

    names =
      kinds
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> "kind #{inspect(name)} is declared more than once" end)

    reserved_hits =
      for kind <- kinds, kind.tag in reserved do
        "kind #{inspect(kind.name)}: tag #{hex(kind.tag)} is reserved"
      end

    range ++ duplicates ++ names ++ reserved_hits
  end

  defp part_problems(%KeyKind{} = kind, catalog) do
    widths = KeyKind.widths(kind)

    shape =
      cond do
        kind.parts == [] ->
          ["kind #{inspect(kind.name)}: no parts"]

        Enum.sum(widths) > UuidV8.payload_bits() ->
          [
            "kind #{inspect(kind.name)}: widths #{inspect(widths, charlists: :as_lists)} sum to #{Enum.sum(widths)} bits; " <>
              "a v8 payload holds #{UuidV8.payload_bits()}"
          ]

        true ->
          []
      end

    shape ++ Enum.flat_map(kind.parts, &column_problems(kind, &1, catalog))
  end

  defp column_problems(kind, {qualified, width}, catalog) do
    case {KeyKind.split_column(qualified), catalog} do
      {{nil, _}, _} ->
        ["kind #{inspect(kind.name)}: part #{inspect(qualified)} is not \"schema.table.column\""]

      {_, nil} ->
        []

      {{relation, column}, catalog} ->
        catalog_problems(kind, relation, column, width, catalog)
    end
  end

  defp catalog_problems(kind, relation, column, width, catalog) do
    label = "kind #{inspect(kind.name)}: `#{relation}.#{column}`"

    with %{} = rel <- get_in(catalog, ["relations", relation]) || {:no_relation},
         %{} = col <- Enum.find(rel["columns"], &(&1["name"] == column)) || {:no_column} do
      actual = Map.get(@integer_widths, col["udt"])

      cond do
        is_nil(actual) ->
          ["#{label} is #{col["type"]}, not smallint, integer or bigint"]

        not col["not_null"] ->
          ["#{label} is nullable; a packed key part must be NOT NULL"]

        actual > width ->
          [
            "#{label} is #{col["type"]} (#{actual} bits) but the kind packs it in #{width}; " <>
              "widening a part re-keys every row of the kind, so it is a new kind, not an edit"
          ]

        true ->
          []
      end
    else
      {:no_relation} -> ["#{label}: the snapshot catalog has no relation `#{relation}`"]
      {:no_column} -> ["#{label}: the snapshot catalog has no such column"]
    end
  end

  defp hex(tag) when is_integer(tag),
    do: "0x" <> String.pad_leading(Integer.to_string(tag, 16), 3, "0")

  defp hex(tag), do: inspect(tag)

  defp error(dsl, problems) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:key_kinds],
      message: """
      The key-kind registry is not a valid encoding:

      #{problems}

      Tags and widths are the encoding of every id of a kind. Fix the
      declaration rather than the data, and never reuse a tag.
      """
    )
  end
end
