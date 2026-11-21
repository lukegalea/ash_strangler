# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# Target structs for the `facade` DSL entities that are not mapping entities.
#
# The mapping entities (`map`, `decode`, `collapse` and the rest) are the
# strangler's own structs, declared verbatim — see `AshStrangler.Dsl.mapping_entities/0`.
# These three are the facade's own vocabulary: what is deliberately not placed,
# and what writes through the source.

defmodule AshStrangler.Facade.Hide do
  @moduledoc """
  A source attribute this facade leaves out, with the reason.

      hide :internal_notes, because: "Not part of this vocabulary."

  Hidden is a decision on the record: the estate check refuses an attribute
  that is neither exposed, hidden nor deferred, and refuses a hidden attribute
  that some lens reads anyway.
  """
  defstruct [:attribute, :because, :__spark_metadata__]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Facade.Defer do
  @moduledoc """
  A source attribute not placed yet.

      defer :legacy_ref

  A deferral is honest ignorance: the attribute exists on the source, this
  facade does not answer it, and nothing is claimed about when it will. The
  estate check accepts it in place of a mapping or a `hide`.
  """
  defstruct [:attribute, :__spark_metadata__]

  @type t :: %__MODULE__{}
end

defmodule AshStrangler.Facade.WriteSpec do
  @moduledoc """
  One write: a generic action on the facade that runs ONE named source action.

      write :finish, via: :complete, sets: [state: :finished]
      write :set_estimate, via: :set_estimate, accepts: [:effort_minutes]

  `sets:` names facade attributes and the values they take; `accepts:` names
  facade attributes whose argument value travels through the lens. Both are
  put through the lens's reverse direction, so a read-only lens is refused at
  compile time with its `because:` text.

  Named `WriteSpec` because `AshStrangler.Facade.Write` is the runtime
  implementation module (`Ash.Resource.Actions.Implementation`) that the
  generated generic action runs.
  """
  defstruct [:name, :via, :__spark_metadata__, sets: [], accepts: []]

  @type t :: %__MODULE__{}
end
