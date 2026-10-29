# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.MappingVersionTest do
  @moduledoc """
  The mapping version: structurally identical mappings hash equal regardless
  of declaration site; any semantic change moves the hash.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.MappingVersion

  test "the same mapping inline and via fragment hash equal" do
    assert MappingVersion.hash(AshStrangler.MappingVersionTest.VersionInlineUser) ==
             MappingVersion.hash(AshStrangler.MappingVersionTest.VersionFragmentUser)
  end

  test "the hash is 64 hex characters and stable across calls" do
    hash = MappingVersion.hash(AshStrangler.Test.Contract)

    assert String.length(hash) == 64
    assert hash =~ ~r/^[0-9a-f]+$/
    assert MappingVersion.hash(AshStrangler.Test.Contract) == hash
  end

  test "adding a state clause moves the hash" do
    before =
      MappingVersion.hash(define_with(~S|
        collapse :status do
          hit_policy :first

          state :archived,
            when: expr(not is_nil(deleted_at)),
          set: [deleted_at: expr(now())]

          state :active, when: :otherwise, set: [deleted_at: nil]
        end
      |))

    changed =
      define_with(~S|
        collapse :status do
          hit_policy :first

          state :archived,
            when: expr(not is_nil(deleted_at)),
            set: [deleted_at: expr(now())]

          state :suspended,
            when: expr(is_nil(salt)),
            set: [deleted_at: touch()]

          state :active, when: :otherwise, set: [deleted_at: nil]
        end
      |)

    refute MappingVersion.hash(changed) == before
  end

  test "a declaration-order change in a collapse moves the hash" do
    # First-match precedence IS the meaning: swapping clause order is a
    # different mapping even though the clause SET is the same.
    one =
      define_with(~S|
        collapse :status do
          hit_policy :first

          state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]
          state :active, when: :otherwise, set: [deleted_at: nil]
        end
      |)

    two =
      define_with(~S|
        collapse :status do
          hit_policy :first

          state :active, when: :otherwise, set: [deleted_at: nil]
          state :archived, when: expr(not is_nil(deleted_at)), set: [deleted_at: expr(now())]
        end
      |)

    refute MappingVersion.hash(one) == MappingVersion.hash(two)
  end

  test "different resources with different mappings hash differently" do
    refute MappingVersion.hash(AshStrangler.Test.Contract) ==
             MappingVersion.hash(AshStrangler.Test.LegacyUser)
  end

  defp define_with(collapse) do
    name = "AshStrangler.MappingVersionTest.Probe#{System.unique_integer([:positive])}"

    {eval_result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string(
          """
          defmodule #{name} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "version_probe_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false
              attribute :login, :string, public?: true
              attribute :status, :atom do
                public? true
                constraints one_of: [:archived, :active, :suspended]
              end
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :dual_write

              source AshStrangler.Test.Legacy.Users do
                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                map :login, from: :login

                #{collapse}
              end
            end
          end
          """,
          [],
          file: "probe_version.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = eval_result
    module
  end

  # --- local fixtures ----------------------------------------------------------

  defmodule VersionMapping do
    @moduledoc false
    use AshStrangler.Mapping, resource: AshStrangler.MappingVersionTest.VersionFragmentUser

    strangler do
      phase :read_from_legacy

      source AshStrangler.Test.Legacy.Users do
        key :id,
          from: :id,
          strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

        map :login, from: :login
        map :email, from: :email
      end
    end
  end

  defmodule VersionFragmentUser do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      fragments: [AshStrangler.MappingVersionTest.VersionMapping]

    postgres do
      table "version_fragment_v"
      schema "verified"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false
      attribute :login, :string, public?: true
      attribute :email, :ci_string, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule VersionInlineUser do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStrangler.Resource]

    postgres do
      table "version_fragment_v"
      schema "verified"
      repo AshStrangler.TestRepo
      migrate? false
    end

    attributes do
      attribute :id, :uuid, primary_key?: true, allow_nil?: false
      attribute :login, :string, public?: true
      attribute :email, :ci_string, public?: true
    end

    actions do
      defaults [:read]
    end

    strangler do
      phase :read_from_legacy

      source AshStrangler.Test.Legacy.Users do
        key :id,
          from: :id,
          strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

        map :login, from: :login
        map :email, from: :email
      end
    end
  end
end
