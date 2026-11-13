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

  With `through:`, the key packs the end of a declared chain of lookups that
  starts at the twin column `from`, not `from` itself. Each chain is a list of
  hops `{relation, match, take}`: the row of `relation` whose `match` column
  equals the value so far (the lowest `take` when several do), and its `take`
  column becomes the value. Several chains are alternatives, the first non-NULL
  one wins. Estate check E5 holds every hop to a validated foreign key and the
  last `take` to the tenant kind's home.
  """
  defstruct [:attribute, :kind, :from, :through, :__spark_metadata__]
  @type t :: %__MODULE__{}

  @typedoc "One hop of a chain, as declared: `{relation, match_column, take_column}`."
  @type hop :: {String.t(), atom() | String.t(), atom() | String.t()}

  @doc "The twin columns the key reads."
  def columns(%__MODULE__{from: from}), do: List.wrap(from)

  @doc "True when the key packs the end of a declared chain (`through:`), not the twin columns."
  def chained?(%__MODULE__{through: through}), do: through not in [nil, []]

  @doc """
  The declared chains, each a list of hops as maps: `relation` (`{schema, table}`, the schema
  `nil` when the name has none), `name` (the catalog's `schema.table`), `match` and `take`
  (column names as strings).
  """
  def chains(%__MODULE__{through: through}) do
    for chain <- List.wrap(through) do
      for {relation, match, take} <- chain do
        {schema, table} = parts = AshStrangler.Sql.Relation.parse!(relation)

        %{
          relation: parts,
          name: "#{schema || "public"}.#{table}",
          match: to_string(match),
          take: to_string(take)
        }
      end
    end
  end
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
