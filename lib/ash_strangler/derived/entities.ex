# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Derived.Source do
  @moduledoc """
  One way a legacy row yields canonical rows: a `slot`, a `synthesized` row or
  the `element`s of a jsonb array. Data with no behaviour.
  """
  defstruct [
    :name,
    :kind,
    :filter,
    :from,
    :type,
    :value,
    :ordinal,
    :__spark_metadata__,
    path: [],
    mappings: []
  ]

  @type t :: %__MODULE__{}
end
