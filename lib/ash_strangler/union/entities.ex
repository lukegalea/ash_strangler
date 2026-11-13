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
  defstruct [:name, :table, :__spark_metadata__, write_rules: []]
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
    mappings: [],
    write_rules: [],
    shares_key_with: []
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

defmodule AshStrangler.Union.NotWrittenBack do
  @moduledoc "Columns a `:dual_write` update does not carry to the legacy table."
  defstruct [:attributes, :because, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.Extension do
  @moduledoc "Columns a branch stores in the union's extension table instead of the legacy table."
  defstruct [:attributes, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.RefuseDelete do
  @moduledoc "A branch whose rows a `:dual_write` delete refuses to remove."
  defstruct [:because, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Union.InsertThrough do
  @moduledoc """
  An opt-in insert route on a `:dual_write` branch: an insert naming the branch
  (`NEW."__branch" = '<branch>'`) lands in the legacy table. The legacy table
  allocates its own key, the branch's plain `map` columns are written, `set:`
  gives legacy columns a constant, and the trigger returns the view row of the
  new key, so `RETURNING` carries the key and every default.
  """
  defstruct [:because, :set, :__spark_metadata__, columns: []]
  @type t :: %__MODULE__{}
end
