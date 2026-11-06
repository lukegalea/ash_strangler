# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyReferences do
  @moduledoc """
  V-REF: a `reference` names a real kind, reads integer columns that fit it,
  and either is closed by the snapshot or says why not.

  A reference attribute equals the id of the row it points at by construction:
  both are the same packing of the same integers. What construction cannot
  show is that such a row exists. The snapshot can, and **closure** is proven
  when, in the twin's catalog,

    * `from` is the kind's own columns on the kind's own relation, or
    * a **validated** foreign key on the twin's relation maps `from`, column for
      column, onto the kind's columns.

  Compilation fails when:

    * the registry or kind does not exist, or the arity differs;
    * a `from` column is not on the twin, or (pinned) is not an integer no wider
      than its part;
    * closure is proven and `soft:` is declared anyway (the prose would drift
      from the fact), or closure is not proven and `soft:` is absent.

  An unpinned twin cannot prove closure, so its references must be `soft:`.
  Every soft reference becomes a dangling-row count in
  `mix ash_strangler.check` (`AshStrangler.Obligations`).
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.{Info, KeyKind, Reference}
  alias AshStrangler.Verifiers.KeyCatalog
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case Info.source(dsl) do
      nil ->
        :ok

      source ->
        source.mappings
        |> Enum.filter(&match?(%Reference{}, &1))
        |> Enum.find_value(:ok, fn reference ->
          case problems(source.twin, reference) do
            [] -> nil
            problems -> {:error, error(dsl, reference, problems)}
          end
        end)
    end
  end

  defp problems(twin, %Reference{kind: {registry, name}} = reference) do
    with {:ok, kind} <- KeyCatalog.kind(registry, name),
         [] <- arity_problems(reference, kind),
         {:ok, columns} <- columns(twin, reference) do
      case KeyCatalog.relation(twin) do
        {:ok, _catalog, relation} ->
          KeyCatalog.width_problems(relation, columns, kind, false) ++
            closure_problems(
              reference,
              KeyCatalog.closed?(KeyCatalog.relation_name(twin), relation, columns, kind),
              kind
            )

        :unpinned ->
          closure_problems(reference, :unpinned, kind)

        {:error, message} ->
          [message]
      end
    else
      {:error, message} -> [message]
      problems when is_list(problems) -> problems
    end
  end

  defp arity_problems(reference, kind) do
    if length(Reference.columns(reference)) == length(kind.parts) do
      []
    else
      [
        "`from` names #{length(Reference.columns(reference))} column(s); kind " <>
          "#{inspect(kind.name)} packs #{length(kind.parts)}"
      ]
    end
  end

  defp columns(twin, reference) do
    case KeyCatalog.columns(twin, Reference.columns(reference)) do
      {:ok, columns} ->
        if Enum.all?(Reference.columns(reference), &integer?(twin, &1)) do
          {:ok, columns}
        else
          {:error, "every `from` column must be an integer attribute of #{inspect(twin)}"}
        end

      {:error, attribute} ->
        {:error, "#{inspect(twin)} has no attribute #{inspect(attribute)}"}
    end
  end

  defp integer?(twin, attribute),
    do: Ash.Resource.Info.attribute(twin, attribute).type == Ash.Type.Integer

  defp closure_problems(%Reference{soft: nil}, true, _kind), do: []
  defp closure_problems(%Reference{soft: soft}, false, _kind) when is_binary(soft), do: []
  defp closure_problems(%Reference{soft: soft}, :unpinned, _kind) when is_binary(soft), do: []

  defp closure_problems(%Reference{}, true, kind) do
    [
      "`soft:` is declared, but a validated foreign key in the snapshot already closes this " <>
        "reference onto #{format_home(kind)}. Delete `soft:`"
    ]
  end

  defp closure_problems(%Reference{}, false, kind) do
    [
      "no validated foreign key in the snapshot maps `from` onto #{format_home(kind)}, so a " <>
        "row may name a #{inspect(kind.name)} that does not exist. Declare why with " <>
        "`soft: \"...\"`, and `mix ash_strangler.check` will count the dangling rows"
    ]
  end

  defp closure_problems(%Reference{}, :unpinned, kind) do
    [
      "the twin is not pinned to a snapshot, so closure onto #{format_home(kind)} cannot be " <>
        "proven. Pin the twin (`twin do snapshot \"…\" end`) or declare `soft: \"...\"`"
    ]
  end

  defp format_home(kind),
    do: Enum.map_join(KeyKind.columns(kind), ", ", fn {rel, col} -> "`#{rel}.#{col}`" end)

  defp error(dsl, reference, problems) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :reference, reference.attribute],
      message: """
      `reference #{inspect(reference.attribute)}, kind: #{inspect(reference.kind)}, \
      from: #{inspect(reference.from)}` does not hold:

      #{Enum.map_join(problems, "\n", &"  * #{&1}")}
      """
    )
  end
end
