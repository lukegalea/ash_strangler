# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.MechanismTest do
  @moduledoc """
  Mechanism tiering, measured against PostgreSQL rather than asserted.

  The claim under test is one paragraph of the `CREATE VIEW` manual page:

  > A column is updatable if it is a **simple reference to an updatable column of
  > the underlying base relation**; otherwise the column is read-only, and an error
  > will be raised if an `INSERT`, `UPDATE`, or `MERGE` statement attempts to assign
  > a value to it.

  Read carefully, that is a rule about **columns**, not about views. So a view may
  hold a mix of updatable and read-only columns, a computed column costs nothing
  unless something assigns to it, and — the part that matters for a real
  migration — upserts, `RETURNING` and `WITH CHECK OPTION` are lost to the
  *trigger*, not to the computation.

  0.1 assumed otherwise: any writable computed mapping forced `INSTEAD OF` triggers
  for the whole resource. That assumption is the premise of the reference
  application's conclusion that **authentication must cut over first**, because
  `ash_authentication`'s OAuth2 and OIDC register actions cannot be defined without
  an upsert. The reasoning was sound and the premise was wrong.

  Every assertion here goes through the SQL the generators actually emit, against a
  live PostgreSQL 17.10, because the whole trade was documented in 0.1 and never
  measured.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Test.DualWriteUser
  alias AshStrangler.Test.MixedUser

  # `pg_column_is_updatable/3` rather than `information_schema.columns`, and the
  # third argument is `true` — *include triggers*. `information_schema` is defined
  # by the SQL standard to pass `false` there, so it reports `NO` for a view made
  # writable purely by our triggers. Asking the catalog directly is the only way to
  # get the answer PostgreSQL will actually act on.
  #
  # `to_regclass($1)` rather than `$1::regclass`: Postgrex sends a bound parameter
  # for an `oid` column as an integer, so the cast form fails with "you tried to use
  # a binary for an oid type" before it reaches the server.
  defp view_column_updatability(view) do
    %Postgrex.Result{rows: rows} =
      TestRepo.query!(
        """
        SELECT a.attname, pg_column_is_updatable(to_regclass($1), a.attnum, true)
        FROM pg_attribute a
        WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """,
        [view]
      )

    Map.new(rows, fn [name, updatable] -> {name, updatable} end)
  end

  describe "the classification" do
    test "a rename is :plain and needs no mechanism at all" do
      assert {:login, :plain, :plain} in AshStrangler.Mechanism.report(MixedUser)
      assert {:email, :plain, :plain} in AshStrangler.Mechanism.report(MixedUser)
    end

    test "a read-only computed mapping is :none, because nothing is written" do
      assert {:full_name, :none, :none} in AshStrangler.Mechanism.report(MixedUser)
      assert {:state_label, :none, :none} in AshStrangler.Mechanism.report(MixedUser)
    end

    test "a mixed view of plain and read-only columns resolves to :auto, and emits no triggers" do
      assert AshStrangler.Info.writes(MixedUser) == :auto
      assert AshStrangler.Sql.Triggers.build(MixedUser) == []
    end

    test "the report separates the tier a mapping deserves from the tier this version emits" do
      # The honest half of the result. A `decode` is row-local and reversible, so a
      # `BEFORE` trigger on the base table plus a shadow column would carry it and
      # the view would stay auto-updatable -- pgroll's design. Emitting that means
      # `ALTER TABLE legacy.users ADD COLUMN`, which this generator will not do to a
      # table it does not own, so it folds up to `:instead_of`.
      #
      # Reporting one number would either overstate what the generator does or hide
      # what the schema could support. Reporting both is what makes the gap -- and
      # the DDL that would close it -- a decision somebody can take.
      assert {:state_code, :base_trigger, :instead_of} in AshStrangler.Mechanism.report(
               DualWriteUser
             )

      assert AshStrangler.Info.writes(DualWriteUser) == :triggers
    end

    test "a join escalates the whole resource, because updatability needs one base relation" do
      # The boundary of the per-column rule, and it is worth pinning because the
      # per-column rule is this module's headline result.
      #
      # `CREATE VIEW`'s column rule narrows *which* mappings force a trigger within
      # one base relation. It does not survive a second one: automatic updatability
      # requires exactly one, so a join makes the whole view non-updatable regardless
      # of how each column classifies. Without the escalation, a resource whose only
      # writable mapping was a plain rename alongside a read-only `expr(address.city)`
      # resolved to `writes: :auto` and emitted no triggers at all — on a view
      # PostgreSQL will not accept a write to. `pg_relation_is_updatable` returns `0`
      # for every column of such a view, and the only symptom is an error on the
      # first `UPDATE`.
      assert AshStrangler.Info.joins(AshStrangler.DiagramTest.Account) != []
      assert AshStrangler.Info.writes(AshStrangler.DiagramTest.Account) == :triggers
    end

    test "a derived cast costs a column its plain tier, which is a real trade rather than a detail" do
      # `email` on `DualWriteUser` is `:ci_string` over a `text` column, so the lens
      # derives `(email)::citext`. That is not a simple reference, so the view column
      # is not auto-updatable -- the cast buys case-insensitive comparison through
      # the view and charges a mechanism for it.
      #
      # `MixedUser` declares the same column `:string` and keeps `:plain`. Both are
      # defensible; the point is that the choice is visible instead of accidental.
      assert {:email, :base_trigger, :instead_of} in AshStrangler.Mechanism.report(DualWriteUser)
      assert {:email, :plain, :plain} in AshStrangler.Mechanism.report(MixedUser)
    end
  end

  describe "what PostgreSQL actually does with the mixed view" do
    test "the plain columns are updatable and the computed ones are not" do
      updatability = view_column_updatability("strangler.mixed_users")

      assert updatability["login"] == true
      assert updatability["email"] == true

      assert updatability["full_name"] == false
      assert updatability["state_label"] == false
      assert updatability["id"] == false
    end

    test "updating a plain column succeeds, with no trigger anywhere near it" do
      login = insert_mixed_row!()

      assert %Postgrex.Result{num_rows: 1} =
               TestRepo.query!(
                 "UPDATE strangler.mixed_users SET email = $1 WHERE login = $2",
                 ["updated@example.com", login]
               )

      assert legacy_email(login) == "updated@example.com"
    end

    test "updating a computed column errors, quoting PostgreSQL's own explanation" do
      login = insert_mixed_row!()

      error =
        assert_raise Postgrex.Error, fn ->
          TestRepo.query!(
            "UPDATE strangler.mixed_users SET full_name = $1 WHERE login = $2",
            ["Nope", login]
          )
        end

      message = Exception.message(error)
      assert message =~ ~s(cannot update column "full_name")
      assert message =~ "not columns of their base relation"
    end

    test "INSERT ... ON CONFLICT DO UPDATE ... RETURNING works, on the insert and on the conflict" do
      # The property the whole tiering result is for. `ash_authentication`'s OAuth2
      # and OIDC register actions are upserts by construction -- their own
      # transformer refuses to define them without `upsert? true` -- so a resource
      # that loses `ON CONFLICT` cannot carry them at all.
      login = "upsert-#{System.unique_integer([:positive])}"

      insert = fn email ->
        TestRepo.query!(
          """
          INSERT INTO strangler.mixed_users (login, email) VALUES ($1, $2)
          ON CONFLICT (login) DO UPDATE SET email = EXCLUDED.email
          RETURNING id, login, email, full_name, state_label
          """,
          [login, email]
        )
      end

      assert %Postgrex.Result{num_rows: 1, rows: [[id, ^login, "first@example.com" | _]]} =
               insert.("first@example.com")

      assert id != nil

      assert %Postgrex.Result{num_rows: 1, rows: [[^id, ^login, "second@example.com" | _]]} =
               insert.("second@example.com")

      assert legacy_email(login) == "second@example.com"
    end

    test "deleting through the mixed view removes the legacy row" do
      login = insert_mixed_row!()

      assert %Postgrex.Result{num_rows: 1} =
               TestRepo.query!("DELETE FROM strangler.mixed_users WHERE login = $1", [login])

      assert %Postgrex.Result{rows: []} =
               TestRepo.query!("SELECT 1 FROM legacy.users WHERE login = $1", [login])
    end
  end

  describe "the same operations through Ash" do
    test "an upsert action round-trips through the auto-updatable view" do
      login = "ash-upsert-#{System.unique_integer([:positive])}"

      first =
        MixedUser
        |> Ash.Changeset.for_create(:upsert, %{login: login, email: "one@example.com"})
        |> Ash.create!()

      second =
        MixedUser
        |> Ash.Changeset.for_create(:upsert, %{login: login, email: "two@example.com"})
        |> Ash.create!()

      assert second.id == first.id
      assert second.email == "two@example.com"
    end

    test "a read-only column is computed from what was actually stored" do
      user =
        MixedUser
        |> Ash.Changeset.for_create(:create, %{
          login: "ash-#{System.unique_integer([:positive])}",
          email: "computed@example.com"
        })
        |> Ash.create!()

      # `first_name` and `last_name` are both NULL, so the concatenation is a
      # single space rather than nil -- which is the projection doing its job, and
      # is only observable because the view was re-read rather than assumed.
      assert user.full_name == " "
      assert user.state_label == "ACTIVE"
    end
  end

  describe "the contrast: what the trigger path costs" do
    test "ON CONFLICT is rejected outright on a view with INSTEAD OF triggers" do
      # `VerifyNoUpserts` refuses this at compile time. Measured here so the
      # verifier is refusing something real rather than something believed.
      error =
        assert_raise Postgrex.Error, fn ->
          TestRepo.query!(
            """
            INSERT INTO strangler.dual_users (login, email, state_code) VALUES ($1, $2, 0)
            ON CONFLICT (login) DO UPDATE SET email = EXCLUDED.email
            """,
            ["conflict-#{System.unique_integer([:positive])}", "x@example.com"]
          )
        end

      assert Exception.message(error) =~ "ON CONFLICT"
    end

    test "the same conflict target succeeds on the auto-updatable view over the same base table" do
      # Same legacy table, same unique index, same conflict target. The only
      # difference is the trigger, which is the whole point: the cost belongs to the
      # mechanism and not to the computation.
      login = "same-#{System.unique_integer([:positive])}"

      assert %Postgrex.Result{num_rows: 1} =
               TestRepo.query!(
                 """
                 INSERT INTO strangler.mixed_users (login, email) VALUES ($1, $2)
                 ON CONFLICT (login) DO UPDATE SET email = EXCLUDED.email
                 """,
                 [login, "y@example.com"]
               )
    end
  end

  defp insert_mixed_row!(attrs \\ %{}) do
    login = Map.get_lazy(attrs, :login, fn -> "mixed-#{System.unique_integer([:positive])}" end)
    insert_legacy_user!(Map.put(attrs, :login, login))
    login
  end

  defp legacy_email(login) do
    %Postgrex.Result{rows: [[email]]} =
      TestRepo.query!("SELECT email FROM legacy.users WHERE login = $1", [login])

    email
  end
end
