# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# Target structs for the `union` DSL entities. Data with no behaviour, kept in
# one file like `AshStrangler.Entities`.

defmodule AshStrangler.Union.Column do
  @moduledoc "One column of the canonical relation a union presents."
  defstruct [:name, :type, :__spark_metadata__, null?: true]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.Owned do
  @moduledoc "The owned branch: rows that exist only in the new system, in a table the union creates."
  defstruct [:name, :table, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.Legacy do
  @moduledoc "One legacy branch: a twin, a phase, a declared refusal reason and one lens per column."
  defstruct [
    :name,
    :twin,
    :phase,
    :refused_because,
    :filter,
    :__spark_metadata__,
    keys: [],
    mappings: []
  ]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.Map do
  @moduledoc "A column read from the branch's twin: a bare column or an expression over its columns."
  defstruct [:attribute, :from, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.Constant do
  @moduledoc "A column given the same literal for every row of the branch."
  defstruct [:attribute, :value, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.Unmapped do
  @moduledoc "Columns the branch has no source for. They read NULL."
  defstruct [:attributes, :because, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.TenantKey do
  @moduledoc """
  A column read as a packed key of a registry kind: how a branch (or a derived
  source) derives its tenant. Estate check E5 requires the kind to be a tenant
  kind.
  """
  defstruct [:attribute, :kind, :from, :__spark_metadata__]
  @type t :: %__MODULE__{}

  @doc "The twin columns the key packs."
  def columns(%__MODULE__{from: from}), do: List.wrap(from)
end
