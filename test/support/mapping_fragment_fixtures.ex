# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.UsersFragmentMapping do
  @moduledoc """
  The mapping for `AshStrangler.Test.FragmentMappedUser`, declared **outside**
  the resource as a `AshStrangler.Mapping` fragment.

  It exists so the fragment machinery is exercised by the same fixtures the
  round-trip tests use: the body is the identical `strangler` grammar, the
  resource attaches it with `fragments:`, and
  `test/ash_strangler/mapping_fragment_test.exs` proves the generated DDL is
  byte-identical to the same mapping declared inline.

  In its own file on purpose: `AshStrangler.Mapping.verify_target/1`
  correlates a source entity with the mapping module compiled from the same
  file, and two mapping fragments sharing a file is the one shape it honestly
  cannot disambiguate.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"
  @organization_id "00000000-0000-0000-0000-0000000000fe"

  use AshStrangler.Mapping, resource: AshStrangler.MappingFragmentTest.FragmentMappedUser

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      map :email, from: :email
      map :archived_at, from: :deleted_at, zone: "UTC"

      constant :organization_id, expr(type(@organization_id, :uuid))
    end
  end
end
