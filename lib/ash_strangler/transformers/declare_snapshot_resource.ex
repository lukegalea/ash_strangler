# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Transformers.DeclareSnapshotResource do
  @moduledoc """
  Makes a twin's snapshot catalog an `@external_resource` of the twin.

  Without it, editing `catalog.json` recompiles nothing, so
  `AshStrangler.Verifiers.VerifySnapshot` would keep passing against the
  catalog it last read: a compile-time check that only runs when somebody
  happens to touch the twin is not a check.
  """

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    case AshStrangler.Twin.snapshot(dsl) do
      nil ->
        {:ok, dsl}

      path ->
        {:ok, Spark.Dsl.Transformer.eval(dsl, [], quote(do: @external_resource(unquote(path))))}
    end
  end
end
