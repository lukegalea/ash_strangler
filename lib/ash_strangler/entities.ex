# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# Target structs for the `strangler` DSL entities.
#
# Spark builds these from the DSL, so their field names are the option names in
# AshStrangler.Dsl. Kept in one file because they are data with no behaviour;
# splitting them across nine files would be filing, not structure.
#
# Every one of them stores an UNHYDRATED `Ash.Expr` tree -- see
# `AshStrangler.Expr` for why, and `AshStrangler.Lens` for the one place that
# hydrates.

defmodule AshStrangler.Map do
  @moduledoc """
  One attribute projected from legacy data. See `AshStrangler.Dsl`.

  Whether it is writable is **not** a field here. It is computed by
  `AshStrangler.Lens.classify/1` from the shape of `from:`, and `read_only?` is
  an explicit opt-out rather than the declaration of a fact.
  """
  defstruct [
    :attribute,
    :from,
    :zone,
    :because,
    # Required by Spark >= 2.7 so it can attach source annotations to the entity.
    :__spark_metadata__,
    read_only?: false
  ]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Decode do
  @moduledoc "A declared bijection between a legacy value set and an attribute value set."
  defstruct [:attribute, :from, :values, :because, :__spark_metadata__, read_only?: false]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Collapse do
  @moduledoc "Several legacy columns collapsed into one attribute by a decision table."
  defstruct [
    :attribute,
    :because,
    :__spark_metadata__,
    hit_policy: :first,
    states: [],
    read_only?: false
  ]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Collapse.State do
  @moduledoc "One clause of a `collapse`: a forward guard and a backward assignment."
  defstruct [:value, :when, :set, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Coalesce do
  @moduledoc "A legacy NULL read as a default value; the reverse is `NULLIF`."
  defstruct [:attribute, :from, :default, :because, :__spark_metadata__, read_only?: false]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Concat do
  @moduledoc "Several legacy columns joined by a separator; the reverse is `split_part`."
  defstruct [:attribute, :from, :because, :__spark_metadata__, separator: " ", read_only?: false]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Negate do
  @moduledoc "A boolean read inverted. Its own inverse."
  defstruct [:attribute, :from, :because, :__spark_metadata__, read_only?: false]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Affine do
  @moduledoc "A numeric column scaled and shifted: `multiply * col + add`."
  defstruct [
    :attribute,
    :from,
    :because,
    :__spark_metadata__,
    multiply: 1,
    add: 0,
    read_only?: false
  ]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Constant do
  @moduledoc "An attribute with no legacy source, given a fixed expression."
  defstruct [:attribute, :expression, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Unmapped do
  @moduledoc "Attributes deliberately left unmapped, with a stated reason."
  defstruct [:attributes, :because, :__spark_metadata__, as: :null]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Key do
  @moduledoc "How the modern primary key is derived from the legacy key."
  defstruct [:attribute, :from, :strategy, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Source do
  @moduledoc """
  The legacy relation a resource is mapped onto — a *twin* module rather than a
  relation name. See `AshStrangler.Twin`.
  """
  defstruct [
    :twin,
    :writes,
    :notify_channel,
    :__spark_metadata__,
    on_update: :full_row,
    backfill_interlock?: false,
    notify?: false,
    mappings: [],
    keys: []
  ]

  @type t :: %__MODULE__{}
end
