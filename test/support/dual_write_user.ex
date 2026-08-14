# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.DualWriteUser do
  @moduledoc """
  A `:dual_write` resource over the same `legacy.users` fixture, projected
  through its own view so it can coexist with `AshStrangler.Test.LegacyUser`.

  Its mapping deliberately forces the trigger path: `state_code` is a computed
  mapping with an inverse (`from`/`to`/`into`), and per
  `AshStrangler.Info.writes/1` that is exactly what makes view
  auto-updatability insufficient. So this fixture exercises generated
  `INSTEAD OF` triggers, while `LegacyUser` covers the read-only phase.

  It also carries a `writable? false` mapping, so the guard that raises with
  the mapping's own `because:` text has something to fire on -- including an
  apostrophe in that text, since the message is interpolated into a plpgsql
  string literal and a naive implementation would produce a syntax error the
  first time somebody wrote "don't".
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "dual_users"
    schema "strangler"
    repo AshStrangler.TestRepo
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true
    attribute :state_code, :integer, public?: true
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

    source "legacy.users" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: @namespace}

      map :login, "login"
      map :email, "email", cast: :citext
      map :archived_at, "deleted_at", cast: :timestamptz, from_zone: "UTC"

      # The mapping that forces triggers: computed forward, explicit backward.
      map :state_code do
        from "CASE state WHEN 'active' THEN 0 ELSE 1 END"
        to "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'suspended' END"
        into "state"
      end

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
      end

      index "index_users_on_login", unique: true, columns: ["login"]
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace
end
