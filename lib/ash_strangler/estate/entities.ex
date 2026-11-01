# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# Target structs for the `estate` DSL entities, and the claim a plug-in
# returns. Data with no behaviour, kept in one file like `entities.ex`.

defmodule AshStrangler.Estate.Disposition do
  @moduledoc """
  A declared disposition: what happens to one legacy relation or column that
  no mapping reads. See `AshStrangler.Estate.Dsl`.

  `id` is `"schema.table"` for a whole relation or `"schema.table.column"` for
  one column. `kind` is one of `:carried`, `:deferred`, `:legacy_only` and
  `:dead`; `wave` and `target` are set only for `:deferred`.
  """
  defstruct [:kind, :id, :because, :wave, :target, :__spark_metadata__]

  @type kind :: :carried | :deferred | :legacy_only | :dead
  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t(),
          because: String.t(),
          wave: atom() | nil,
          target: String.t() | nil
        }

  @doc "The declared kinds, which no claim may use."
  @spec kinds() :: [kind()]
  def kinds, do: [:carried, :deferred, :legacy_only, :dead]
end

defmodule AshStrangler.Estate.Residue do
  @moduledoc """
  A relation a live legacy database may carry that the catalog does not: left
  over from an old migration or a hand edit, and dead by declaration.
  `AshStrangler.Estate.drift_allow/1` turns these into allow patterns for
  `AshStrangler.Snapshot.drift/3`.
  """
  defstruct [:relation, :because, :__spark_metadata__]
  @type t :: %__MODULE__{relation: String.t(), because: String.t()}
end

defmodule AshStrangler.Estate.OpenReference do
  @moduledoc """
  A foreign key out of a mapped relation that the estate accepts as not
  closed: its target is not (yet) mapped or claimed, or the constraint is
  `NOT VALID`. `id` is `"schema.table.constraint_name"`.
  """
  defstruct [:id, :because, :__spark_metadata__]
  @type t :: %__MODULE__{id: String.t(), because: String.t()}
end

defmodule AshStrangler.Estate.Claim do
  @moduledoc """
  A computed disposition: a legacy column that a compiled declaration reads.

  The estate computes `:mapped` claims from its resources' mappings and
  `:secret` claims from their twins' `secrets`. A plug-in
  (`AshStrangler.Estate.Plugin`) adds claims of its own kinds for the host's
  own machinery, such as a projection or an access check that reads legacy
  rows without mapping them. `by` names what claims the column.
  """
  defstruct [:relation, :column, :kind, :by]

  @type t :: %__MODULE__{
          relation: String.t(),
          column: String.t(),
          kind: atom(),
          by: module() | String.t()
        }

  @doc "The kinds the estate computes itself, which a plug-in may not claim."
  @spec reserved_kinds() :: [atom()]
  def reserved_kinds, do: [:mapped, :secret | AshStrangler.Estate.Disposition.kinds()]
end
