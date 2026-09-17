# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.LedgerUser do
  @moduledoc """
  A third mapping over the same `legacy.users` fixture, carrying `ledger?
  true` — the resource whose statements install the `legacy_change_events`
  table and the combined ledger-plus-wake trigger.

  It deliberately shares its legacy relation with `AshStrangler.Test.LegacyUser`
  and `AshStrangler.Test.DualWriteUser`, which is the case the ledger's
  "one table per relation" claim rests on: this resource's statements emit the
  ledger DDL, the others' emit none, and one trigger serves the table.

  Its `notify_channel` is its own, on purpose. The ledger trigger's wake
  payload (`wake:<event id>`) replaces the JSON envelope on the channel it
  notifies, and the notify-trigger integration tests listen on the default
  channel expecting envelope payloads — sharing a channel would make
  `assert_receive` grab whichever trigger spoke first, which is a race, not a
  test.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "ledger_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :ci_string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      notify? true
      ledger?(true)
      notify_channel "ash_strangler_ledger_test"

      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :login, from: :login
      map :email, from: :email
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace
end
