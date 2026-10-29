# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.MappingFragmentTest.FragmentMappedUser do
  @moduledoc """
  The resource the fragment maps. It contains no strangler content of its own
  — no `extensions:`, no `strangler` block — which is the R1.1 success
  condition, not a convenience.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshStrangler.Test.UsersFragmentMapping]

  postgres do
    table "fragment_users_v"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :organization_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.MappingFragmentTest.FragmentInlineUser do
  @moduledoc """
  The same mapping `AshStrangler.Test.UsersFragmentMapping` declares, written
  inline — the control side of the byte-identical DDL assertion.
  """
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"
  @organization_id "00000000-0000-0000-0000-0000000000fe"

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "fragment_users_v"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :organization_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

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

defmodule AshStrangler.MappingFragmentTest.ProbeTwoSources do
  @moduledoc """
  An inline `source` *and* an attached fragment over the same twin — the shape
  `VerifySingleSource` exists to refuse, kept compilable so the verifier can be
  called over it directly.
  """
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource],
    fragments: [AshStrangler.Test.UsersFragmentMapping]

  postgres do
    table "two_sources_v"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :login, from: :login
    end
  end
end

defmodule AshStrangler.MappingFragmentTest.ProbeWrongTarget do
  @moduledoc """
  Attaches `AshStrangler.Test.WrongTargetUsersMapping`, which declares
  `AshStrangler.Test.LegacyUser` as its target. Compiles clean — Spark cannot
  see the fragment module to compare — which is exactly why the target check
  lives in `verify_target/1`.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshStrangler.Test.WrongTargetUsersMapping]

  postgres do
    table "fragment_users_v"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.MappingFragmentTest do
  @moduledoc """
  Out-of-resource mappings: the fragment carries the whole `strangler` block,
  the resource carries none of it, and the generated SQL cannot tell the
  difference.
  """

  use ExUnit.Case, async: false

  # --- the product --------------------------------------------------------------

  test "a fragment-declared mapping generates byte-identical DDL to the inline one" do
    inline = AshStrangler.Migration.statements(AshStrangler.MappingFragmentTest.FragmentInlineUser)
    via_fragment = AshStrangler.Migration.statements(AshStrangler.MappingFragmentTest.FragmentMappedUser)

    assert via_fragment == inline

    # Both directions of every statement, in the order a migration runs them —
    # comparing `up` alone would pass a generator whose `down` could not undo it.
    assert Enum.map(via_fragment, & &1.down) == Enum.map(inline, & &1.down)
  end

  test "the fragment carries the extension and the target; the resource carries none of it" do
    mapping = AshStrangler.Test.UsersFragmentMapping
    resource = AshStrangler.MappingFragmentTest.FragmentMappedUser

    assert function_exported?(mapping, :target, 0)
    assert mapping.target() == resource
    assert AshStrangler.Resource in Spark.extensions(resource)
    assert AshStrangler.Info.strangled?(resource)
    assert AshStrangler.Info.source(resource).twin == AshStrangler.Test.Legacy.Users
  end

  test "a resource cannot carry two sources, inline and fragment alike" do
    verifier = AshStrangler.Verifiers.VerifySingleSource

    probe = AshStrangler.MappingFragmentTest.ProbeTwoSources.spark_dsl_config()

    assert {:error, error} = verifier.verify(probe)

    message = Exception.message(error)

    assert message =~
             "resource has 2 strangler sources (inline and/or fragments): " <>
               "two mappings is the same bug as two answers to one question"

    assert message =~ "Keep one mapping per resource"
  end

  # --- the target declaration ---------------------------------------------------

  test "verify_target accepts the fragment attached to its declared resource" do
    assert :ok = AshStrangler.Mapping.verify_target(AshStrangler.MappingFragmentTest.FragmentMappedUser)
  end

  test "verify_target refuses the fragment attached to any other resource" do
    assert {:error, message} = AshStrangler.Mapping.verify_target(AshStrangler.MappingFragmentTest.ProbeWrongTarget)

    assert message =~
             "mapping AshStrangler.Test.WrongTargetUsersMapping declares target " <>
               "AshStrangler.Test.LegacyUser but is attached to " <>
               "AshStrangler.MappingFragmentTest.ProbeWrongTarget"
  end
end
