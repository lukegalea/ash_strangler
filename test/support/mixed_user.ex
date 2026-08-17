# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.MixedUser do
  @moduledoc """
  The fixture that proves mechanism tiering.

  A `:dual_write` resource whose view holds a **mix**: two plain column references
  and two computed columns, of which the computed ones are read-only. Per
  PostgreSQL's `CREATE VIEW` rule — *"a column is updatable if it is a simple
  reference to an updatable column of the underlying base relation; otherwise the
  column is read-only, and an error will be raised if an `INSERT`, `UPDATE`, or
  `MERGE` statement attempts to assign a value to it"* — such a view is
  automatically updatable, and a computed column costs nothing unless something
  assigns to it.

  So `AshStrangler.Info.writes/1` resolves to `:auto` here, **no `INSTEAD OF`
  triggers are emitted**, and `AshStrangler.MechanismTest` asserts against a live
  database that:

    * `UPDATE` of a plain column succeeds;
    * `UPDATE` of a computed column errors, with PostgreSQL's own message;
    * `INSERT … ON CONFLICT DO UPDATE … RETURNING` works, on both the insert and
      the conflict — which is the property that matters, because
      `ash_authentication`'s OAuth2 and OIDC register actions **cannot be defined
      without an upsert**;
    * `DELETE` succeeds.

  0.1 could not have this fixture, because it had no way to state a computed
  mapping that keeps the view auto-updatable and no test asserting the trade was
  real either way. The whole `INSTEAD OF` trade was documented and never measured.

  It shares `legacy.users` with the other two fixtures on purpose: three resources
  over one wide legacy table is the case this package exists for, and it is what
  makes `strangler.mixed_users`, `strangler.users` and `strangler.dual_users`
  coexist over one base relation.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "mixed_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
    attribute :email, :string, public?: true
    attribute :full_name, :string, public?: true
    attribute :state_label, :string, public?: true
  end

  identities do
    identity :unique_login, [:login]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:login, :email]

    create :create do
      primary? true
    end

    # The action that would be impossible on the trigger path. `ON CONFLICT` is
    # rejected outright once an `INSTEAD OF` trigger exists -- measured:
    # `ERROR: there is no unique or exclusion constraint matching the ON CONFLICT
    # specification`.
    create :upsert do
      upsert? true
      upsert_identity :unique_login
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      # Plain references. `AshStrangler.Mechanism` classifies these `:plain`, and
      # PostgreSQL makes them updatable with no mechanism at all.
      #
      # `email` is `:string` here rather than `:ci_string`, and that is not
      # incidental. A `:ci_string` attribute over a `text` column makes
      # `AshStrangler.Lens` derive `(email)::citext`, which is a cast, which is not
      # a *simple reference*, which costs the column its auto-updatability. That is
      # a real trade and it is worth seeing stated: the cast buys case-insensitive
      # comparison through the view and charges a mechanism for it.
      # `mix ash_strangler.check` prints which columns are paying.
      map :login, from: :login
      map :email, from: :email

      # Computed, and read-only. Read-only is what keeps the view auto-updatable:
      # the columns are not updatable, and nothing tries to update them.
      map :full_name,
        from: expr((first_name || "") <> " " <> (last_name || "")),
        read_only?: true,
        because: "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."

      map :state_label,
        from: expr(fragment("upper(?::text)", state)),
        read_only?: true,
        because: "Presentational. The lifecycle is owned by DualWriteUser's decode."
    end
  end

  @doc "The namespace the key strategy hashes against, for test assertions."
  def namespace, do: @namespace
end
