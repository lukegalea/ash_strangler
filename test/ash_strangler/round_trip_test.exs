defmodule AshStrangler.RoundTripTest do
  @moduledoc """
  The core of the suite (plan §8.3): insert an arbitrary legacy row with raw
  SQL, read it back through the **generated** compatibility view as an Ash
  record, and assert the projection is faithful.

  Faithful means each mapping kind does what it claims: the key derives, plain
  columns pass through, casts apply, computed columns compute, constants are
  constant, and unmapped columns are NULL. None of those failures raise on
  their own — a wrong projection is a wrong value, quietly, which is why this
  is a property over generated adversarial input rather than a handful of
  examples.

  `:read_from_legacy` is read-only, so this is the read half only. The write
  half — round-tripping back through `INSTEAD OF` triggers — arrives with step
  4, and this harness is deliberately in place first so the risky generator is
  built against an oracle rather than alongside one.
  """

  use AshStrangler.DataCase, async: false
  use ExUnitProperties

  alias AshStrangler.Test.Generators

  describe "the projection is faithful" do
    property "every mapping kind projects correctly for an arbitrary legacy row" do
      check all(row <- Generators.legacy_user_row(), max_runs: 50) do
        legacy_id = insert_legacy_user!(row)
        record = read_through_view!(legacy_id)

        # The key: derived in SQL by the view, recomputed independently in
        # Elixir. `read_through_view!/1` already looked the row up BY the
        # Elixir-derived id, so merely finding it proves agreement -- but
        # asserting it makes the failure legible rather than a confusing
        # "record not found".
        assert record.id == derived_id(legacy_id)

        # A plain mapping with no cast: byte-for-byte pass-through.
        assert record.login == login_of(legacy_id)

        # `cast: :citext`. citext preserves the value as written and changes
        # only how it COMPARES, so the projected text must be unchanged.
        assert ci_to_string(record.email) == row.email

        # A computed mapping. Note what `coalesce(a,'') || ' ' || coalesce(b,'')`
        # actually does: two NULLs produce a single SPACE, not NULL and not "".
        # The concatenation is never null, and NULL is indistinguishable from ""
        # once projected -- verified against PostgreSQL 17.10.
        assert record.full_name == "#{row.first_name} #{row.last_name}"

        # A constant: no legacy source, same value for every row.
        assert record.organization_id == AshStrangler.Test.LegacyUser.organization_id()

        # `unmapped ..., as: :null`.
        assert record.created_by_id == nil

        # `cast: :timestamptz` over a naive `timestamp` column. Only nil-ness is
        # asserted here; which INSTANT it lands on is session-dependent and has
        # its own test below.
        assert is_nil(record.archived_at) == is_nil(row.deleted_at)
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
      from_nulls = read_through_view!(insert_legacy_user!(%{first_name: nil, last_name: nil}))
      from_empties = read_through_view!(insert_legacy_user!(%{first_name: "", last_name: ""}))

      assert from_nulls.full_name == from_empties.full_name
    end
  end

  describe "citext, and what it does not fold" do
    test "folds ASCII case, so two spellings collide" do
      %Postgrex.Result{rows: [[collides?]]} =
        TestRepo.query!("SELECT 'Alice@Example.COM'::citext = 'alice@example.com'::citext", [])

      assert collides?
    end

    test "does NOT fold whitespace or non-ASCII case" do
      # citext folds through SQL `lower()`, which under this cluster's collation
      # touches only ASCII. A developer reading "case-insensitive" will assume
      # otherwise, and an ASCII-only test will never contradict them -- so the
      # negative case is asserted explicitly.
      for {left, right} <- [
            {" alice", "alice"},
            {"alice ", "alice"},
            {"İstanbul", "istanbul"},
            {"Straße", "STRASSE"},
            # NFC vs NFD of the same visual string, escaped so the two are
            # distinguishable in source.
            {"caf\u00E9", "cafe\u0301"}
          ] do
        %Postgrex.Result{rows: [[equal?]]} =
          TestRepo.query!("SELECT $1::citext = $2::citext", [left, right])

        refute equal?, "expected #{inspect(left)} and #{inspect(right)} to stay distinct"
      end
    end
  end

  describe "the timestamp -> timestamptz cast is session-dependent" do
    @tag :hazard
    test "the same stored value projects to different instants under different session TimeZones" do
      # NOT a bug in this test -- a hazard in the generated SQL, pinned here so
      # it cannot change silently. `(deleted_at)::timestamptz` interprets a naive
      # `timestamp` as wall-clock time in the SESSION's TimeZone, so the instant
      # it yields depends on a connection-level setting the view does not
      # control. Verified against PostgreSQL 17.10: the same row read under UTC
      # and under Australia/Lord_Howe is 10.5 hours apart.
      #
      # See docs/plans/ash-strangler.md §10.12 in the reference application for
      # the design options. The mapping asks for `cast: :timestamptz` and the
      # generator emits exactly that; making it deterministic means deciding
      # what timezone a naive legacy column is *in*, which the corpus cannot
      # know and the DSL does not yet ask.
      legacy_id = insert_legacy_user!(%{deleted_at: ~N[2024-06-15 12:00:00]})

      utc = archived_at_under_timezone(legacy_id, "UTC")
      lord_howe = archived_at_under_timezone(legacy_id, "Australia/Lord_Howe")

      refute utc == lord_howe

      # 630 minutes = 10h30m, Lord Howe's offset. Reading noon as UTC gives a
      # LATER instant than reading it as Lord Howe local time, because +10:30
      # means local noon is 01:30 UTC.
      assert DateTime.diff(utc, lord_howe, :minute) == 630
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

  defp ci_to_string(nil), do: nil
  defp ci_to_string(value), do: to_string(value)
end
