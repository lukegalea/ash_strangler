# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TypedNullTest do
  @moduledoc """
  An `unmapped ..., as: :null` column must keep the attribute's Postgres type.

  A bare `NULL` in a view's SELECT list resolves to `text`, so an Ash filter on
  a `uuid` attribute compiles to `uuid = text` and Postgres refuses it. This is
  asserted against the real generated view, not the SQL text.
  """
  use AshStrangler.DataCase, async: false

  require Ash.Query

  alias AshStrangler.Test.LegacyUser

  test "the view column keeps the attribute's type" do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!("""
      SELECT format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
      WHERE a.attrelid = 'strangler.users'::regclass AND a.attname = 'created_by_id'
      """)

    assert rows == [["uuid"]]
  end

  test "the column compares against a uuid column, as a relationship join would" do
    insert_legacy_user!()

    # Ash joins a belongs_to by comparing the foreign key column with the other
    # side's uuid. With a text-typed NULL column this raises
    # `operator does not exist: text = uuid`.
    assert %Postgrex.Result{rows: [[0]]} =
             TestRepo.query!("""
             SELECT count(*) FROM strangler.users u
             JOIN strangler.users o ON u.created_by_id = o.id
             """)
  end

  test "a filter on an unmapped uuid attribute runs and matches nothing" do
    insert_legacy_user!()
    some_id = Ash.UUID.generate()

    assert [] = LegacyUser |> Ash.Query.filter(created_by_id == ^some_id) |> Ash.read!()

    assert [_ | _] = LegacyUser |> Ash.Query.filter(is_nil(created_by_id)) |> Ash.read!()
  end

  # The CHANGELOG tells existing installs to drop and recreate. This is why.
  test "CREATE OR REPLACE cannot retype a view built with the bare NULL" do
    %{view: %{up: up}} = AshStrangler.Sql.View.build(LegacyUser)
    assert up =~ "NULL::uuid AS created_by_id"

    TestRepo.query!("DROP VIEW strangler.users CASCADE")

    TestRepo.query!(
      String.replace(up, "CREATE OR REPLACE VIEW", "CREATE VIEW")
      |> String.replace("NULL::uuid", "NULL")
    )

    assert_raise Postgrex.Error, ~r/cannot change data type of view column "created_by_id"/, fn ->
      TestRepo.query!(up)
    end
  end
end
