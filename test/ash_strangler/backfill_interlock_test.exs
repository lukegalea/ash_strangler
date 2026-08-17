# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.BackfillInterlockTest.Interlocked do
  @moduledoc """
  A `:dual_write` resource that opts into pgroll's backfill interlock.

  It maps `legacy.users`, like the other fixtures, but its own view — so it can
  carry the flag without changing what the rest of the suite generates.
  """
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "interlocked_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true

    attribute :state_code, :integer do
      public? true
      constraints min: 0, max: 4
    end
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      backfill_interlock?(true)

      key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :login, from: :login

      decode :state_code,
        from: :state,
        values: %{active: 0, passive: 1, pending: 2, suspended: 3, deleted: 4}
    end
  end
end

defmodule AshStrangler.BackfillInterlockTest do
  @moduledoc """
  pgroll's backfill interlock: the writer declares the row done.

  `AshStrangler.Backfill` borrowed the flag column from pgroll and credited it, but
  not the interlock — so the backfill/trigger race stayed open. The half that was
  already right is the loop's: the batch statement selects `WHERE flag` under
  `FOR NO KEY UPDATE`, and PostgreSQL re-evaluates a locking query's qualification
  against the *updated* row version, so a row a concurrent writer cleared is dropped
  from the batch automatically. The entire missing half was the `false` nothing
  assigned.

  ## Why the exposure is narrow, and why it still matters

  Every expression `AshStrangler.Backfill.plan/2` derives is a function of the row —
  a key expression over the row's own key, a constant — so re-deriving a row the
  trigger already handled produces identical bytes and the race is invisible because
  it is harmless.

  A hand-passed `set: [counter: "counter + 1"]` is not a function of the row. The
  race double-applies it, and every row count and batch count reads correctly while
  the value is wrong. That is the shape of failure this package exists to refuse, so
  the interlock exists even though the derived path does not need it.
  """

  use ExUnit.Case, async: true

  alias AshStrangler.Backfill
  alias AshStrangler.BackfillInterlockTest.Interlocked
  alias AshStrangler.Test.DualWriteUser

  defp function_body(resource, operation) do
    resource
    |> AshStrangler.Sql.Triggers.build()
    |> Enum.find(&(&1.name == :"strangler_#{table(resource)}_#{operation}_function"))
    |> Map.fetch!(:up)
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  describe "when declared" do
    test "the INSERT lists the flag column and supplies false" do
      body = function_body(Interlocked, :insert)

      assert body =~ ~s|INSERT INTO legacy.users (login, state, "#{Backfill.flag_column()}")|
      assert body =~ "false)"
    end

    test "the UPDATE assigns the flag last, after every mapped column" do
      # Last, because it is bookkeeping rather than part of the mapping, and a
      # reader scanning the `SET` list should be able to tell the difference at a
      # glance.
      body = function_body(Interlocked, :update)

      assert body =~ Backfill.interlock_assignment()

      [_, tail] = String.split(body, "SET ", parts: 2)
      assignments = tail |> String.split("\n  WHERE") |> List.first() |> String.split(",\n")

      assert assignments |> List.last() |> String.trim() == Backfill.interlock_assignment()
    end

    test "the flag is assigned directly rather than through the changed-columns guard" do
      # `on_update: :changed_columns` wraps each assignment in
      # `CASE WHEN expr IS DISTINCT FROM col THEN expr ELSE col END`. Doing that to a
      # bare `false` is correct SQL and reads as though the flag were something the
      # mapping projects, so it is excluded by name.
      body = function_body(Interlocked, :update)

      refute body =~ ~s|"#{Backfill.flag_column()}" = (CASE|
    end

    test "the DELETE does not carry it, because a deleted row has nothing to backfill" do
      refute function_body(Interlocked, :delete) =~ Backfill.flag_column()
    end
  end

  describe "when not declared" do
    test "no generated trigger mentions the flag column at all" do
      # Off by default, and it has to be: the trigger *assigns* to the flag column,
      # so the column has to exist for as long as the interlock is on. Emitting it
      # unasked would make every write on the legacy table fail until somebody ran
      # `add_flag_column!/3`.
      for operation <- [:insert, :update, :delete] do
        refute function_body(DualWriteUser, operation) =~ Backfill.flag_column(),
               "the #{operation} trigger carries the flag without being asked to"
      end
    end
  end

  describe "the two halves agree about the column name" do
    test "the trigger's assignment is the one `interlock_assignment/1` documents" do
      # One definition of the name. A trigger clearing `_strangler_needs_backfill`
      # while the loop reads `needs_backfill` would leave the race exactly as open as
      # before, and nothing would report it -- the backfill would simply redo every
      # row, correctly, forever.
      assert function_body(Interlocked, :update) =~ Backfill.interlock_assignment()
    end
  end
end
