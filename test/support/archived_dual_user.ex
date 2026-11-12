# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.ArchivedUser do
  @moduledoc """
  A `:dual_write` resource over the `legacy.users` fixture that uses
  `AshArchival` (the `map :archived_at, from: :deleted_at, zone: "UTC"` gives
  the archive attribute the writable mapping `VerifyArchival` requires).

  It pins the `:dual_write` DELETE decision: the legacy table is still the
  system of record here, and an Ash destroy on an archival resource reaches
  the compatibility view as an **UPDATE** of the mapped archive column —
  AshArchival turns the destroy soft, so the dual-write `INSTEAD OF DELETE`
  never fires and the legacy row stays, stamped. The sibling
  `AshStrangler.Test.ExcludedDestroyUser` covers the deliberate hard delete.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource, AshArchival.Resource]

  postgres do
    table "archived_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true

    attribute :state_code, :integer do
      public? true
      constraints min: 0, max: 4
    end

    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :full_name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:login, :email, :state_code, :archived_at]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      map :email, from: :email
      map :archived_at, from: :deleted_at, zone: "UTC"

      decode :state_code,
        from: :state,
        values: %{
          active: 0,
          passive: 1,
          pending: 2,
          suspended: 3,
          deleted: 4
        }

      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace
end

defmodule AshStrangler.Test.ExcludedDestroyUser do
  @moduledoc """
  The same `:dual_write` mapping as `AshStrangler.Test.ArchivedUser`, with the
  primary destroy listed in `exclude_destroy_actions`.

  That exclusion is an explicit choice to delete, and the dual-write
  `INSTEAD OF DELETE` carries it: the legacy row is removed. The package must
  not second-guess it by archiving instead.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource, AshArchival.Resource]

  postgres do
    table "excluded_destroy_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  archive do
    exclude_destroy_actions([:destroy])
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true

    attribute :state_code, :integer do
      public? true
      constraints min: 0, max: 4
    end

    attribute :archived_at, :utc_datetime_usec, public?: true
    attribute :full_name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:login, :email, :state_code, :archived_at]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      map :email, from: :email
      map :archived_at, from: :deleted_at, zone: "UTC"

      decode :state_code,
        from: :state,
        values: %{
          active: 0,
          passive: 1,
          pending: 2,
          suspended: 3,
          deleted: 4
        }

      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace
end
