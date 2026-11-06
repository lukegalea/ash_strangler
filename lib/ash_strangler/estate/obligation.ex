# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Obligation do
  @moduledoc """
  One estate obligation: a statement about the legacy rows that no schema can
  prove, a query that measures it and the denominator it is measured over.

  `shape` says what the query returns:

    * `:census`: one row of two integers, `violations` then `total`;
    * `:count`: one row of one integer, the number of violations (`0` is clean);
    * `:rows`: the offending rows themselves, one per violation (none is clean; a row
      holding the value `0` is a violation like any other).

  `severity` is what a violation means: `:error` fails the report, `:warning`
  only reports. A host brings its own through
  `c:AshStrangler.Estate.Plugin.obligations/1`; `AshStrangler.Estate.Obligations`
  collects the library's own from the estate's resources.
  """

  @enforce_keys [:id, :summary, :denominator, :sql]
  defstruct [:id, :summary, :denominator, :sql, shape: :census, severity: :error, source: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          summary: String.t(),
          denominator: String.t(),
          sql: String.t(),
          shape: :census | :count | :rows,
          severity: :error | :warning,
          source: String.t() | nil
        }
end
