# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Reconciler do
  @moduledoc """
  Drift detection between two relations that are supposed to hold the same
  rows — a legacy table and the compatibility view over it, or the legacy table
  and the new table during dual-write.

  Row counts first, then per-batch checksums over the mapped columns, so a
  disagreement comes back as a key range a human can go and look at rather than
  as a single boolean.

  ## The same function is the scheduled job and the test assertion

  `diff/2` returns structured data and logs nothing. The Oban job that runs
  nightly and the test that asserts a mapping is faithful call the identical
  function and read the identical map. That is not tidiness: the drift check
  *is* the correctness oracle for this package, so if the production checker
  and the test checker are different code, the tests certify something nobody
  is running.

  Which raises the obvious question — who checks the checker? See
  `test/ash_strangler/reconciler_test.exs`: every mutation it can detect is
  proven by deliberately introducing that mutation and asserting it is found.
  A drift detector nobody has proven can detect drift is worse than no drift
  detector, because it manufactures confidence.

  ## Normalization, and why it is not optional

  Ash normalises values on the way in. `Ash.Type.CiString` trims by default, so
  `" alice@example.com"` written *through Ash* is stored trimmed, while the
  identical value written by the legacy application is stored as given. Both
  are correct. Both are what their side is supposed to store. A comparison that
  does not know this reports every such row as drift, forever — and a drift
  report that is mostly false positives gets muted, which is how a team ends up
  with a drift detector and no drift detection.

  So each column may carry a normalizer, and the design decisions in it are:

    * **It is SQL, not Elixir.** The entire value of a checksum is that the
      comparison happens in the database over whole batches. A normalizer that
      forced rows into the BEAM would defeat the mechanism it is part of.

    * **It is applied to *both* sides.** Applying it only to the legacy side
      would assume Ash's normalisation is idempotent — usually true, never
      guaranteed. Applied to both, the comparison stops being "are these bytes
      equal" and becomes "are these values equal *modulo the transformation
      Ash performs*", which is the question actually being asked.

    * **The shorthands are named after the cause, not the effect.**
      `normalize: %{email: :ci_string}` records *why* the column needs
      normalising — because the Ash attribute is an `Ash.Type.CiString` — where
      `"lower(btrim(%s))"` would leave the next reader to reverse-engineer it.

  Supported forms:

      normalize: %{
        email:        :ci_string,             # lower(btrim(...)) — trim? and case-insensitivity
        login:        :trim,                  # btrim(...)
        archived_at:  {:sql, "%s AT TIME ZONE 'UTC'"},
        weird:        fn expr -> "my_fn(\#{expr})" end
      }

  `{:sql, template}` substitutes the column expression for each `%s`. The
  `:archived_at` example is the second real case: a naive `timestamp` and a
  `timestamptz` render differently as text, so comparing them without stating
  the zone compares a rendering artefact.

  ## Two things the obvious implementation gets wrong

  **Both checksums must be computed in one statement.** Under `READ COMMITTED`
  each statement takes a fresh snapshot, so two separate `SELECT`s see two
  different states of the database and any concurrent write between them looks
  exactly like drift. A nightly job on a live table would report drift more or
  less at random. Both sides are therefore scalar subqueries of a single
  statement, which forces one snapshot.

  **The per-row encoding has to be injective, and the obvious one is not.**
  `concat_ws('|', a, b)` *skips* nulls rather than encoding them, so it moves a
  column boundary: `(NULL, 'a|b')` and `('a', 'b')` both render as `a|b`, and a
  row that lost a value to NULL is reported as agreeing with one that did not.
  (Checked, on 17.10 — `concat_ws` does distinguish `NULL` from `''` when
  neither is at a boundary, which makes this the more dangerous kind of bug:
  it is right in the case you would test by hand.) Every value is therefore
  wrapped in `quote_nullable`, which renders `NULL` as the bare word `NULL` and
  everything else as a quoted, escaped literal, so nothing in a value can
  imitate a separator and nothing can be omitted.

  ## Usage

      config = [
        legacy: [relation: "legacy.users", key: "id"],
        view: [relation: "strangler.users", key: "__legacy_id"],
        columns: [
          email: "email",
          full_name: {"coalesce(first_name,'') || ' ' || coalesce(last_name,'')", "full_name"}
        ],
        normalize: %{email: :ci_string}
      ]

      %{agrees?: true} = AshStrangler.Reconciler.diff(MyApp.Repo, config)
  """

  @batch_size 1_000

  @typedoc "Row counts on each side. `drift` is `legacy - view`, signed."
  @type count_drift :: %{
          agrees?: boolean(),
          legacy: non_neg_integer(),
          view: non_neg_integer(),
          drift: integer()
        }

  @typedoc """
  One key range and the two checksums over it. `rows` is how many distinct keys
  the range covers across *both* sides, so a row present on only one of them
  still counts.
  """
  @type batch :: %{
          agrees?: boolean(),
          lower: term(),
          upper: term(),
          rows: non_neg_integer(),
          legacy: String.t(),
          view: String.t()
        }

  @typedoc "`mismatched` is the sublist of `batches` that disagreed — the thing to go and look at."
  @type checksum_drift :: %{
          agrees?: boolean(),
          batches: [batch()],
          mismatched: [batch()],
          columns: [atom()]
        }

  @typedoc false
  @type drift :: %{
          agrees?: boolean(),
          counts: count_drift(),
          checksums: checksum_drift()
        }

  @doc """
  Counts and checksums, in that order, as one map.

  This is the entry point for both the scheduled job and the test assertion —
  see the moduledoc on why there is only one.

  Checksums run even when the counts agree, because equal counts with unequal
  values is the interesting failure: a mapping that reads the wrong column
  keeps the row count perfect.
  """
  @spec diff(module(), keyword()) :: drift()
  def diff(repo, config) do
    counts = count_drift(repo, config)
    checksums = checksum_drift(repo, config)

    %{
      agrees?: counts.agrees? and checksums.agrees?,
      counts: counts,
      checksums: checksums
    }
  end

  @doc """
  Row counts on both sides.

  Cheap, and the first thing worth knowing. Both counts come from a single
  statement so they share a snapshot — see the moduledoc.
  """
  @spec count_drift(module(), keyword()) :: count_drift()
  def count_drift(repo, config) do
    config = normalize!(config)

    %Postgrex.Result{rows: [[legacy, view]]} =
      repo.query!(
        """
        SELECT
          (SELECT count(*) FROM #{config.legacy.relation}),
          (SELECT count(*) FROM #{config.view.relation})
        """,
        []
      )

    %{agrees?: legacy == view, legacy: legacy, view: view, drift: legacy - view}
  end

  @doc """
  Batched checksums over the mapped columns.

  Walks the key space in `:batch_size` ranges and md5s the ordered, mapped
  columns on each side of each range. Returns every batch plus the sublist that
  disagreed, so the answer to "where is the drift" is a key range rather than
  "somewhere in forty million rows".
  """
  @spec checksum_drift(module(), keyword()) :: checksum_drift()
  def checksum_drift(repo, config) do
    config = normalize!(config)
    batches = walk(repo, config, first_key(repo, config), ">=", [])
    mismatched = Enum.reject(batches, & &1.agrees?)

    %{
      agrees?: mismatched == [],
      batches: batches,
      mismatched: mismatched,
      columns: Enum.map(config.columns, & &1.name)
    }
  end

  # --- walking the key space ---------------------------------------------------

  defp walk(_repo, _config, nil, _op, acc), do: Enum.reverse(acc)

  defp walk(repo, config, cursor, op, acc) do
    case bounds(repo, config, cursor, op) do
      {nil, nil, 0} ->
        Enum.reverse(acc)

      {lower, upper, rows} ->
        batch = checksum_batch(repo, config, lower, upper, rows)
        walk(repo, config, upper, ">", [batch | acc])
    end
  end

  # The boundaries of the next batch, taken from the UNION of both sides' keys.
  #
  # Batching off the legacy side alone is the obvious implementation and it is
  # unsound: a key that exists only in the view falls outside every range, so
  # the checksum pass reports agreement for a row it never looked at. The union
  # costs one more index scan and closes that hole.
  defp bounds(repo, config, cursor, op) do
    sql = """
    WITH strangler_keys AS (
      SELECT #{config.legacy.key} AS k FROM #{config.legacy.relation}
      WHERE #{config.legacy.key} #{op} $1
      UNION
      SELECT #{config.view.key} AS k FROM #{config.view.relation}
      WHERE #{config.view.key} #{op} $1
    )
    SELECT min(k), max(k), count(*)
    FROM (SELECT k FROM strangler_keys ORDER BY k LIMIT #{config.batch_size}) strangler_page
    """

    %Postgrex.Result{rows: [[lower, upper, rows]]} = repo.query!(sql, [cursor])

    {lower, upper, rows}
  end

  defp first_key(repo, config) do
    %Postgrex.Result{rows: [[key]]} =
      repo.query!(
        """
        SELECT least(
          (SELECT min(#{config.legacy.key}) FROM #{config.legacy.relation}),
          (SELECT min(#{config.view.key}) FROM #{config.view.relation})
        )
        """,
        []
      )

    key
  end

  # Both checksums, one statement, one snapshot. See the moduledoc.
  #
  # `$1`/`$2` are the batch bounds and are shared by both subqueries, which is
  # also why the bounds are bound parameters rather than interpolated: the two
  # sides must be given literally the same range, not two renderings of it.
  defp checksum_batch(repo, config, lower, upper, rows) do
    sql = """
    SELECT
      (#{checksum_query(config.columns, config.legacy, :legacy)}),
      (#{checksum_query(config.columns, config.view, :view)})
    """

    %Postgrex.Result{rows: [[legacy, view]]} = repo.query!(sql, [lower, upper])

    %{
      agrees?: legacy == view,
      lower: lower,
      upper: upper,
      rows: rows,
      legacy: legacy,
      view: view
    }
  end

  defp checksum_query(columns, side, which) do
    row = Enum.map_join(columns, ", ", &"quote_nullable((#{expression(&1, which)})::text)")

    # ORDER BY inside string_agg, not outside: without it the aggregation order
    # is whatever the scan produced, so an UPDATE that moved one row to the end
    # of the heap on one side changes that side's checksum and nothing else.
    # The drift would be real-looking, reproducible, and entirely fictional.
    """
    SELECT coalesce(
             md5(string_agg(concat_ws('|', #{row}), E'\\n' ORDER BY #{side.key})),
             ''
           )
    FROM #{side.relation}
    WHERE #{side.key} BETWEEN $1 AND $2
    """
  end

  defp expression(column, which) do
    expr = Map.fetch!(column, which)

    case column.normalize do
      nil -> expr
      normalizer -> normalizer.(expr)
    end
  end

  # --- configuration -----------------------------------------------------------

  defp normalize!(config) do
    normalizers = Keyword.get(config, :normalize, %{})

    %{
      legacy: side!(config, :legacy),
      view: side!(config, :view),
      columns: columns!(Keyword.fetch!(config, :columns), normalizers),
      batch_size: Keyword.get(config, :batch_size, @batch_size)
    }
  end

  defp side!(config, which) do
    side = Keyword.fetch!(config, which)

    %{
      relation: Keyword.fetch!(side, :relation),
      key: Keyword.fetch!(side, :key)
    }
  end

  # `name: "col"` when both sides spell it the same, `name: {legacy, view}` when
  # they do not. Both values are SQL *expressions*, not identifiers: the whole
  # reason a legacy column needs reconciling is often that it is
  # `coalesce(first_name,'') || ' ' || coalesce(last_name,'')` on one side and a
  # single column on the other.
  defp columns!(columns, normalizers) do
    Enum.map(columns, fn
      {name, {legacy, view}} ->
        %{name: name, legacy: legacy, view: view, normalize: normalizer!(normalizers, name)}

      {name, expression} when is_binary(expression) ->
        %{
          name: name,
          legacy: expression,
          view: expression,
          normalize: normalizer!(normalizers, name)
        }
    end)
  end

  defp normalizer!(normalizers, name) do
    case Map.get(normalizers, name) do
      nil ->
        nil

      :ci_string ->
        template("lower(btrim(%s))")

      :trim ->
        template("btrim(%s)")

      {:sql, sql} ->
        template(sql)

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError, "unsupported normalizer for #{inspect(name)}: #{inspect(other)}"
    end
  end

  defp template(sql), do: fn expression -> String.replace(sql, "%s", "(#{expression})") end
end
