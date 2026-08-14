# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ReconcilerTest do
  @moduledoc """
  Step 6: mutation tests for the drift detector (plan §8.5).

  The reconciler is the correctness oracle for everything else in this package,
  which makes it the one module where "the tests pass" proves the least. A
  checker that always returns `agrees?: true` passes every naive test ever
  written for it and silently certifies a broken migration.

  So the shape of this file is: for each way two relations can disagree,
  introduce that disagreement deliberately and assert the reconciler finds it.
  The `agrees?` tests exist only to prove the detector is not stuck on
  "different", and each one is paired with a mutation of the same fixture.

  The fixtures live in a `reconciler_test` schema created inside the test's own
  sandbox transaction, and the "modern" side is a **table**, not a view. A view
  over a table cannot drift from it by construction, so a test built on one
  could never fail. The reconciler does not care either way: it compares two
  relations, and whether either is a view is not its business. One test does
  use a real generated-shape view, to prove exactly that.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Reconciler

  @config [
    legacy: [relation: "reconciler_test.legacy_users", key: "id"],
    view: [relation: "reconciler_test.modern_users", key: "__legacy_id"],
    columns: [email: "email", name: {"first_name", "name"}],
    batch_size: 2
  ]

  setup do
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS reconciler_test", [])

    TestRepo.query!(
      """
      CREATE TABLE reconciler_test.legacy_users (
        id         bigint PRIMARY KEY,
        email      text,
        first_name text
      )
      """,
      []
    )

    TestRepo.query!(
      """
      CREATE TABLE reconciler_test.modern_users (
        __legacy_id bigint PRIMARY KEY,
        email       text,
        name        text
      )
      """,
      []
    )

    :ok
  end

  # Seeds both sides identically. Values chosen to be hostile on purpose: a
  # NULL, an empty string, a separator character, a quote, and a non-ASCII
  # string are each a way a checksum encoding can lose information.
  defp seed_agreeing!(count \\ 6) do
    values = [
      {"alice@example.com", "Alice"},
      {nil, "Bob"},
      {"", "Carol"},
      {"dave@example.com", "a|b"},
      {"eve@example.com", "O'Hara"},
      {"frank@example.com", "Ünïcødé"}
    ]

    values
    |> Enum.take(count)
    |> Enum.with_index(1)
    |> Enum.each(fn {{email, name}, id} ->
      insert_legacy!(id, email, name)
      insert_modern!(id, email, name)
    end)
  end

  defp insert_legacy!(id, email, name) do
    TestRepo.query!(
      "INSERT INTO reconciler_test.legacy_users (id, email, first_name) VALUES ($1, $2, $3)",
      [id, email, name]
    )
  end

  defp insert_modern!(id, email, name) do
    TestRepo.query!(
      "INSERT INTO reconciler_test.modern_users (__legacy_id, email, name) VALUES ($1, $2, $3)",
      [id, email, name]
    )
  end

  defp config(overrides \\ []), do: Keyword.merge(@config, overrides)

  describe "agreement" do
    test "a faithful pair reports no drift, including NULLs, quotes and separators" do
      seed_agreeing!()

      result = Reconciler.diff(TestRepo, config())

      assert result.agrees?
      assert result.counts == %{agrees?: true, legacy: 6, view: 6, drift: 0}
      assert result.checksums.mismatched == []
      assert length(result.checksums.batches) == 3
      assert result.checksums.columns == [:email, :name]
    end

    test "batches tile the whole key space in order" do
      seed_agreeing!()

      %{checksums: %{batches: batches}} = Reconciler.diff(TestRepo, config())

      assert Enum.map(batches, &{&1.lower, &1.upper, &1.rows}) == [
               {1, 2, 2},
               {3, 4, 2},
               {5, 6, 2}
             ]
    end

    test "an empty pair agrees rather than crashing" do
      assert Reconciler.diff(TestRepo, config()).agrees?
    end

    test "physical row order does not affect the checksum" do
      seed_agreeing!()

      # A plain UPDATE writes a new tuple version further down the heap, so this
      # row now scans *last* on the modern side and first on the legacy side.
      # Without `ORDER BY` inside `string_agg` the two checksums differ --
      # reproducibly, convincingly, and entirely fictionally.
      TestRepo.query!(
        "UPDATE reconciler_test.modern_users SET name = name WHERE __legacy_id = 1",
        []
      )

      # Forcing the seq scan is not stacking the deck, it is the only way to
      # test the thing at this size. Verified on 17.10: with an index or bitmap
      # plan the update stays a HOT chain, the index still points at the
      # original ctid, and the row comes back in key order anyway -- so an
      # unordered aggregate looks perfectly stable in a six-row fixture and
      # falls apart on the first production batch wide enough to seq-scan.
      Enum.each(["indexscan", "bitmapscan", "indexonlyscan"], fn plan ->
        TestRepo.query!("SET LOCAL enable_#{plan} = off", [])
      end)

      assert Reconciler.diff(TestRepo, config(batch_size: 10)).agrees?
    end

    test "a real compatibility view over the legacy table agrees with it" do
      seed_agreeing!()

      # The generated-view shape: a derived key column named `__legacy_id` and
      # a computed column. Proves the reconciler does not care which side is a
      # view -- and that a computed column is compared as an expression, not as
      # a column name.
      TestRepo.query!(
        """
        CREATE VIEW reconciler_test.users_view AS
          SELECT id AS __legacy_id, email, coalesce(first_name, '') AS name
          FROM reconciler_test.legacy_users
        """,
        []
      )

      result =
        Reconciler.diff(
          TestRepo,
          config(
            view: [relation: "reconciler_test.users_view", key: "__legacy_id"],
            columns: [email: "email", name: {"coalesce(first_name, '')", "name"}]
          )
        )

      assert result.agrees?
    end
  end

  describe "mutation: the detector must find these" do
    test "a changed value is found, and localized to its batch" do
      seed_agreeing!()

      TestRepo.query!(
        "UPDATE reconciler_test.modern_users SET name = 'Corrupted' WHERE __legacy_id = 5",
        []
      )

      result = Reconciler.diff(TestRepo, config())

      refute result.agrees?
      # Counts are perfect. This is the failure that a count-only reconciler
      # calls healthy: a mapping reading the wrong column keeps every row.
      assert result.counts.agrees?

      assert [batch] = result.checksums.mismatched
      assert {batch.lower, batch.upper} == {5, 6}
      assert batch.legacy != batch.view
    end

    test "a missing row is found by both counts and checksums" do
      seed_agreeing!()
      TestRepo.query!("DELETE FROM reconciler_test.modern_users WHERE __legacy_id = 3", [])

      result = Reconciler.diff(TestRepo, config())

      refute result.agrees?
      assert result.counts == %{agrees?: false, legacy: 6, view: 5, drift: 1}
      assert [%{lower: 3, upper: 4}] = result.checksums.mismatched
    end

    test "a row that exists only on the modern side is inside a batch, not past the end" do
      seed_agreeing!()
      insert_modern!(99, "ghost@example.com", "Ghost")

      result = Reconciler.diff(TestRepo, config())

      # Batching off the legacy side alone would end at key 6 and never look at
      # 99, so the checksum pass would report agreement while the counts
      # disagreed -- a report that reads as "some rows are missing" when what
      # actually happened is "rows exist that should not". The key ranges come
      # from the union of both sides for exactly this row.
      assert result.counts.drift == -1
      assert [%{lower: 99, upper: 99, rows: 1}] = result.checksums.mismatched
    end

    test "a value replaced by NULL is found" do
      seed_agreeing!()

      TestRepo.query!(
        "UPDATE reconciler_test.modern_users SET email = NULL WHERE __legacy_id = 3",
        []
      )

      result = Reconciler.diff(TestRepo, config())

      refute result.agrees?
      assert result.counts.agrees?
      assert [%{lower: 3, upper: 4}] = result.checksums.mismatched
    end

    test "a NULL that shifts a column boundary is found" do
      # The `concat_ws` trap, in the one arrangement where it bites. Verified
      # on 17.10: `concat_ws('|', NULL, 'a|b')` and `concat_ws('|', 'a', 'b')`
      # are both "a|b", because skipping the NULL removes a separator and every
      # column after it slides. Two rows that agree about nothing would be
      # certified identical.
      #
      # It is the more dangerous shape of bug precisely because `concat_ws`
      # *does* tell NULL and '' apart when neither sits at a boundary -- so the
      # case anyone would check by hand comes out right.
      insert_legacy!(1, nil, "a|b")
      insert_modern!(1, "a", "b")

      result = Reconciler.diff(TestRepo, config())

      refute result.agrees?
      assert result.counts.agrees?
      assert [%{lower: 1, upper: 1}] = result.checksums.mismatched
    end

    test "values shuffled across the separator are found" do
      # ('a|b', 'c') against ('a', 'b|c'). A naive `a || '|' || b` renders both
      # as "a|b|c" and reports agreement. Quoting each value makes the encoding
      # injective, so no separator inside a value can imitate a column boundary.
      insert_legacy!(1, "a|b", "c")
      insert_modern!(1, "a", "b|c")

      result = Reconciler.diff(TestRepo, config())

      refute result.agrees?
      assert result.counts.agrees?
      assert [%{lower: 1, upper: 1}] = result.checksums.mismatched
    end
  end

  describe "normalization (§10.14)" do
    setup do
      # What Ash actually does to this column: `Ash.Type.CiString` trims by
      # default and compares case-insensitively, so a value written through Ash
      # is stored trimmed while the legacy application stores it as typed. Both
      # sides are correct. Neither is drift.
      insert_legacy!(1, "  Alice@Example.com ", "Alice")
      insert_modern!(1, "alice@example.com", "Alice")
      :ok
    end

    test "without a normalizer this is reported, forever" do
      # Not a bug -- the honest baseline. It is what makes the first production
      # run a wall of false positives, and why the hook exists at all.
      refute Reconciler.diff(TestRepo, config()).agrees?
    end

    test ":ci_string suppresses it, because that is what Ash did to the value" do
      assert Reconciler.diff(TestRepo, config(normalize: %{email: :ci_string})).agrees?
    end

    test "normalizing does not blind the column to real drift" do
      # The assertion that makes the one above safe. A normalizer is a way to
      # ignore a known, explained transformation -- not a way to stop looking
      # at a column, which is what an over-broad one silently becomes.
      TestRepo.query!(
        "UPDATE reconciler_test.modern_users SET email = 'someone.else@example.com'",
        []
      )

      refute Reconciler.diff(TestRepo, config(normalize: %{email: :ci_string})).agrees?
    end

    test "normalization applies to both sides, not just the legacy one" do
      # `btrim` alone would leave the legacy side as "Alice@Example.com" and the
      # modern side as "alice@example.com". Only a normalizer applied to both
      # sides makes this a comparison of equivalence classes rather than of
      # bytes, and `:trim` is deliberately not enough here.
      refute Reconciler.diff(TestRepo, config(normalize: %{email: :trim})).agrees?

      assert Reconciler.diff(TestRepo, config(normalize: %{email: {:sql, "lower(btrim(%s))"}})).agrees?
    end

    test "a function normalizer is accepted for cases the shorthands do not cover" do
      normalizer = fn expression -> "lower(btrim(#{expression}))" end

      assert Reconciler.diff(TestRepo, config(normalize: %{email: normalizer})).agrees?
    end

    test "an unrecognised normalizer is rejected rather than ignored" do
      # Silently ignoring it would mean the column is compared un-normalised
      # and the report fills with the false positives the config was written to
      # prevent.
      assert_raise ArgumentError, ~r/unsupported normalizer for :email/, fn ->
        Reconciler.diff(TestRepo, config(normalize: %{email: :trimmed}))
      end
    end
  end

  describe "count_drift/2" do
    test "reports a signed drift so the direction is legible" do
      seed_agreeing!(4)
      TestRepo.query!("DELETE FROM reconciler_test.legacy_users WHERE id = 1", [])

      assert Reconciler.count_drift(TestRepo, config()) == %{
               agrees?: false,
               legacy: 3,
               view: 4,
               drift: -1
             }
    end
  end
end
