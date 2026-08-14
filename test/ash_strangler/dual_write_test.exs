# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.DualWriteTest do
  @moduledoc """
  Step 4: writes made through Ash reach the legacy table, correctly, and come
  back correctly.

  Every test here goes through the **generated** `INSTEAD OF` triggers — the
  fixture installer executes the generator's output verbatim, so a trigger that
  Postgres would reject never reaches these tests, and a trigger that is merely
  *wrong* fails here rather than in production.

  The two failures worth naming, because both report success while being wrong:

    * a trigger that returns `NEW` instead of re-reading gives Ash a record with
      a **null primary key** and raises nothing;
    * a trigger that writes nothing at all still reports `UPDATE 1`.
  """

  use AshStrangler.DataCase, async: false
  use ExUnitProperties

  alias AshStrangler.Test.DualWriteUser
  alias AshStrangler.Test.Generators

  defp create!(attrs) do
    attrs
    |> Map.put_new_lazy(:login, fn -> "dw-#{System.unique_integer([:positive])}" end)
    |> Map.put_new(:state_code, 0)
    |> then(&Ash.create!(DualWriteUser, &1))
  end

  defp legacy_row(login) do
    %Postgrex.Result{rows: [row], columns: columns} =
      TestRepo.query!(
        "SELECT state, email, login, deleted_at FROM legacy.users WHERE login = $1",
        [login]
      )

    columns |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()
  end

  describe "INSTEAD OF INSERT" do
    test "RETURNING reports the stored row, not what the trigger was handed" do
      # The §10.1 regression. A trigger body that inserts and then returns NEW
      # produces exactly this call succeeding with a nil id -- no error, no
      # warning, and Ash holding an unusable record.
      user = create!(%{email: "returning@example.com"})

      assert user.id != nil
      assert user.id == derived_id_for(user.login)

      # __legacy_id is populated by the re-read too, which is what later phases
      # key their updates off.
      assert to_string(user.email) == "returning@example.com"
    end

    test "the write reaches the legacy table with the inverse mapping applied" do
      user = create!(%{state_code: 0, email: "inverse@example.com"})

      # state_code 0 maps back through `to:` to the legacy string 'active'.
      assert legacy_row(user.login).state == "active"

      suspended = create!(%{state_code: 1})
      assert legacy_row(suspended.login).state == "suspended"
    end

    test "a derived column is computed from what was actually stored" do
      # full_name is read-only and computed from first_name/last_name, neither
      # of which this insert sets -- so it must come back as the coalesce of two
      # NULLs, a single space, rather than nil.
      user = create!(%{})

      assert user.full_name == " "
    end
  end

  describe "INSTEAD OF UPDATE" do
    test "updates the legacy row and returns the re-read result" do
      user = create!(%{state_code: 0, email: "before@example.com"})

      updated =
        user
        |> Ash.Changeset.for_update(:update, %{state_code: 1, email: "after@example.com"})
        |> Ash.update!()

      assert updated.id == user.id
      assert to_string(updated.email) == "after@example.com"

      legacy = legacy_row(user.login)
      assert legacy.state == "suspended"
      assert legacy.email == "after@example.com"
    end

    test "a vanished legacy row is caught, not silently reported as updated" do
      user = create!(%{})
      TestRepo.query!("DELETE FROM legacy.users WHERE login = $1", [user.login])

      # Ash catches this before the trigger does, and that is the better
      # outcome: deleting the legacy row removes it from the view too, so
      # Ash's `UPDATE ... WHERE id = $1` matches nothing and it reports a stale
      # record. The trigger's own `IF NOT FOUND` guard is therefore defence in
      # depth for the narrower race -- the view row read, the legacy row
      # deleted concurrently, then the update arriving -- rather than the
      # primary mechanism.
      #
      # What matters either way is that neither path reports success: an
      # INSTEAD OF trigger that writes nothing still returns `UPDATE 1`.
      assert_raise Ash.Error.Invalid, ~r/stale record/, fn ->
        user
        |> Ash.Changeset.for_update(:update, %{state_code: 1})
        |> Ash.update!()
      end
    end
  end

  describe "INSTEAD OF DELETE" do
    test "removes the legacy row and does not raise StaleEntryError" do
      user = create!(%{})

      # Returning NULL here would report "0 rows affected" for a delete that
      # succeeded, which Ecto surfaces as Ecto.StaleEntryError.
      assert :ok == Ash.destroy!(user)

      assert %Postgrex.Result{rows: []} =
               TestRepo.query!("SELECT 1 FROM legacy.users WHERE login = $1", [user.login])
    end
  end

  describe "writing a writable? false mapping" do
    test "raises, quoting the mapping's own because: text" do
      user = create!(%{})

      # Ash will not send `full_name` -- it is not in default_accept -- so the
      # guard is exercised the way a legacy application or a hand-written query
      # would hit it: straight at the view.
      assert_raise Postgrex.Error, ~r/de la Cruz/, fn ->
        TestRepo.query!(
          "UPDATE strangler.dual_users SET full_name = $1 WHERE __legacy_id = (SELECT id FROM legacy.users WHERE login = $2)",
          ["Someone Else", user.login]
        )
      end
    end

    test "the reason survives the apostrophes in it" do
      # `because:` is prose interpolated into a plpgsql string literal, and the
      # DSL's own documentation example contains apostrophes. A naive
      # implementation produces a function that fails to compile -- which would
      # have taken the whole fixture install down, so reaching this assertion at
      # all is most of the test.
      user = create!(%{})

      error =
        assert_raise Postgrex.Error, fn ->
          TestRepo.query!(
            "UPDATE strangler.dual_users SET full_name = 'x' WHERE __legacy_id = (SELECT id FROM legacy.users WHERE login = $1)",
            [user.login]
          )
        end

      assert Exception.message(error) =~ "'de la Cruz' splits wrong"
    end
  end

  describe "the timestamp inverse" do
    test "a timestamptz written through Ash lands as the right naive instant" do
      # The write direction of §10.12. Assigning a timestamptz to a naive
      # `timestamp` column uses an assignment cast that reads the session's
      # TimeZone -- the same hazard as the read, mirrored. `from_zone: "UTC"`
      # makes the trigger emit `AT TIME ZONE 'UTC'` explicitly.
      user = create!(%{archived_at: ~U[2024-06-15 12:00:00.000000Z]})

      assert legacy_row(user.login).deleted_at == ~N[2024-06-15 12:00:00.000000]
    end

    test "and survives a full write-read round trip under a shifted session zone" do
      TestRepo.query!("SET LOCAL TimeZone = 'Australia/Lord_Howe'", [])

      user = create!(%{archived_at: ~U[2024-06-15 12:00:00.000000Z]})

      assert user.archived_at == ~U[2024-06-15 12:00:00.000000Z]
      assert legacy_row(user.login).deleted_at == ~N[2024-06-15 12:00:00.000000]
    end
  end

  describe "round trip" do
    property "an arbitrary row written through Ash reads back as it was stored" do
      check all(
              email <- Generators.adversarial_text(),
              state_code <- StreamData.member_of([0, 1]),
              max_runs: 25
            ) do
        created = create!(%{email: email, state_code: state_code})
        read_back = Ash.get!(DualWriteUser, created.id)

        assert read_back.id == created.id
        assert read_back.state_code == state_code

        # Compared against what the create RETURNED, not against the input.
        # Ash casts before the value ever reaches SQL -- see the asymmetry test
        # below -- so asserting against `email` here would be testing Ash's type
        # casting rather than this package's projection.
        assert read_back.email == created.email
      end
    end

    test "Ash's own type casting can diverge from what the legacy app would write" do
      # A real dual-write hazard, and not one this package can fix.
      # `Ash.Type.CiString` defaults to `trim?: true`, so a value written
      # through Ash is trimmed before it reaches the database, while the same
      # value written directly by the legacy application is not. During
      # dual-write the two paths therefore disagree about what is stored, and
      # nothing raises.
      #
      # The reconciler (step 6) is what should surface this class of drift.
      # Pinned here so the behaviour is at least known and deliberate.
      through_ash = create!(%{email: "  padded@example.com  "})

      assert to_string(through_ash.email) == "padded@example.com"

      login = "legacy-#{System.unique_integer([:positive])}"
      insert_legacy_user!(%{login: login, email: "  padded@example.com  "})

      assert legacy_row(login).email == "  padded@example.com  "
    end
  end

  defp derived_id_for(login) do
    %Postgrex.Result{rows: [[legacy_id]]} =
      TestRepo.query!("SELECT id FROM legacy.users WHERE login = $1", [login])

    AshStrangler.KeyDerivation.uuid_v5(
      DualWriteUser.namespace(),
      AshStrangler.KeyDerivation.name("legacy.users", legacy_id)
    )
  end
end
