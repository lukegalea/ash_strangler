# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.ExtendedUser do
  @moduledoc """
  The extension-store fixture: a mapping over `legacy.users` whose source
  declares

      extension [:notes, :risk_score]

  `:notes` carries a static literal default (`""`) and reads back through
  `COALESCE` — which is the path a pre-existing legacy row takes, since it has
  no extension row at all. `:risk_score` declares no default and reads NULL
  until first written. Both are owned storage beside `legacy.users`: the
  compatibility view `LEFT JOIN`s `strangler."extended_users_extension"`, and
  the `INSTEAD OF` triggers insert/upsert/delete the extension row inside the
  same transaction as the legacy write.

  Any extension attribute forces `writes: :triggers`
  (`AshStrangler.Mechanism.resource_mechanism/1` escalates, exactly as a join
  does), so this fixture is also where the trigger-backed extension write
  paths run against the real database.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "extended_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true, allow_nil?: false
    attribute :email, :ci_string, public?: true
    attribute :notes, :string, public?: true, default: ""
    attribute :risk_score, :integer, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:login, :email, :notes, :risk_score]

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

      extension([:notes, :risk_score])
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace

  @doc "The extension table's qualified name, for raw SQL assertions."
  def extension_table, do: ~s("strangler"."extended_users_extension")
end
