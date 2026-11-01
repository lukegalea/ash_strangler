# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Transformers.DeclareSnapshotResource do
  @moduledoc """
  Makes a snapshot catalog an `@external_resource` of the module that names
  it: a twin (`twin do snapshot ... end`), a key-kind registry
  (`key_kinds do snapshot ... end`) or an estate (`estate do snapshot ... end`).

  Without it, editing `catalog.json` recompiles nothing, so
  `AshStrangler.Verifiers.VerifySnapshot` and
  `AshStrangler.Verifiers.VerifyEstate` would keep passing against the catalog
  they last read: a compile-time check that only runs when somebody happens to
  touch the module is not a check.
  """

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    case AshStrangler.Twin.snapshot(dsl) || AshStrangler.KeyKinds.snapshot(dsl) ||
           Spark.Dsl.Extension.get_opt(dsl, [:estate], :snapshot, nil) do
      nil ->
        {:ok, dsl}

      path ->
        {:ok, Spark.Dsl.Transformer.eval(dsl, [], quote(do: @external_resource(unquote(path))))}
    end
  end
end
