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

  ## The comparison is derived from the mapping, not transcribed beside it

      %{agrees?: true} = AshStrangler.Reconciler.diff(MyApp.Accounts.User)

  Everything that call needs is already declared. The legacy relation comes off
  the twin, the legacy key off the `key` entity, and each column's
  **legacy-side** expression is the same `AshStrangler.Lens` forward expression
  the compatibility view selects, printed by the same
  `AshStrangler.Sql.Printer`; its **view-side** expression is the attribute name.
  Both halves of the comparison come out of one declaration, so a mapping and
  the check on that mapping cannot disagree about what the mapping says.

  Transcribing `columns:` by hand instead has one specific failure mode, and it
  is the worst one available to a checker: **a column the list omits is not
  compared, and a comparison that skips a column reports agreement.** So the
  detector's blind spots were a function of how carefully somebody copied a
  mapping into a keyword list, nothing ever reported the omission, and the
  report that came back said `agrees?: true` either way.

  `diff/2` accepts either subject. An Ash resource and an `Ecto.Repo` are
  distinguishable — `Ash.Resource.Info.resource?/1` is a definite answer, not a
  guess — so one name serves both without a mode flag.

  ## The hand-passed form stays, and the reason it stays is unchanged

  `diff(repo, config)` takes the whole comparison as data:

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

  The operator who needs a drift check most is reconciling a table the model
  does not describe yet — a column added by hand during an incident, a
  half-migrated tenant, a pair of relations no resource has ever named. A
  checker that could only run against a compiled resource would make *that* the
  case needing a deploy. `diff(resource, opts)` is `plan/2` followed by this
  function and nothing else, so the derived path is a caller of the hand-passed
  one rather than a replacement for it.

  ## Normalization, and why it is derived rather than passed

  Ash normalises values on the way in. `Ash.Type.CiString` trims by default, so
  `" alice@example.com"` written *through Ash* is stored trimmed, while the
  identical value written by the legacy application is stored as given. Both
  are correct. Both are what their side is supposed to store. A comparison that
  does not know this reports every such row as drift, forever — and a drift
  report that is mostly false positives gets muted, which is how a team ends up
  with a drift detector and no drift detection.

  The attribute's own type already says which normalisation Ash performed, so
  that is where the normalizer comes from:

  | Attribute type | Derived | Because |
  |---|---|---|
  | `Ash.Type.CiString` | `:ci_string` — `lower(btrim(…))` | trims by default, and declares case not to be information |
  | `Ash.Type.CiString`, `trim?: false` | `:downcase` — `lower(…)` | keeps its whitespace, so trimming it away here would hide drift that is real |
  | `Ash.Type.String`, `trim?: true` | `:trim` — `btrim(…)` | Ash discards surrounding whitespace on write |
  | anything else | none | |

  That table is most of the argument for deriving it. Nobody hand-writes
  `:trim` against every string column of a wide resource, and every string
  column they miss is a permanent false positive on a report whose only defence
  against being ignored is that it is usually empty.

  Three properties of the hook are load-bearing:

    * **It is SQL, not Elixir.** The entire value of a checksum is that the
      comparison happens in the database over whole batches. A normalizer that
      forced rows into the BEAM would defeat the mechanism it is part of.

    * **It is applied to *both* sides.** Applying it only to the legacy side
      would assume Ash's normalisation is idempotent — usually true, never
      guaranteed. Applied to both, the comparison stops being "are these bytes
      equal" and becomes "are these values equal *modulo the transformation
      Ash performs*", which is the question actually being asked.

    * **The shorthands are named after the cause, not the effect.**
      `:ci_string` records *why* the column needs normalising — because the Ash
      attribute is an `Ash.Type.CiString` — where `"lower(btrim(…))"` would
      leave the next reader to reverse-engineer it.

  A hand-passed `normalize:` takes the same three shorthands, plus
  `fn expr -> "my_fn(\#{expr})" end` for a divergence none of them describes.
  An unrecognised value raises: ignoring it silently would compare the column
  un-normalised and fill the report with exactly the false positives the entry
  was written to prevent.

  ## A time zone is part of the expression, not a normalizer of its own

  Comparing a naive `timestamp` against a `timestamptz` compares a rendering
  artefact rather than two instants, and the fix used to be a third
  mini-language for one transform: `archived_at: {:sql, "%s AT TIME ZONE 'UTC'"}`
  alongside the view's own `AT TIME ZONE 'UTC'`, with nothing relating the two.
  Two spellings of one rule drift, and when this pair drifts the reconciler
  quietly reports drift that is not there — or, worse, agreement that is not
  there.

  `zone:` is part of the forward expression now, and the forward expression is
  what both sides of the comparison are printed from, so the zone is stated
  once and no template survives to disagree with it. There is no
  `{:sql, template}` normalizer.

  ## Two things the obvious implementation gets wrong

  **Both checksums must be computed in one statement.** Under `READ COMMITTED`
  each statement takes a fresh snapshot, so two separate `SELECT`s see two
  different states of the database and any concurrent write between them looks
  exactly like drift. A nightly job on a live table would report drift more or
  less at random. Both sides are therefore scalar subqueries of a single
  statement, which forces one snapshot. It is also what makes the derived path
  safe to aim at a read replica — `plan/2` asks for the resource's `:read`
  repo — since replication lag moves both sides of one snapshot together.

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
  """

  alias AshStrangler.{Constant, Info, Lens, Twin, Unmapped}
  alias AshStrangler.Sql.{Printer, View}

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

  Takes either a strangler-mapped resource — in which case the comparison is
  derived by `plan/2` and `opts` overrides parts of it — or a repo and a
  hand-written config. This is the entry point for the scheduled job and the
  test assertion alike; see the moduledoc on why there is only one.

  Checksums run even when the counts agree, because equal counts with unequal
  values is the interesting failure: a mapping that reads the wrong column
  keeps the row count perfect.
  """
  @spec diff(Ash.Resource.t() | module(), keyword()) :: drift()
  def diff(subject, opts \\ []) do
    {repo, config} = target!(subject, opts)

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
  @spec count_drift(Ash.Resource.t() | module(), keyword()) :: count_drift()
  def count_drift(subject, opts \\ []) do
    {repo, config} = target!(subject, opts)
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
  @spec checksum_drift(Ash.Resource.t() | module(), keyword()) :: checksum_drift()
  def checksum_drift(subject, opts \\ []) do
    {repo, config} = target!(subject, opts)
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

  # --- deriving the comparison from the resource -------------------------------

  @doc """
  The comparison for `resource`, as the config `diff/2` takes.

  Pure — it reads the DSL and touches no database — so it is also the thing to
  look at when a drift report is surprising: what got compared, on which
  expression, under which normalizer, is a value you can print.

      AshStrangler.Reconciler.plan(MyApp.Accounts.User)
      #=> [
      #     repo: MyApp.Repo,
      #     legacy: [relation: "legacy.users", key: "id"],
      #     view: [relation: "strangler.users", key: "__legacy_id"],
      #     columns: [
      #       login: {"login", "login"},
      #       email: {"(email)::citext", "email"},
      #       full_name: {"(coalesce(first_name, '') || (' ' || coalesce(last_name, '')))", "full_name"}
      #     ],
      #     normalize: %{login: :trim, email: :ci_string, full_name: :trim}
      #   ]

  Every value in `opts` replaces the derived one wholesale rather than merging
  into it, `normalize: %{}` included — an override is a statement that the
  derivation is wrong for this run, and a half-applied override would be a
  third thing that is neither.

  ## Which columns are compared

  Every attribute that has a mapping lens, in resource declaration order, minus
  three kinds that carry no information:

    * the **key**, whose two sides are the comparison's own join condition;
    * `constant`, whose value the view manufactures — both sides would render
      the same literal and agree by construction;
    * `unmapped`, which is a declaration that there is nothing on the legacy
      side to compare against.

  A `read_only?` mapping *is* compared. Being unable to write a value back has
  nothing to do with whether the value the view serves is right, and this is
  the column most likely to be wrong: `full_name` is the shape of mapping that
  gets its `coalesce` wrong and reports `"NULL Cruz"` to every consumer.

  ## Joins

  The legacy side is `AshStrangler.Sql.View.from_clause/1` — the view's own
  `FROM`, joins and all — rather than the bare relation, and the column
  expressions are printed in the view's own reference frame. A mapping that
  reads `expr(address.city)` therefore reconciles against the same rows the
  view projects. Assembling a bare `FROM legacy.users` instead would fail on
  the first qualified reference, which is the good outcome; deriving an
  unqualified frame to make it parse would compare a different query, which is
  not.
  """
  @spec plan(Ash.Resource.t(), keyword()) :: keyword()
  def plan(resource, opts \\ []) do
    source =
      Info.source(resource) ||
        raise ArgumentError, """
        #{inspect(resource)} has no strangler `source`, so there is nothing to reconcile it against.

        Pass the comparison explicitly if you are checking a pair of relations no
        resource describes:

            AshStrangler.Reconciler.diff(MyApp.Repo,
              legacy: [relation: "legacy.users", key: "id"],
              view: [relation: "strangler.users", key: "__legacy_id"],
              columns: [email: "email"]
            )
        """

    key =
      Info.key(resource) ||
        raise ArgumentError,
              "#{inspect(resource)}'s source declares no `key`, so the two sides cannot be lined up row by row"

    twin = source.twin
    frame = View.read_frame(resource)
    compared = compared_lenses(resource)

    derived = [
      # `:read`, not `:mutate`. A drift check writes nothing, and on a project
      # with a read replica it has no business occupying the primary. Replication
      # lag does not corrupt the answer, because both sides are read inside one
      # statement and therefore one snapshot.
      repo: AshPostgres.DataLayer.Info.repo(resource, :read),
      legacy: [relation: View.from_clause(resource), key: legacy_key(resource, twin, key)],
      view: [relation: view_relation!(resource), key: "__legacy_id"],
      columns: Enum.map(compared, &column(&1, frame)),
      normalize: normalizers(compared)
    ]

    Keyword.merge(derived, opts)
  end

  # `Twin.column!/2` rather than the printer's frame, which falls back to the
  # attribute name when the twin has no such column. That fallback is right for a
  # projected column -- the view is generated once and reviewed -- and wrong here,
  # where a stale twin would silently line the two sides up on a column that does
  # not exist and report every row as drift. This raises, naming the column and
  # the regeneration command.
  defp legacy_key(resource, twin, key) do
    column = Twin.column!(twin, key.from)

    case Info.joins(resource) do
      [] -> column
      _joins -> "#{Twin.table!(twin)}.#{column}"
    end
  end

  defp view_relation!(resource) do
    table =
      AshPostgres.DataLayer.Info.table(resource) ||
        raise ArgumentError,
              "#{inspect(resource)} has no `postgres do table \"...\" end`, so there is no relation to compare against"

    # `"public"` explicitly rather than by search_path, matching the name
    # `AshStrangler.Sql.View` creates the view under. A reconciler that resolved
    # the relation differently from the generator would be checking a relation
    # the generator did not make.
    "#{AshPostgres.DataLayer.Info.schema(resource) || "public"}.#{table}"
  end

  defp compared_lenses(resource) do
    lenses = Lens.by_attribute(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.flat_map(fn attribute ->
      case Map.fetch(lenses, attribute.name) do
        {:ok, lens} -> if comparable?(lens), do: [{attribute, lens}], else: []
        :error -> []
      end
    end)
  end

  defp comparable?(%Lens{entry: %Constant{}}), do: false
  defp comparable?(%Lens{entry: %Unmapped{}}), do: false
  defp comparable?(%Lens{combinator: :key}), do: false
  defp comparable?(%Lens{forward: nil}), do: false
  defp comparable?(%Lens{}), do: true

  # The legacy side is the lens's forward expression through the view's frame --
  # literally the SQL in the view's SELECT list -- and the view side is the
  # attribute name. One declaration, both halves.
  defp column({attribute, lens}, frame) do
    {attribute.name, {Printer.to_sql(lens.forward, ref: frame), to_string(attribute.name)}}
  end

  defp normalizers(compared) do
    for {attribute, _lens} <- compared,
        normalizer = derived_normalizer(attribute),
        into: %{},
        do: {attribute.name, normalizer}
  end

  # Ash's own defaults, read off the attribute. `trim?` defaults to true on both
  # string types, so an attribute that says nothing about trimming is still
  # trimming -- and a derivation that read a missing constraint as "no
  # normalisation" would restore the false positives this exists to remove.
  defp derived_normalizer(%{type: type, constraints: constraints}) do
    case Ash.Type.get_type(type) do
      Ash.Type.CiString -> if trim?(constraints), do: :ci_string, else: :downcase
      Ash.Type.String -> if trim?(constraints), do: :trim, else: nil
      _other -> nil
    end
  rescue
    _ -> nil
  end

  defp trim?(constraints), do: Keyword.get(constraints || [], :trim?, true)

  # --- one name, two subjects --------------------------------------------------

  defp target!(subject, opts) do
    if Ash.Resource.Info.resource?(subject) do
      config = plan(subject, opts)
      {Keyword.fetch!(config, :repo), config}
    else
      {subject, hand_passed!(subject, opts)}
    end
  end

  defp hand_passed!(subject, opts) do
    if Keyword.has_key?(opts, :legacy) do
      opts
    else
      raise ArgumentError, """
      #{inspect(subject)} is not an Ash resource, so it was read as a repo -- and a repo
      needs the comparison passed with it:

          AshStrangler.Reconciler.diff(#{inspect(subject)},
            legacy: [relation: "legacy.users", key: "id"],
            view: [relation: "strangler.users", key: "__legacy_id"],
            columns: [email: "email"]
          )

      To have the comparison derived instead, pass the resource:

          AshStrangler.Reconciler.diff(MyApp.Accounts.User)
      """
    end
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

      :downcase ->
        template("lower(%s)")

      :trim ->
        template("btrim(%s)")

      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError, "unsupported normalizer for #{inspect(name)}: #{inspect(other)}"
    end
  end

  defp template(sql), do: fn expression -> String.replace(sql, "%s", "(#{expression})") end
end
