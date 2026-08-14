# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyWritableMappingsReversible do
  @moduledoc """
  A writable mapping must be reversible, and a non-writable one must say why.

  A mapping computed with `from:` has no automatic inverse — Postgres cannot
  work out that `coalesce(first,'') || ' ' || coalesce(last,'')` splits back into
  two columns, and neither can this extension. So a computed mapping either
  supplies `to: ... into:` or declares itself unwritable.

  `because:` is required rather than encouraged because that text is
  **user-facing**: it appears in the runtime error raised when something attempts
  the write. "not writable" tells the person nothing; "Password changes must not
  be written back into a SHA1 scheme — cut over first" tells them what to do.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    AshStrangler.Info.mappings(dsl)
    |> Enum.reduce_while(:ok, fn mapping, :ok ->
      case check(mapping) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, error(dsl, mapping, message)}}
      end
    end)
  end

  # A plain column mapping is bidirectional by construction.
  defp check(%{column: column, from: nil}) when is_binary(column), do: :ok

  # Computed and writable: needs an explicit inverse and a target column.
  defp check(%{writable?: true, from: from, to: to, into: into}) when is_binary(from) do
    cond do
      is_nil(to) ->
        {:error,
         "it is computed with `from:` and marked writable, but supplies no `to:` expression"}

      is_nil(into) ->
        {:error, "it supplies `to:` but no `into:`, so there is no column to write"}

      true ->
        :ok
    end
  end

  # Not writable: must explain itself.
  defp check(%{writable?: false, because: because}) do
    if is_binary(because) and String.trim(because) != "" do
      :ok
    else
      {:error, "it is `writable? false` but gives no `because:`"}
    end
  end

  defp check(_), do: :ok

  defp error(dsl, mapping, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :map, mapping.attribute],
      message: """
      Mapping for #{inspect(mapping.attribute)} is not reversible: #{message}.

      Either give it an inverse:

          map #{inspect(mapping.attribute)} do
            from #{inspect(mapping.from || mapping.column)}
            to   "..." , into: "legacy_column"
          end

      or declare it read-only, with a reason that will be shown to whoever tries
      to write it:

          map #{inspect(mapping.attribute)} do
            from #{inspect(mapping.from || mapping.column)}
            writable? false
            because "..."
          end
      """
    )
  end
end
