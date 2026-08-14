# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# Target structs for the `strangler` DSL entities.
#
# Spark builds these from the DSL, so their field names are the option names in
# AshStrangler.Dsl. Kept in one file because they are data with no behaviour;
# splitting them across five files would be filing, not structure.

defmodule AshStrangler.Map do
  @moduledoc "One attribute mapped onto legacy data. See `AshStrangler.Dsl`."
  defstruct [
    :attribute,
    :column,
    :from,
    :to,
    :into,
    :cast,
    :from_zone,
    :because,
    # Required by Spark >= 2.7 so it can attach source annotations to the entity.
    :__spark_metadata__,
    writable?: true
  ]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Constant do
  @moduledoc "An attribute with no legacy source, given a fixed SQL expression."
  defstruct [:attribute, :expression, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Unmapped do
  @moduledoc "Attributes deliberately left unmapped, with a stated reason."
  defstruct [:attributes, :because, :__spark_metadata__, as: :null]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Index do
  @moduledoc "A uniqueness constraint that exists on the legacy table."
  defstruct [:name, :columns, :__spark_metadata__, unique: false]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Key do
  @moduledoc "How the modern primary key is derived from the legacy key."
  defstruct [:attribute, :from, :strategy, :__spark_metadata__]
  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Source do
  @moduledoc "The legacy relation a resource is mapped onto."
  defstruct [
    :relation,
    :writes,
    :notify_channel,
    :__spark_metadata__,
    notify?: false,
    mappings: [],
    indexes: [],
    keys: []
  ]

  @type t :: %__MODULE__{}
end
