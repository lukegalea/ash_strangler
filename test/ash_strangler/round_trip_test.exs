# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.RoundTripTest do
  @moduledoc """
  The core of the suite: insert an arbitrary legacy row with raw SQL, read it back
  through the **generated** compatibility view as an Ash record, and assert the
  projection is faithful.

  Faithful means each mapping kind does what it claims: the key derives, plain
  columns pass through, derived casts apply, computed columns compute, constants
  are constant, and unmapped columns are NULL. None of those failures raise on
  their own — a wrong projection is a wrong value, quietly, which is why this
  is a property over generated adversarial input rather than a handful of
  examples.

  ## The value space it generates over

  Rows are generated over the **legacy** value space, not the modern one. That is
  the rule the whole design follows from, and it is worth stating in the file that
  would otherwise get it wrong: the modern value space contains only rows this
  package created, while the legacy space is the one holding rows the old
  application wrote over fifteen years, and it is the space a mapping has to be
  faithful on.

  The suite learned this the expensive way. A round-trip property named *"an
  arbitrary row written through Ash reads back as it was stored"* generated
  `state_code <- member_of([0, 1])` — the one value set on which a broken
  five-values-onto-two mapping *is* a bijection — while its legacy-row helper never
  set `state` at all, so every row in the entire suite carried the column default
  `'active'`. Both directions of a mapping that destroyed three of five lifecycle
  states were green.

  So `state` is generated here from `AshStrangler.DataCase.legacy_states/0`, which
  is every value the column actually ranges over.

  `AshStrangler.Test.LegacyUser` is `:read_from_legacy`, so this file is the read
  half. The write half — a row read through the view, written back, and compared
  against the legacy row it came from — is `AshStrangler.DualWriteTest`.
  """

  use AshStrangler.DataCase, async: false
  use ExUnitProperties

  alias AshStrangler.Test.DualWriteUser
  alias AshStrangler.Test.Generators

  describe "the projection is faithful" do
    property "every mapping kind projects correctly for an arbitrary legacy row" do
      check all(
              row <- Generators.legacy_user_row(),
              state <- StreamData.member_of(legacy_states()),
              max_runs: 50
            ) do
        legacy_id = insert_legacy_user!(Map.put(row, :state, state))
        record = read_through_view!(legacy_id)

        # The key: derived in SQL by the view, recomputed independently in
        # Elixir. `read_through_view!/1` already looked the row up BY the
        # Elixir-derived id, so merely finding it proves agreement -- but
        # asserting it makes the failure legible rather than a confusing
        # "record not found".
        assert record.id == derived_id(legacy_id)

        # A plain rename, which needs no mechanism at all: the view column is a
        # simple reference, so it is byte-for-byte pass-through.
        assert record.login == login_of(legacy_id)

        # The derived cast. The twin declares `email` as `:string` and the
        # resource as `:ci_string`, so the view casts to `citext` -- nothing types
        # it, and the reconciler derives its normalisation from those same two
        # facts rather than a third restatement. citext preserves the value as
        # written and changes only how it COMPARES, so the projected text must be
        # unchanged.
        assert ci_to_string(record.email) == row.email

        # A computed mapping, and the one place Ash's operators invert SQL's:
        # `expr((first_name || "") <> " " <> (last_name || ""))` is Ash's `||` for
        # null-defaulting and `<>` for concatenation, so it renders as
        # `coalesce(first_name, '') || ' ' || coalesce(last_name, '')`.
        #
        # Note what that actually does with two NULLs: it produces a single SPACE,
        # not NULL and not "". The concatenation is never null, and NULL is
        # indistinguishable from "" once projected -- verified against PostgreSQL
        # 17.10.
        assert record.full_name == "#{row.first_name} #{row.last_name}"

        # A constant: no legacy source, same value for every row.
        assert record.organization_id == AshStrangler.Test.LegacyUser.organization_id()

        # `unmapped ..., as: :null`.
        assert record.created_by_id == nil

        # `zone: "UTC"` over a naive `timestamp` column. Only nil-ness is asserted
        # here; which INSTANT it lands on is the subject of its own test below.
        assert is_nil(record.archived_at) == is_nil(row.deleted_at)

        # The same legacy row, read through the other resource mapped onto this
        # table, whose `decode` turns the lifecycle into a code. This is `GetTotal`
        # measured rather than proven: the obligation is decided at compile time
        # against the value set the twin *declares*, and this is the same question
        # asked of a value the database actually holds.
        assert Ash.get!(DualWriteUser, derived_id(legacy_id)).state_code ==
                 DualWriteUser.state_codes()[String.to_existing_atom(state)]
      end
    end

    test "a row with every nullable column NULL still projects" do
      legacy_id = insert_legacy_user!(%{email: nil, first_name: nil, last_name: nil})
      record = read_through_view!(legacy_id)

      assert record.email == nil
      assert record.archived_at == nil
      # Not nil, and not "" -- see above.
      assert record.full_name == " "
    end

    test "NULL and empty string are indistinguishable once concatenated" do
      # Recorded as a test rather than a comment because it is a real, permanent
      # limitation of this mapping shape: the projection is lossy, and anything
      # downstream that needs to tell "no first name recorded" from "first name
      # recorded as empty" cannot get it from `full_name`.
      #
      # It is also why `full_name` is `read_only?: true` with a reason rather than
      # a `concat`: `concat` reverses with `split_part`, and no separator makes
      # that correct for 'de la Cruz'.
      from_nulls = read_through_view!(insert_legacy_user!(%{first_name: nil, last_name: nil}))
      from_empties = read_through_view!(insert_legacy_user!(%{first_name: "", last_name: ""}))

      assert from_nulls.full_name == from_empties.full_name
    end
  end

  describe "the projection is total over the legacy value space" do
    test "every value `state` ranges over projects to the code the decode declares" do
      # The property the old suite could not have failed, because it never inserted
      # a row whose `state` was anything but the column default.
      #
      # Compared against the mapping's own declaration rather than a copy of it, so
      # this test cannot drift from the DSL -- and comparing the whole map at once
      # asserts three things in one: every legacy value projects (totality), none
      # projects to NULL, and no two share a code (injectivity, which is what makes
      # the reverse have one answer per row).
      projected =
        Map.new(legacy_states(), fn state ->
          legacy_id = insert_legacy_user!(%{state: state})
          record = Ash.get!(DualWriteUser, derived_id(legacy_id))

          {String.to_existing_atom(state), record.state_code}
        end)

      assert projected == DualWriteUser.state_codes()
    end
  end

  describe "citext, and what it does not fold" do
    test "folds ASCII case, so two spellings collide" do
      %Postgrex.Result{rows: [[collides?]]} =
        TestRepo.query!("SELECT 'Alice@Example.COM'::citext = 'alice@example.com'::citext", [])

      assert collides?
    end

    test "never folds whitespace, under any collation" do
      # Invariant. citext folds case, never whitespace, so leading and trailing
      # padding keeps rows distinct that a human would call duplicates.
      for {left, right} <- [{" alice", "alice"}, {"alice ", "alice"}, {"alice", "ALICE "}] do
        refute citext_equal?(left, right),
               "expected #{inspect(left)} and #{inspect(right)} to stay distinct"
      end
    end

    test "never folds NFC against NFD, under any collation" do
      # Also invariant: citext does no Unicode normalization. These two render
      # identically and are unequal under `=`, under citext, and therefore under
      # any Ash identity built on the column.
      #
      # Written as escapes rather than literally, because spelled out they are two
      # source lines that look identical, with no way for a reader to tell which is
      # which -- and an edit that "tidied" them into literals would silently delete
      # the distinction the test exists for.
      refute citext_equal?("caf\u00E9", "cafe\u0301")
    end

    test "folds non-ASCII case only when the database collation does" do
      # **This is a portability hazard, not a curiosity.** citext folds by
      # calling SQL `lower()`, which follows the database's LC_CTYPE. Under `C`
      # only ASCII folds; under a UTF-8 locale, Turkish dotted I and friends fold
      # too. So the SAME mapping gives a different uniqueness answer on two
      # servers -- and a strangler migration is precisely a situation with two
      # servers involved.
      #
      # Found by CI: this suite asserted the `C` behaviour it saw locally and
      # failed on postgres:16, whose default collation is a UTF-8 locale. The
      # test now asserts the DEPENDENCY, so it is honest on either.
      %Postgrex.Result{rows: [[collation]]} =
        TestRepo.query!("SELECT datctype FROM pg_database WHERE datname = current_database()", [])

      c_locale? = collation in ["C", "POSIX", "C.UTF-8", "C.utf8"]

      folds? = citext_equal?("\u0130stanbul", "istanbul")

      if c_locale? do
        refute folds?, "under #{collation} citext should fold only ASCII"
      else
        assert folds?, "under #{collation} citext should fold non-ASCII case too"
      end
    end
  end

  describe "`zone:` makes the timestamp projection connection-independent" do
    test "the same stored value projects to one instant under every session TimeZone" do
      # The regression test for a measured 10.5 hours of drift. With a bare
      # `(deleted_at)::timestamptz` this same assertion showed two connections
      # reading two different instants from one row -- silently, with no error
      # anywhere -- because the cast reads a naive value as wall-clock time in the
      # SESSION's TimeZone. `zone: "UTC"` renders `AT TIME ZONE 'UTC'`, stating the
      # zone in the view itself.
      #
      # `AT TIME ZONE` is also the only form that could carry an index:
      # `timezone(text, timestamp without time zone)` is IMMUTABLE, while the
      # one-argument form a bare cast resolves to is STABLE, and PostgreSQL refuses
      # a STABLE function in an index expression.
      #
      # Lord Howe is in the list deliberately: its offset is a half hour, so an
      # implementation that still depended on the session in some partial way
      # would show a fractional-hour difference that a whole-hour zone could
      # mask.
      legacy_id = insert_legacy_user!(%{deleted_at: ~N[2024-06-15 12:00:00]})

      instants =
        for zone <- ["UTC", "America/New_York", "Australia/Lord_Howe"],
            do: archived_at_under_timezone(legacy_id, zone)

      assert Enum.uniq(instants) == [~U[2024-06-15 12:00:00.000000Z]]
    end
  end

  defp archived_at_under_timezone(legacy_id, timezone) do
    TestRepo.query!("SET LOCAL TimeZone = '#{timezone}'", [])

    %Postgrex.Result{rows: [[archived_at]]} =
      TestRepo.query!("SELECT archived_at FROM strangler.users WHERE __legacy_id = $1", [
        legacy_id
      ])

    DateTime.from_naive!(archived_at, "Etc/UTC")
  end

  defp login_of(legacy_id) do
    %Postgrex.Result{rows: [[login]]} =
      TestRepo.query!("SELECT login FROM legacy.users WHERE id = $1", [legacy_id])

    login
  end

  defp citext_equal?(left, right) do
    %Postgrex.Result{rows: [[equal?]]} =
      TestRepo.query!("SELECT $1::citext = $2::citext", [left, right])

    equal?
  end

  defp ci_to_string(nil), do: nil
  defp ci_to_string(value), do: to_string(value)
end
