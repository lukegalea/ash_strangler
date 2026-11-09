# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TypedNullTest.Reference do
  @moduledoc false
  use Ash.Type.NewType, subtype_of: :uuid
end

defmodule AshStrangler.TypedNullTest.EveryType do
  @moduledoc """
  One unmapped attribute per Ash type the printer has a Postgres name for, plus
  one it has none for, over the existing `legacy.users` twin.
  """

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "typed_nulls"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :a_uuid, :uuid, public?: true
    attribute :a_string, :string, public?: true
    attribute :a_utc_datetime, :utc_datetime, public?: true
    attribute :a_utc_datetime_usec, :utc_datetime_usec, public?: true
    attribute :a_datetime, :datetime, public?: true
    attribute :a_naive_datetime, :naive_datetime, public?: true
    attribute :a_time_usec, :time_usec, public?: true
    attribute :an_integer, :integer, public?: true
    attribute :a_new_type, AshStrangler.TypedNullTest.Reference, public?: true
    attribute :a_term, :term, public?: true
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      unmapped [
                 :a_uuid,
                 :a_string,
                 :a_utc_datetime,
                 :a_utc_datetime_usec,
                 :a_datetime,
                 :a_naive_datetime,
                 :a_time_usec,
                 :an_integer,
                 :a_new_type,
                 :a_term
               ],
               as: :null,
               because: "Nothing in the legacy table answers these."
    end
  end
end

defmodule AshStrangler.TypedNullTest do
  @moduledoc """
  An `unmapped ..., as: :null` column must keep the attribute's Postgres type.

  A bare `NULL` in a view's SELECT list resolves to `text`, so comparing the
  column with a `uuid` column fails with `operator does not exist: text = uuid`.
  An Ash filter against a bound parameter does not fail that way, because the
  parameter takes the column's type. This is asserted against the real generated
  view, not the SQL text.
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

  test "every type the printer names is the view column's type" do
    create_view!(AshStrangler.TypedNullTest.EveryType)

    assert column_types("strangler.typed_nulls") == %{
             "a_uuid" => "uuid",
             "a_string" => "text",
             "a_utc_datetime" => "timestamp with time zone",
             "a_utc_datetime_usec" => "timestamp with time zone",
             "a_datetime" => "timestamp with time zone",
             "a_naive_datetime" => "timestamp without time zone",
             "a_time_usec" => "time without time zone",
             "an_integer" => "bigint",
             "a_new_type" => "uuid",
             "a_term" => "text"
           }
  end

  test "an unmapped timestamp compares against a timestamp" do
    create_view!(AshStrangler.TypedNullTest.EveryType)

    assert %Postgrex.Result{rows: [[0]]} =
             TestRepo.query!("""
             SELECT count(*) FROM strangler.typed_nulls
             WHERE a_utc_datetime_usec > now() OR a_datetime > now()
             """)
  end

  defp create_view!(resource) do
    %{view: %{up: up}} = AshStrangler.Sql.View.build(resource)
    TestRepo.query!(up)
  end

  defp column_types(relation) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT a.attname::text, format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute a
        WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND a.attname LIKE 'a%'
        """,
        [relation]
      )

    Map.new(rows, &List.to_tuple/1)
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
