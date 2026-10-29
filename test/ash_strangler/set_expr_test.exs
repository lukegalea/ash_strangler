# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.SetExprTest.ArchivedUser do
  @moduledoc """
  A collapse whose backward `set:` carries an `expr(now())` — what an `archive`
  transition stamps a legacy timestamp with. The expr renders through the
  trigger frame like every write expression; it makes no invertibility claim,
  so the obligations are unchanged.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "set_expr_probe_v"
    schema "verified"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true

    attribute :status, :atom do
      public? true
      constraints one_of: [:archived, :active]
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

      collapse :status do
        hit_policy :first

        state :archived,
          when: expr(not is_nil(deleted_at)),
          set: [deleted_at: expr(now())]

        state :active, when: :otherwise, set: [deleted_at: nil]
      end
    end
  end
end

defmodule AshStrangler.SetExprTest do
  @moduledoc """
  `set:` gains expr values.
  """

  use ExUnit.Case, async: false

  test "the backward direction renders the expr through the trigger frame" do
    [update | _] =
      AshStrangler.Sql.Triggers.build(AshStrangler.SetExprTest.ArchivedUser)
      |> Enum.filter(&(&1.name == :strangler_set_expr_probe_v_update_function))

    assert update.up =~ "WHEN 'archived' THEN now()"
    # :active is the :otherwise fallback, so it renders as the CASE's ELSE.
    assert update.up =~ "ELSE NULL"
  end

  test "the forward direction is unchanged" do
    view = AshStrangler.Sql.View.build(AshStrangler.SetExprTest.ArchivedUser)

    assert view.view.up =~
             "(CASE WHEN (deleted_at IS NOT NULL) THEN 'archived' ELSE 'active' END)"
  end

  test "an expr value makes no invertibility claim: the obligations are unchanged" do
    check = AshStrangler.Obligations.check(AshStrangler.SetExprTest.ArchivedUser)

    # No linearity violation (the expr writes the one column the table owns),
    # and nothing at error severity: the expr value changed nothing about what
    # the table proves — it is a backward-side derivation, not an inverse.
    assert check |> Enum.filter(&(&1.obligation == :linearity)) == []
    assert check |> Enum.reject(&(&1.severity != :error)) == []
  end
end
