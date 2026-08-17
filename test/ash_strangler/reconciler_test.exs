# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ReconcilerTest do
  @moduledoc """
  Mutation tests for the drift detector.

  The reconciler is the correctness oracle for everything else in this package,
  which makes it the one module where "the tests pass" proves the least. A
  checker that always returns `agrees?: true` passes every naive test ever
  written for it and silently certifies a broken migration.

  So the shape of this file is: for each way two relations can disagree,
  introduce that disagreement deliberately and assert the reconciler finds it.
  The `agrees?` tests exist only to prove the detector is not stuck on
  "different", and each one is paired with a mutation of the same fixture.

  ## Two fixtures, because there are two things to disprove

  The first half runs on a `reconciler_test` schema created inside the test's own
  sandbox transaction, where the "modern" side is a **table**, not a view. A view
  over a table cannot drift from it by construction, so a test built on one could
  never fail. The reconciler does not care either way: it compares two relations,
  and whether either is a view is not its business.

  The second half runs on the real generated view over the real `legacy` fixture,
  because that is the only way to test the *derivation* — that
  `diff(resource)` compares the expressions the view actually projects, over the
  relations the mapping actually names, under the normalisation the attribute's
  Ash type actually performs. Where that half needs the two sides to be able to
  diverge, it takes a copy of the view into a table and corrupts the copy.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Reconciler

  @config [
    legacy: [relation: "reconciler_test.legacy_users", key: "id"],
    view: [relation: "reconciler_test.modern_users", key: "__legacy_id"],
    columns: [email: "email", name: {"first_name", "name"}],
    batch_size: 2
  ]

  @copy "reconciler_test.users_copy"

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

  describe "normalization" do
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

    test "each shorthand covers exactly its own cause and no more" do
      # `btrim` alone leaves the legacy side as "Alice@Example.com" and the
      # modern side as "alice@example.com"; `lower` alone leaves the legacy
      # side's surrounding whitespace. Only a normalizer that covers both
      # transformations Ash performed on a trimming `Ash.Type.CiString` makes
      # this a comparison of equivalence classes rather than of bytes -- and the
      # narrower two are deliberately not enough here, which is the property
      # that keeps them usable on a column where only one applies.
      refute Reconciler.diff(TestRepo, config(normalize: %{email: :trim})).agrees?
      refute Reconciler.diff(TestRepo, config(normalize: %{email: :downcase})).agrees?

      assert Reconciler.diff(TestRepo, config(normalize: %{email: :ci_string})).agrees?
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

    test "a raw SQL template is refused by name, not accepted" do
      # `{:sql, "%s AT TIME ZONE 'UTC'"}` was a third mini-language for one
      # transform, sitting beside the view's own `AT TIME ZONE 'UTC'` with
      # nothing relating the two. Two spellings of one rule drift, and when this
      # pair drifts the reconciler reports drift that is not there. The zone is
      # part of the forward expression now, and both sides are printed from it,
      # so there is nothing left for a template to say -- and a config still
      # carrying one must fail loudly rather than be silently reinterpreted.
      assert_raise ArgumentError, ~r/unsupported normalizer for :email/, fn ->
        Reconciler.diff(TestRepo, config(normalize: %{email: {:sql, "lower(btrim(%s))"}}))
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

  # --- the derived comparison ---------------------------------------------------

  describe "plan/2: the comparison comes out of the mapping" do
    test "the relations and the key are read off the twin and the key entity" do
      plan = Reconciler.plan(LegacyUser)

      assert plan[:repo] == TestRepo
      assert plan[:legacy] == [relation: "legacy.users", key: "id"]
      assert plan[:view] == [relation: "strangler.users", key: "__legacy_id"]
    end

    test "each column's legacy side is verbatim an expression the view selects" do
      # The whole claim, as an assertion: the reconciler is not comparing
      # something *equivalent* to what the view projects, it is comparing the
      # same printed string. A hand-transcribed `columns:` list can be equivalent
      # today and equivalent-looking tomorrow, and nothing compares the two.
      %{view: %{up: view_sql}} = AshStrangler.Sql.View.build(LegacyUser)

      for {name, {legacy, view}} <- Reconciler.plan(LegacyUser)[:columns] do
        assert String.contains?(view_sql, "#{legacy} AS #{name}"),
               "#{legacy} is not what the view selects as #{name}"

        assert view == to_string(name)
      end
    end

    test "a rename is read from the twin on one side and from the resource on the other" do
      # `map :nickname, from: :nick`. Both halves of the comparison come from
      # that one line, which is why they cannot disagree about which column is
      # which. The qualification is the join's doing -- see the joined test
      # below.
      columns = Reconciler.plan(AshStrangler.DiagramTest.Account)[:columns]

      assert columns[:nickname] == {"accounts.nick", "nickname"}
    end

    test "the key, constants and unmapped attributes are not compared" do
      names = Keyword.keys(Reconciler.plan(LegacyUser)[:columns])

      # The key is the comparison's own join condition, not one of its columns.
      refute :id in names
      # A constant renders the same literal on both sides, so comparing it
      # measures the printer against itself.
      refute :organization_id in names
      # `unmapped` is a declaration that the legacy side has nothing to offer.
      refute :created_by_id in names
    end

    test "a read-only mapping is compared, because read-only is not the same as unchecked" do
      # Being unable to write `full_name` back has nothing to do with whether the
      # value the view serves is right, and this is the shape of mapping most
      # likely to be wrong -- a missed `coalesce` reports "NULL Cruz" to every
      # consumer, forever, with the row count perfect.
      assert Keyword.has_key?(Reconciler.plan(LegacyUser)[:columns], :full_name)
    end

    test "the normalizer is derived from the attribute's Ash type" do
      # `email` is `:ci_string`; `login` and `full_name` are `:string`, which
      # trims by default; `archived_at` is a datetime and needs nothing. Nobody
      # writes `:trim` against every string column of a wide resource by hand,
      # and every one they miss is a permanent false positive.
      assert Reconciler.plan(LegacyUser)[:normalize] == %{
               login: :trim,
               email: :ci_string,
               full_name: :trim
             }
    end

    test "a joined mapping reconciles against the view's own FROM clause" do
      # A bare `FROM drawn_legacy.accounts` would fail on the first qualified
      # reference, which is the good outcome; printing an unqualified frame to
      # make it parse would compare a different query, which is not.
      plan = Reconciler.plan(AshStrangler.DiagramTest.Account)

      assert plan[:legacy][:relation] =~ "LEFT JOIN"
      assert plan[:legacy][:relation] =~ "AS address"
      assert plan[:legacy][:key] == "accounts.id"
      assert plan[:columns][:city] == {"address.city", "city"}
    end

    test "an override replaces the derived value rather than merging into it" do
      plan = Reconciler.plan(LegacyUser, view: [relation: "x.y", key: "k"], normalize: %{})

      assert plan[:view] == [relation: "x.y", key: "k"]
      assert plan[:normalize] == %{}
      # Everything not overridden is still derived.
      assert plan[:legacy] == [relation: "legacy.users", key: "id"]
    end

    test "a resource with no strangler mapping says so, and says what to do instead" do
      assert_raise ArgumentError, ~r/has no strangler `source`/, fn ->
        Reconciler.plan(AshStrangler.DiagramTest.Plain)
      end
    end

    test "a repo passed with no comparison says which of the two forms it wanted" do
      # The one confusing failure the two-subjects-one-name dispatch can produce.
      assert_raise ArgumentError, ~r/needs the comparison passed with it/, fn ->
        Reconciler.diff(TestRepo)
      end
    end
  end

  describe "diff/2 against the generated view" do
    setup do
      ids =
        Enum.map(
          [
            # Hostile on purpose, and each value is hostile about something the
            # derivation has to get right: whitespace and case that
            # `Ash.Type.CiString` normalises away, a NULL inside the
            # concatenation `full_name` reads, a separator character, a quote,
            # and a naive `deleted_at` that only `zone:` makes comparable.
            %{
              email: "  Alice@Example.com ",
              first_name: "Alice",
              last_name: "Adams",
              deleted_at: ~N[2024-06-15 12:00:00.000000]
            },
            %{email: nil, first_name: nil, last_name: "de la Cruz"},
            %{email: "", first_name: "a|b", last_name: nil},
            %{email: "eve@example.com", first_name: "O'Hara", last_name: "Ünïcødé"},
            %{email: "frank@example.com", first_name: "Frank", last_name: "Fox"}
          ],
          &insert_legacy_user!/1
        )

      %{ids: ids}
    end

    test "the generated view agrees with the table it is generated from" do
      # It cannot drift by construction, so this proves nothing about the view --
      # it proves the *derivation*. A wrong frame, a wrong cast, a wrong
      # normalizer or a column read off the wrong side all show up here as drift.
      assert Reconciler.diff(LegacyUser).agrees?
    end

    test "the derived comparison computes the identical checksums to a transcribed one" do
      # Not just the same verdict: the same digests, batch for batch. Equal
      # verdicts would also be produced by two comparisons that both looked at
      # nothing.
      transcribed = [
        legacy: [relation: "legacy.users", key: "id"],
        view: [relation: "strangler.users", key: "__legacy_id"],
        columns: [
          login: "login",
          email: {"(email)::citext", "email"},
          full_name:
            {"(coalesce(first_name, '') || (' ' || coalesce(last_name, '')))", "full_name"},
          archived_at: {"(deleted_at AT TIME ZONE 'UTC')", "archived_at"}
        ],
        normalize: %{login: :trim, email: :ci_string, full_name: :trim},
        batch_size: 2
      ]

      derived = Reconciler.diff(LegacyUser, batch_size: 2)
      hand = Reconciler.diff(TestRepo, transcribed)

      assert derived.agrees? == hand.agrees?
      assert derived.counts == hand.counts

      assert Enum.map(derived.checksums.batches, &{&1.lower, &1.upper, &1.legacy, &1.view}) ==
               Enum.map(hand.checksums.batches, &{&1.lower, &1.upper, &1.legacy, &1.view})
    end
  end

  # A table taken from the view, so the two sides *can* diverge. The rest of the
  # comparison stays derived, which is the point: a mutation has to be caught by
  # the columns and normalizers the mapping produced, not by a column list
  # written to catch it.
  defp copy_view! do
    TestRepo.query!("DROP TABLE IF EXISTS #{@copy}", [])
    TestRepo.query!("CREATE TABLE #{@copy} AS SELECT * FROM strangler.users", [])
  end

  defp against_copy(overrides \\ []) do
    Reconciler.diff(
      LegacyUser,
      Keyword.merge([view: [relation: @copy, key: "__legacy_id"], batch_size: 2], overrides)
    )
  end

  defp corrupt!(assignment) do
    copy_view!()

    TestRepo.query!(
      """
      UPDATE #{@copy} SET #{assignment}
      WHERE __legacy_id = (SELECT min(__legacy_id) FROM #{@copy})
      """,
      []
    )
  end

  describe "mutation: the derived comparison must find these" do
    setup do
      ids =
        Enum.map(
          [
            %{
              email: "  Alice@Example.com ",
              first_name: "Alice",
              last_name: "Adams",
              deleted_at: ~N[2024-06-15 12:00:00.000000]
            },
            %{email: nil, first_name: nil, last_name: "de la Cruz"},
            %{email: "eve@example.com", first_name: "O'Hara", last_name: "Ünïcødé"}
          ],
          &insert_legacy_user!/1
        )

      %{ids: ids}
    end

    test "a faithful copy agrees" do
      copy_view!()

      assert against_copy().agrees?
    end

    test "every column the derivation produced is actually compared" do
      # This is the assertion aimed squarely at the failure a transcribed
      # `columns:` list produces: a column left out is not compared, and a
      # comparison that skips a column reports agreement. So each derived column
      # is mutated in turn and each mutation must be found -- and the set of
      # columns under test is checked against the derivation, so a mapping that
      # grows a column fails this test until the mutation for it exists.
      mutations = %{
        login: "login = login || 'x'",
        email: "email = 'someone.else@example.com'",
        full_name: "full_name = 'Corrupted'",
        archived_at: "archived_at = '1999-12-31 23:59:59Z'"
      }

      assert MapSet.new(Keyword.keys(Reconciler.plan(LegacyUser)[:columns])) ==
               MapSet.new(Map.keys(mutations))

      for {column, assignment} <- mutations do
        corrupt!(assignment)

        refute against_copy().agrees?, "drift in #{inspect(column)} was not detected"
      end
    end

    test "the derived normalizer suppresses Ash's normalisation and nothing else" do
      # `Ash.Type.CiString` trims and declares case not to be information, so the
      # same address written through Ash and through the legacy application is
      # stored differently and both are correct. Deriving `:ci_string` from the
      # attribute's type is what stops that being reported forever -- and
      # `normalize: %{}` is the same comparison with the derivation switched off,
      # which is how we know the derivation is doing work rather than being
      # vacuous.
      copy_view!()
      TestRepo.query!("UPDATE #{@copy} SET email = lower(btrim(email))", [])

      assert against_copy().agrees?
      refute against_copy(normalize: %{}).agrees?
    end

    test "the derived normalizer does not blind the column to real drift" do
      copy_view!()

      TestRepo.query!(
        "UPDATE #{@copy} SET email = 'someone.else@example.com' WHERE email IS NOT NULL",
        []
      )

      refute against_copy().agrees?
    end

    test "a row that exists only on the modern side lands inside a batch" do
      copy_view!()

      TestRepo.query!(
        "INSERT INTO #{@copy} (id, __legacy_id, login) VALUES (gen_random_uuid(), 999999999, 'ghost')",
        []
      )

      result = against_copy()

      assert result.counts.drift == -1
      assert [%{upper: 999_999_999}] = result.checksums.mismatched
    end

    test "a missing row is found by both counts and checksums" do
      copy_view!()

      TestRepo.query!(
        "DELETE FROM #{@copy} WHERE __legacy_id = (SELECT min(__legacy_id) FROM #{@copy})",
        []
      )

      result = against_copy()

      assert result.counts.drift == 1
      refute result.agrees?
      assert result.checksums.mismatched != []
    end
  end
end
