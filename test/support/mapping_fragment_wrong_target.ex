# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.WrongTargetUsersMapping do
  @moduledoc """
  A mapping fragment that declares `AshStrangler.Test.LegacyUser` as its
  target — the realistic mistake: a mapping written for one resource, attached
  by another. `AshStrangler.Mapping.verify_target/1` refuses the attachment.

  In its own file, and the only mapping fragment in it:
  `verify_target/1` correlates a source entity with the mapping modules
  compiled from the same file, and two mapping fragments sharing a file is the
  one shape it honestly cannot disambiguate. The probe that attaches it lives
  in `test/ash_strangler/mapping_fragment_test.exs`.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use AshStrangler.Mapping, resource: AshStrangler.Test.LegacyUser

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :login, from: :login
    end
  end
end
