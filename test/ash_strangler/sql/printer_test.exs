# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.PrinterTest do
  @moduledoc """
  The printer is the one module in this package where a bug is a security bug.

  `AshSql` parameterises every literal and **DDL cannot be parameterised**, so
  `AshStrangler.Sql.Printer.literal/1` builds SQL literals by hand. It is the only
  function in the package that does. Get it wrong once and the result is an
  injection in DDL generated at compile time out of a `strangler` block — a place
  nobody thinks to audit, in a statement run by a migration with enough privilege
  to `CREATE VIEW` and `CREATE TRIGGER`.

  A suite that compared `literal/1` against a second Elixir implementation of the
  same escaping would prove only that two functions written by the same author on
  the same afternoon agree. So the escaping is tested against **PostgreSQL itself as
  a differential oracle**: the printed literal is executed, the same value is sent
  as a bound parameter, and the two results are compared. Postgrex's parameter
  encoding is an independent code path that shares no escaping with this module,
  which is what makes the agreement evidence rather than a tautology.

  The same technique is applied one level up. `Printer.inline_literals/1` exists so
  an expression can be handed to `AshSql.Expr.dynamic_expr/6` with zero bound
  parameters, and `describe "the AshSql differential oracle"` renders each
  expression twice — once by this printer, once by the renderer that actually ships
  inside `ash_postgres` — then compares **the rows PostgreSQL returns** rather than
  the strings. Comparing strings would have been wrong, not merely weaker: the two
  renderers disagree textually on purpose. `expr(id in [1, 2, 3])` is `IN (1, 2, 3)`
  here and `= ANY(ARRAY[…])` there, and both are correct. A test that has to be
  relaxed until it passes has stopped being an oracle.

  Everything executable is executed. A generator that agrees with itself and emits
  SQL PostgreSQL rejects has failed at the only thing it is for.
  """

  use AshStrangler.DataCase, async: false
  use ExUnitProperties

  require Ecto.Query

  import Ash.Expr

  alias AshStrangler.Lens
  alias AshStrangler.Sql.Printer
  alias AshStrangler.Test.Generators
  alias AshStrangler.Test.Legacy.Users, as: LegacyUsers

  doctest AshStrangler.Sql.Printer

  @forward expr((first_name || "") <> " " <> (last_name || ""))

  # One row with a value in every column these tests read, and one row that is NULL
  # in all of them. Two rather than one because most of the ways an expression can
  # be wrong are ways it can be wrong about NULL, and a fixture with no NULL in it
  # cannot see any of them.
  setup do
    TestRepo.query!(
      """
      INSERT INTO legacy.users (login, email, first_name, last_name, state, deleted_at)
      VALUES ('printer-populated', 'Alice@Example.COM', 'O''Brien', 'de la Cruz',
              'suspended', '2024-03-10 02:30:00'),
             ('printer-null', NULL, NULL, NULL, 'active', NULL)
      """,
      []
    )

    :ok
  end

  # --- the literal oracle ------------------------------------------------------

  describe "literal/1, against PostgreSQL as a differential oracle" do
    property "a printed literal and the same value bound as a parameter are the same value" do
      check all(value <- literal_value(), max_runs: 300) do
        assert_agrees!(value)
      end
    end

    property "a printed text literal survives standard_conforming_strings being off" do
      # The claim `literal/1`'s docstring makes, measured rather than asserted. A
      # legacy database is exactly the kind of database with this turned off, and
      # with it off a backslash inside a plain `'…'` becomes an escape introducer:
      # `'a\\nb'` is three characters and a newline rather than four characters. The
      # `E'…'` form is what makes the rendering mean the same thing either way, and
      # this is the only test that can tell.
      #
      # `SET LOCAL`, so the sandbox transaction's rollback restores it rather than a
      # cleanup step a failing assertion can skip.
      TestRepo.query!("SET LOCAL standard_conforming_strings = off", [])

      check all(value <- sql_hostile_text(), max_runs: 200) do
        assert_agrees!(value)
      end
    end

    test "the adversarial strings that break naive escaping round-trip exactly" do
      # Enumerated as well as generated. The property will find these eventually;
      # naming them means a regression reports *which* shape broke rather than a
      # shrunk string somebody has to interpret.
      for value <- [
            "'",
            "''",
            "'''",
            "\\",
            "\\\\",
            "\\'",
            "'\\",
            "E'x'",
            "e'x'",
            "U&'\\0041'",
            "$$x$$",
            "';DROP TABLE legacy.users;--",
            "' OR '1'='1",
            "--",
            "/*",
            "*/",
            "/* ' */",
            ";",
            "?",
            "$1",
            "%s",
            "",
            "\n",
            "\r\n",
            "\t",
            "\\\n",
            # NFC and NFD of the same visible string, written as escapes for the
            # reason `Generators` gives: spelled literally they are two source lines
            # that look identical, with no way for a reader to tell which is which.
            "caf\u00E9",
            "cafe\u0301",
            "\u{1F600}",
            # Escaped because Elixir's trojan-source defence rejects a raw
            # bidirectional override in source at all — which is itself the reason
            # this value is worth a case: it is a string that renders as something
            # other than its bytes.
            "\u202Etext\u202C"
          ] do
        assert_agrees!(value)
      end
    end

    test "a NUL byte is refused, because PostgreSQL cannot store one in text at all" do
      # Not a style preference. `text` rejects NUL, so there is no encoding of it —
      # `\\0`, `\\x00`, `chr(0)` — that describes a value the database will hold.
      # Escaping it would produce DDL that either fails during a migration or, worse,
      # stores something else. Refusing at the printer puts the error next to the
      # declaration that caused it.
      assert_raise ArgumentError, ~r/cannot contain a NUL byte/, fn ->
        Printer.literal("before" <> <<0>> <> "after")
      end

      # The other half of that argument, measured here rather than quoted from
      # documentation: PostgreSQL's own refusal of the same byte.
      assert_raise Postgrex.Error, ~r/0x00/, fn ->
        TestRepo.query!("SELECT ($1)::text", ["before" <> <<0>> <> "after"])
      end
    end

    test "a value with no SQL literal form is refused rather than inspected into SQL" do
      # The catch-all clause matters more than it looks. `inspect/1` of a pid or a
      # map produces text that parses as SQL often enough to be dangerous and is
      # never the value that was meant.
      assert_raise ArgumentError, ~r/cannot be rendered as a SQL literal/, fn ->
        Printer.literal(%{a: 1})
      end

      assert_raise ArgumentError, ~r/cannot be rendered as a SQL literal/, fn ->
        Printer.literal(self())
      end
    end

    test "a list renders as an array whose elements are each escaped" do
      # The recursive case, which is where an escaping function usually loses its
      # nerve. Executed rather than string-compared, so the assertion is about the
      # array PostgreSQL builds.
      %{rows: [[array]]} =
        TestRepo.query!("SELECT #{Printer.literal(["O'Brien", "back\\slash", ""])}", [])

      assert array == ["O'Brien", "back\\slash", ""]
    end
  end

  describe "pg_type!/1" do
    test "asks Ash for the storage type rather than keeping a table that could disagree" do
      assert Printer.pg_type!(:ci_string) == "citext"
      assert Printer.pg_type!(:string) == "text"
      assert Printer.pg_type!(:utc_datetime_usec) == "timestamptz"
      assert Printer.pg_type!({:array, :uuid}) == "uuid[]"
    end

    test "a bare string passes through, so a Postgres type Ash has never heard of still works" do
      assert Printer.pg_type!("hstore") == "hstore"
      assert Printer.pg_type!("tsvector") == "tsvector"
    end

    test "every type it names is one PostgreSQL will accept in a cast" do
      # The table is a restatement of AshPostgres's private `migration_type/2`, and a
      # restatement's failure mode is drifting from what it restates. This is the
      # check that cannot drift, because each name is put in front of the server.
      for ash_type <- [
            :ci_string,
            :string,
            :atom,
            :uuid,
            :integer,
            :float,
            :decimal,
            :boolean,
            :date,
            :time,
            :naive_datetime,
            :utc_datetime,
            :utc_datetime_usec,
            :map,
            :binary
          ] do
        pg_type = Printer.pg_type!(ash_type)

        assert %Postgrex.Result{} = TestRepo.query!("SELECT NULL::#{pg_type}", []),
               "#{inspect(ash_type)} rendered as #{pg_type}, which PostgreSQL rejected"
      end
    end
  end

  # --- reference frames --------------------------------------------------------

  describe "the reference frame is a parameter, which is the point of the module" do
    # One forward expression, four renderings. This is why the printer is not
    # `Ecto.Adapters.SQL.to_sql/4`: Ecto knows exactly one frame (`s0."deleted_at"`)
    # and no option changes that, while a mapping has to render against legacy
    # columns for the view, against a qualified alias under a join, against `NEW.*`
    # inside a trigger, and against the modern table for the reverse view. Three of
    # those four produce SQL that runs and is wrong when used in the wrong place,
    # which is why the frame is required rather than defaulted.

    test "bare_frame/0 renders column names alone, for the index and the reverse view" do
      assert Printer.to_sql(@forward, ref: Printer.bare_frame()) ==
               "(coalesce(first_name, '') || (' ' || coalesce(last_name, '')))"
    end

    test "bare_frame/1 resolves an attribute to the twin's real column name" do
      # A twin's `source:` option is where a column Elixir would not want as an atom
      # lives, so the frame reads it rather than assuming attribute name and column
      # name are the same word.
      assert Printer.to_sql(expr(nick), ref: Printer.bare_frame(diagram_twin())) == "nick"
    end

    test "qualified_frame/2 qualifies the primary relation with the alias it was given" do
      assert Printer.to_sql(@forward, ref: Printer.qualified_frame(LegacyUsers, "users")) ==
               "(coalesce(users.first_name, '') || (' ' || coalesce(users.last_name, '')))"
    end

    test "qualified_frame/2 qualifies a joined reference with the relationship, not the alias" do
      # `expr(address.city)` reads a column that is not on the primary relation at
      # all, and the frame is the only thing that knows so. Qualifying it with the
      # primary alias would produce SQL that runs and reads the wrong table whenever
      # a column of that name exists on both.
      assert Printer.to_sql(expr(address.city),
               ref: Printer.qualified_frame(diagram_twin(), "accounts")
             ) == "address.city"
    end

    test "new_frame/0 renders references as NEW.*, which is what the trigger side needs" do
      # References in a write expression name *resource attributes* of the incoming
      # view row rather than legacy columns, and this frame is what says so. It
      # replaces the deleted `String.replace(to, "$NEW.", "NEW.")` and the `$NEW.`
      # sigil the DSL used to make authors type.
      assert Printer.to_sql(expr(archived_at), ref: Printer.new_frame()) == "NEW.archived_at"
    end

    test "the frame is required rather than defaulted" do
      assert_raise ArgumentError, ~r/requires a `:ref` frame/, fn ->
        Printer.to_sql(@forward, [])
      end
    end
  end

  describe "the :touch mode" do
    # `touch()` is the one declared `PutPut` violation in the design, and it renders
    # differently on the two write paths because the two paths genuinely know
    # different things. Read off the real `collapse` in `AshStrangler.Demo.Customer`
    # rather than a hand-built node, so a change in how the DSL stores `touch()`
    # fails here instead of leaving this passing against a shape nothing produces.
    setup do
      writes = Lens.by_attribute(AshStrangler.Demo.Customer)[:status].writes
      %{cancelled_at: Keyword.fetch!(writes, :cancelled_at), writes: writes}
    end

    test "an INSERT has no prior row, so touch() is now()", %{cancelled_at: write} do
      sql = Printer.to_sql(write, ref: Printer.new_frame(), touch: :now)

      assert sql =~ "now()"
      refute sql =~ "IS DISTINCT FROM"
    end

    test "an UPDATE preserves the stored value unless the state actually changed", %{
      cancelled_at: write
    } do
      # The alternative — always `now()` — silently rewrites the timestamp of every
      # row a write touched for any reason, including a write that never mentioned
      # the lifecycle. Same shape as the 0.1 `state_code` bug: no symptom until
      # somebody audits the timestamps, by which point the original instants are
      # gone.
      sql =
        Printer.to_sql(write, ref: Printer.new_frame(), touch: {:preserve, Printer.bare_frame()})

      assert sql =~
               "CASE WHEN status IS DISTINCT FROM NEW.status THEN now() ELSE cancelled_at END"
    end

    test "one write expression carries two reference frames at once", %{cancelled_at: write} do
      # The asymmetry is load-bearing rather than incidental. Every reference in a
      # write expression is a *resource attribute* and renders `NEW.<attribute>` —
      # except the column inside a `touch()`, which is the legacy column's previously
      # stored value, and on the right-hand side of `UPDATE ... SET` that is the bare
      # column name.
      #
      # Rendered through `ctx.ref` like everything else it came out `NEW.cancelled_at`,
      # naming a column the *view* does not have, and the generated plpgsql would not
      # have compiled. So the frame cannot be a parameter of the whole render, and
      # `AshStrangler.Lens.collapse_value/4` carries that one reference as a name.
      sql =
        Printer.to_sql(write, ref: Printer.new_frame(), touch: {:preserve, Printer.bare_frame()})

      assert sql =~ "NEW.status"
      assert sql =~ "ELSE cancelled_at END"
      refute sql =~ "NEW.cancelled_at"
    end

    test "both renderings are SQL PostgreSQL accepts", %{writes: writes} do
      # A trigger body is compiled by PL/pgSQL at `CREATE FUNCTION` time, so a syntax
      # error in either rendering surfaces during a migration rather than during a
      # test run. Asking the parser directly is cheaper than generating the trigger.
      #
      # Three reference kinds appear in one statement and each needs a source: `NEW.*`
      # for the incoming attributes, the preserve frame for the prior attribute value,
      # and the *unqualified* legacy columns the `touch()` reads. The middle one is
      # qualified `old.` only because PostgreSQL cannot resolve two unqualified `status`
      # columns coming from two relations; the legacy columns stay bare, which is the
      # shape under test.
      old_frame = fn {_path, attribute} -> "old.#{attribute}" end

      for {_column, write} <- writes,
          touch <- [:now, {:preserve, old_frame}] do
        sql = Printer.to_sql(write, ref: Printer.new_frame(), touch: touch)

        assert %Postgrex.Result{} =
                 TestRepo.query!(
                   """
                   SELECT #{sql}
                   FROM (SELECT NULL::boolean AS is_deleted,
                                NULL::timestamp AS cancelled_at,
                                NULL::timestamp AS approved_at) AS legacy_row,
                        (SELECT 'pending'::text AS status) AS new,
                        (SELECT 'pending'::text AS status) AS old
                   """,
                   []
                 ),
               "#{sql} was rejected by PostgreSQL"
      end
    end
  end

  # --- the closed node set -----------------------------------------------------

  describe "the closed node set renders, and runs" do
    test "every renderable node produces SQL PostgreSQL executes" do
      for {expression, description} <- executable_expressions() do
        sql = Printer.to_sql(expression, ref: Printer.bare_frame(LegacyUsers))

        assert %Postgrex.Result{} =
                 TestRepo.query!("SELECT #{sql} FROM legacy.users ORDER BY id", []),
               "#{description} rendered as #{sql}, which PostgreSQL rejected"
      end
    end

    test "Ash's `<>` becomes SQL's `||` and Ash's `||` becomes SQL's coalesce" do
      # The two symbols mean the other thing in the two languages, which makes this
      # the likeliest place in the module for a silent inversion: both renderings
      # parse, both run, and the wrong one produces NULL where the mapping promised a
      # string. Asserted on the value for that reason, not on the SQL.
      assert selected!(expr(first_name <> last_name), "printer-populated") == "O'Briende la Cruz"
      assert selected!(expr(first_name || "fallback"), "printer-null") == "fallback"
      assert selected!(expr(first_name <> "!"), "printer-null") == nil
    end

    test "a comparison against nil becomes IS NULL rather than = NULL" do
      # `x = NULL` is not false, it is NULL — so a `WHERE` built on it matches
      # nothing and a `CASE` built on it takes the `ELSE` branch. Both are wrong
      # answers that run.
      assert Printer.to_sql(nil_comparison(:==, :email), ref: Printer.bare_frame()) ==
               "(email IS NULL)"

      assert Printer.to_sql(nil_comparison(:!=, :email), ref: Printer.bare_frame()) ==
               "(email IS NOT NULL)"

      assert selected!(nil_comparison(:==, :email), "printer-null") == true
      assert selected!(nil_comparison(:==, :email), "printer-populated") == false
    end

    test "`in` renders a parenthesised list, not an array" do
      # `x IN ARRAY[1, 2]` is a type error, and the fix is not `= ANY`: that renders
      # differently, so the index expression and the query expression would become
      # two spellings of one thing — which is the drift this module exists to stop.
      assert Printer.to_sql(expr(id in [1, 2, 3]), ref: Printer.bare_frame()) ==
               "(id IN (1, 2, 3))"
    end

    test "`cond`'s final `true ->` arm collapses into a plain ELSE" do
      # `expr/1` desugars `cond` into nested `if`s, so the last arm arrives as
      # `if true, do: …`. Rendered literally that becomes a trailing
      # `ELSE (CASE WHEN TRUE THEN 'other' END)`: correct SQL, and unreadable inside
      # a view definition somebody has to review before it goes near production.
      expression =
        expr(
          cond do
            state == :deleted -> "gone"
            state == :active -> "here"
            true -> "other"
          end
        )

      sql = Printer.to_sql(expression, ref: Printer.bare_frame())

      assert sql ==
               "(CASE WHEN (state = 'deleted') THEN 'gone' " <>
                 "ELSE (CASE WHEN (state = 'active') THEN 'here' ELSE 'other' END) END)"

      refute sql =~ "WHEN TRUE"
      assert selected!(expression, "printer-populated") == "other"
      assert selected!(expression, "printer-null") == "here"
    end

    test "`zone:` renders AT TIME ZONE and never a bare cast" do
      # A bare `::timestamptz` on a naive column reads it as wall-clock time in the
      # *session's* TimeZone, so two connections reading the same row disagree — the
      # printer's own comment records how far. The second reason is the testable one:
      # `timezone(text, timestamp)` is IMMUTABLE where the one-argument form a bare
      # cast resolves to is STABLE, and only an IMMUTABLE expression can carry an
      # index.
      forward = Lens.by_attribute(AshStrangler.Test.LegacyUser)[:archived_at].forward
      sql = Printer.to_sql(forward, ref: Printer.bare_frame(LegacyUsers))

      assert sql == "(deleted_at AT TIME ZONE 'UTC')"

      # The fixture's value is deliberately the instant that does not exist in
      # `America/New_York`, which PostgreSQL resolves silently rather than raising.
      # Read as UTC there is nothing to resolve, which is the point.
      assert selected!(forward, "printer-populated") == ~U[2024-03-10 02:30:00.000000Z]

      # And the IMMUTABLE claim, which can only be checked by building the index.
      assert %Postgrex.Result{} =
               TestRepo.query!("CREATE INDEX printer_zone_idx ON legacy.users ((#{sql}))", [])
    end

    test "a decode renders as one flat CASE, with no ELSE, deliberately" do
      # A fold over the table into nested `if`s renders correctly and is unreadable:
      # five values produce five levels of `CASE WHEN … ELSE (CASE …)`, and a
      # compatibility view is reviewed by people far more often than a migration is.
      #
      # The missing `ELSE` is the more important half. 0.1 wrote
      # `CASE state WHEN 'active' THEN 0 ELSE 1 END`, and that catch-all is exactly how
      # `passive`, `pending` and `deleted` came to be rewritten to `suspended` by a
      # write that never mentioned the lifecycle. Here an unlisted value yields NULL —
      # a visible absence — and `GetTotal` refuses a table that does not cover the
      # column's declared value set in the first place.
      forward = Lens.by_attribute(AshStrangler.Test.DualWriteUser)[:state_code].forward
      sql = Printer.to_sql(forward, ref: Printer.bare_frame(LegacyUsers))

      refute sql =~ "ELSE"
      # One `CASE`, not five nested ones — which is what "flat" means and the whole
      # reason the node exists rather than folding into `if`s.
      assert sql |> String.split("CASE") |> length() == 2

      # And the obligation, measured in SQL rather than argued: every value the legacy
      # column actually ranges over maps to a code, and none of them to NULL.
      %Postgrex.Result{rows: rows} =
        TestRepo.query!(
          "SELECT #{sql} FROM (SELECT unnest($1::text[]) AS state) AS legacy_row",
          [legacy_states()]
        )

      assert rows |> Enum.map(&hd/1) |> Enum.sort() == [0, 1, 2, 3, 4]
    end

    test "`not is_nil(x)` collapses to IS NOT NULL, which is what a collapse guard is made of" do
      assert Printer.to_sql(expr(not is_nil(deleted_at)), ref: Printer.bare_frame()) ==
               "(deleted_at IS NOT NULL)"

      # Not a general rewrite of `NOT`, which would be a second way to say the same
      # thing: only the one composition common enough in a `collapse` to be worth
      # naming.
      assert Printer.to_sql(expr(not (id > 0)), ref: Printer.bare_frame()) == "(NOT (id > 0))"
    end

    test "now() and today() render as server-side functions, never as a frozen value" do
      # The one place a *query* renderer and a *DDL* renderer must disagree. Evaluating
      # either in the BEAM freezes one instant into the view definition, so every
      # legacy row reads the moment the migration was generated — a wrong answer that
      # looks like a right one, and one nothing later notices. It is the same refusal
      # `AshStrangler.Lens.default_expression!/2` makes for a function-valued default.
      assert Printer.to_sql(expr(now()), ref: Printer.bare_frame()) == "now()"
      assert Printer.to_sql(expr(today()), ref: Printer.bare_frame()) == "current_date"

      assert %Date{} = selected!(expr(today()), "printer-null")
      assert %DateTime{} = selected!(expr(now()), "printer-null")
    end

    test "a fragment's placeholder count is checked, because the mismatch is silent otherwise" do
      # An extra argument would otherwise be dropped and a missing one would leave a
      # bare `?` in the DDL, which PostgreSQL parses as an operator and rejects with
      # a message that names neither the mapping nor the fragment.
      assert_raise ArgumentError, ~r/has 1 `\?` placeholder\(s\) but 2 argument\(s\)/, fn ->
        Printer.to_sql(expr(fragment("upper(?)", first_name, last_name)),
          ref: Printer.bare_frame()
        )
      end
    end
  end

  describe "the refusals name their replacement" do
    # A refusal that only says "unsupported" makes the author guess, and the guess is
    # usually the refused thing spelled differently. Each message is asserted to
    # contain the construct that does work, because that sentence is the whole value
    # of refusing rather than rendering.

    test "`&&` is refused, naming `and` and `||`" do
      # In Ash `&&` returns the *value* of one side rather than a boolean, so there
      # is no single SQL operator for it. Rendering it as `AND` would typecheck in
      # PostgreSQL and mean something else.
      error = refusal(expr(first_name && last_name))

      assert error =~ "`&&` is not renderable"
      assert error =~ "Use `and` for a boolean conjunction"
      assert error =~ "for null-defaulting"
    end

    test "`coalesce/2` is refused, naming `||` and the inversion that causes the mistake" do
      # Ash has no `coalesce/2` at all: `expr(coalesce(a, b))` parses into a call to a
      # function that does not exist and fails later, somewhere unhelpful. Refusing it
      # here is what makes the failure point at the mapping. Built by hand because
      # `expr/1` would produce the same node and the point is the node, not the
      # syntax.
      error =
        refusal(%Ash.Query.Call{
          name: :coalesce,
          args: [Lens.column_ref(:first_name), ""],
          operator?: false,
          relationship_path: []
        })

      assert error =~ "Ash has no `coalesce/2`"
      assert error =~ "expr(first_name || \"\")"
      assert error =~ "the two symbols are inverted relative to SQL"
    end

    test "`exists(...)` is refused, naming `fragment` and saying lineage still sees inside it" do
      # The message has to make one thing clear that a bare "unsupported" would not:
      # the columns inside the subquery are *not* dropped from the diagram.
      # `AshStrangler.Expr.refs/1` re-roots them onto the relation they belong to.
      # Losing them quietly is exactly what the deleted regex heuristic did.
      error = refusal(expr(exists(payments, amount > 0)))

      assert error =~ "`exists(...)` is not renderable"
      assert error =~ "nothing can write a value"
      assert error =~ "AshStrangler.Expr.refs/1"
      assert error =~ "read_only?: true"
    end

    test "an unknown function is refused by name, with fragment offered and the set listed" do
      error = refusal(expr(width_bucket(id)))

      assert error =~ ":width_bucket/1 is not in the renderable node set"
      assert error =~ "fragment(\"width_bucket(?)\", some_column)"
      # The listing is what turns the refusal into a usable message. Without it the
      # author's next move is another guess.
      assert error =~ ":string_downcase"
      assert error =~ ":at_zone"
    end

    test "an unrecognised node is refused too, not only an unrecognised function" do
      # There is no fallback clause anywhere in the printer, and this is the half of
      # that property the function-name test cannot reach. `%Ash.Query.Parent{}` is a
      # real node `Ash.Expr` can build and this printer has no clause for; a printer
      # with a catch-all would turn it into a literal, and the resulting view would
      # be syntactically valid and semantically invented.
      assert_raise ArgumentError, ~r/cannot be rendered as a SQL literal/, fn ->
        Printer.to_sql(%Ash.Query.Parent{expr: Lens.column_ref(:id)},
          ref: Printer.bare_frame()
        )
      end
    end
  end

  # --- the AshSql differential oracle ------------------------------------------

  describe "the AshSql differential oracle" do
    test "the printer and ash_sql's own renderer return the same rows" do
      # The design document names `inline_literals/1` as the primary implementation
      # strategy for this module: rewrite every literal leaf into a raw
      # `%Ash.Query.Function.Fragment{arguments: [raw: …]}` and let `AshSql` render
      # the rest, so the statement carries zero bound parameters. It ships as the
      # oracle instead of as the renderer because `AshSql` knows one reference frame
      # — §8 of `the-transform-layer` records that — but keeping it means the printer
      # is checked against the renderer that actually ships inside `ash_postgres`
      # rather than only against itself.
      for expression <- oracle_expressions() do
        assert ash_sql_rows(expression) == printer_rows(expression),
               """
               the two renderers disagree for #{inspect(expression)}

                 printer: #{Printer.to_sql(expression, ref: Printer.bare_frame(LegacyUsers))}
                 ash_sql: #{ash_sql_sql(expression)}
               """
      end
    end

    test "the oracle renders with no bound parameters, which is what makes it DDL-safe" do
      # The property the whole `inline_literals/1` pass exists for. If one parameter
      # survives, the statement cannot appear in a `CREATE VIEW` — and the oracle
      # would be checking a rendering this package can never use.
      for expression <- oracle_expressions() do
        assert {_sql, []} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, ash_sql_query(expression)),
               "#{inspect(expression)} still carries a bound parameter after inline_literals/1"
      end
    end

    test "a nil comparison is where the two renderers part company, and the printer is right" do
      # The one divergence in the set, recorded because it is the reason the printer
      # carries an `== nil` clause at all.
      #
      # Ash normalises `expr(x == nil)` into `is_nil(x)` when a *filter* is parsed, so
      # `AshSql` never meets an `Eq(x, nil)` in normal use and renders it literally as
      # `= NULL` — which is not false, it is NULL, so every row comes back NULL. A
      # `strangler` block stores the unhydrated call directly and
      # `Ash.Filter.hydrate_refs/2` does not perform that normalisation, so this
      # printer is the only thing standing between the stored node and a view column
      # that is NULL for every row in the table.
      assert printer_rows(nil_comparison(:==, :email)) == ["false", "true"]
      assert ash_sql_rows(nil_comparison(:==, :email)) == [nil, nil]
    end

    test "the oracle is a real check: two expressions that differ are reported as differing" do
      # Without this, a mistake in the harness that rendered the *same* expression on
      # both sides would leave the test above passing while checking nothing. Ash's
      # `||` is SQL's `coalesce` and Ash's `<>` is SQL's `||`, so this pair is the
      # inversion the printer is most likely to get wrong, and it is the pair the
      # oracle most needs to be able to tell apart.
      refute ash_sql_rows(expr(first_name || "fallback")) ==
               printer_rows(expr(first_name <> "fallback"))
    end
  end

  # The expressions the oracle covers. Three shapes are deliberately absent, and each
  # is a defect in `inline_literals/1` rather than a limit of the technique:
  #
  #   * `%Ash.Query.Not{}`, `%Ash.Query.BooleanExpression{}` and `%Ash.Query.Exists{}`
  #     reach `AshStrangler.Expr.map/2`'s callback as whole nodes and fall through to
  #     its literal branch, so the entire subtree is replaced by one fragment;
  #   * a `fragment`'s template string is inlined as though it were a value, which
  #     leaves `AshSql` with a fragment whose first argument is not a string;
  #   * `type/2`'s second argument — a type, not a value — is inlined the same way.
  #
  # They are omitted rather than worked around here. Substituting a hand-rolled
  # literal-inlining pass would make the oracle check this file's implementation
  # instead of the package's, which is the one thing an oracle may not do.
  #
  # Arithmetic is absent for a different reason, and one that belongs to the harness
  # rather than to either renderer. `AshSql` resolves an operator's operand types
  # through `Ash.Expr.determine_types/4` against the query it is rendering into, and
  # an expression hydrated outside a real read action gives it nothing to work from:
  # `expr(id * 2 + 1)` comes out as `id::bigint * 2::interval`, which PostgreSQL
  # refuses. The printer needs no types at all, which is the whole reason
  # `AshStrangler.Expr` walks the unhydrated tree — so there is no rendering here for
  # the oracle to disagree with, only a context it cannot supply.
  #
  # `now()` and `today()` are absent for a third reason, and it is the one worth
  # knowing: `AshSql` resolves them in the BEAM and sends the result as a bound
  # parameter, because a *query* wants the instant the caller asked. DDL wants the
  # opposite — a view definition holding a date literal reports the moment the
  # migration was generated, for every row, forever. The printer emits `now()` and
  # `current_date` so the server evaluates them per row, which is the same refusal
  # `AshStrangler.Lens.default_expression!/2` makes for a function-valued `default:`.
  # The two renderers are supposed to differ here.
  defp oracle_expressions do
    [
      expr((first_name || "") <> " " <> (last_name || "")),
      expr(if is_nil(first_name), do: "unknown", else: last_name),
      expr(string_downcase(email)),
      expr(string_trim(first_name)),
      expr(string_length(login)),
      expr(id in [1, 2, 3]),
      expr(state == :active),
      expr(state != :active),
      expr(deleted_at),
      expr(is_nil(deleted_at))
    ]
  end

  # Both sides are cast to `text` before they leave the server, and that is a
  # deliberate part of the oracle rather than a concession.
  #
  # The two renderings are consumed by two different clients: Ecto loads the value
  # through the Ash type `AshSql` wrapped it in, and Postgrex hands back what the wire
  # carried. For `expr(deleted_at)` those disagree — `~N[2024-03-10 02:30:00]` against
  # `~N[2024-03-10 02:30:00.000000]` — on identical SQL, because `:naive_datetime`
  # truncates on load. That is a difference between two client libraries, not between
  # two renderers, and letting it fail the oracle would have meant relaxing the
  # comparison until it passed. Comparing PostgreSQL's own text rendering of each
  # value puts the assertion where the disagreement would actually matter.
  defp ash_sql_rows(expression) do
    {query, dynamic} = ash_sql_dynamic(expression)

    # Composed as a nested dynamic rather than interpolated into a `select` fragment:
    # Ecto only accepts a dynamic at the top level of a select, and only another
    # dynamic may wrap one.
    as_text = Ecto.Query.dynamic([row], fragment("(?)::text", ^dynamic))

    query
    |> Ecto.Query.select(^as_text)
    |> TestRepo.all()
  end

  defp ash_sql_sql(expression) do
    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, ash_sql_query(expression))
    sql
  end

  defp printer_rows(expression) do
    sql = Printer.to_sql(expression, ref: Printer.bare_frame(LegacyUsers))

    TestRepo.query!("SELECT (#{sql})::text FROM legacy.users ORDER BY id", []).rows
    |> Enum.map(&hd/1)
  end

  # The full Ash query context the oracle needs, which is also why it is test-only.
  # Three pieces are not optional: the named binding `as: ^0`, which is what `AshSql`
  # emits references against; the query prefix, because a twin's schema lives in
  # `postgres do schema end` rather than in the table name; and hydration, since
  # `AshSql` renders `Ash.Query.Operator.*` structs while a stored mapping is
  # unhydrated `%Ash.Query.Call{}`.
  #
  # `inline_literals/1` runs *before* hydration deliberately. After it, the tree is
  # full of operator structs `AshStrangler.Expr.map/2` does not descend into, and
  # every one of them would be replaced by a literal.
  defp ash_sql_dynamic(expression) do
    inlined = Printer.inline_literals(expression)

    {:ok, hydrated} = Ash.Filter.hydrate_refs(inlined, %{resource: LegacyUsers, public?: false})

    query =
      Ecto.Query.from(row in AshPostgres.DataLayer.resource_to_query(LegacyUsers, nil), as: ^0)
      |> Ecto.Query.put_query_prefix("legacy")
      |> AshSql.Bindings.default_bindings(LegacyUsers, AshPostgres.SqlImplementation)

    {dynamic, _acc} = AshSql.Expr.dynamic_expr(query, hydrated, query.__ash_bindings__)

    {Ecto.Query.order_by(query, [row], asc: row.id), dynamic}
  end

  defp ash_sql_query(expression) do
    {query, dynamic} = ash_sql_dynamic(expression)
    Ecto.Query.select(query, ^dynamic)
  end

  # --- helpers -----------------------------------------------------------------

  # Both renderings in one statement, so the same connection decodes both into the
  # same result type and a difference cannot be an artefact of two round trips.
  #
  # The cast is required rather than chosen: `SELECT $1` alone gives PostgreSQL
  # nothing to infer the parameter's type from and it refuses to plan the statement.
  # Casting both sides identically is what keeps the comparison about the *value*.
  defp assert_agrees!(value) do
    cast = cast_for(value)

    %Postgrex.Result{rows: [[printed, bound]]} =
      TestRepo.query!("SELECT (#{Printer.literal(value)})::#{cast}, ($1)::#{cast}", [param(value)])

    assert same?(printed, bound),
           """
           the printed literal and the bound parameter are different values

               value: #{inspect(value)}
             printed: #{Printer.literal(value)} -> #{inspect(printed)}
               bound: $1 -> #{inspect(bound)}
           """
  end

  # The value's wire form, for the bound side. Postgrex has no encoder for an atom or
  # an `Ash.CiString` — those are Elixir shapes, not PostgreSQL ones — so the bound
  # side sends the text they denote. That is not the oracle conceding the point:
  # `literal/1`'s job for both is to produce a *text* literal, and the text they
  # denote is exactly what the comparison should be against.
  defp param(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp param(%Ash.CiString{} = value), do: Ash.CiString.value(value)
  defp param(value), do: value

  defp cast_for(nil), do: "text"
  defp cast_for(value) when is_boolean(value), do: "boolean"
  defp cast_for(value) when is_integer(value), do: "bigint"
  defp cast_for(value) when is_float(value), do: "float8"
  defp cast_for(value) when is_binary(value), do: "text"
  defp cast_for(value) when is_atom(value), do: "text"
  defp cast_for(%Decimal{}), do: "numeric"
  defp cast_for(%Date{}), do: "date"
  defp cast_for(%Time{}), do: "time"
  defp cast_for(%NaiveDateTime{}), do: "timestamp"
  defp cast_for(%DateTime{}), do: "timestamptz"
  defp cast_for(%Ash.CiString{}), do: "text"

  # `Decimal` carries scale, so `1.230` and `1.23` are distinct terms and the same
  # number. The oracle is about the number.
  defp same?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same?(a, b), do: a == b

  # --- generators --------------------------------------------------------------

  defp literal_value do
    one_of([
      sql_hostile_text(),
      constant(nil),
      boolean(),
      integer(),
      # Bounded rather than unbounded. `Float.to_string/1` emits the shortest
      # round-tripping decimal, which PostgreSQL reads as `numeric` before the cast
      # to `float8` — exact for ordinary magnitudes, and a subnormal is a test of
      # numeric's exponent range rather than of this module's escaping.
      float(min: -1.0e10, max: 1.0e10),
      map({integer(-999_999..999_999), integer(0..999_999)}, fn {whole, frac} ->
        Decimal.new("#{whole}.#{frac}")
      end),
      member_of([:active, :passive, :pending, :suspended, :deleted]),
      map(integer(0..40_000), &Date.add(~D[1900-01-01], &1)),
      map(integer(0..86_399), &Time.add(~T[00:00:00], &1)),
      Generators.adversarial_naive_datetime(),
      map(
        integer(0..1_000_000_000),
        &DateTime.add(~U[2000-01-01 00:00:00.000000Z], &1, :second)
      ),
      map(sql_hostile_text(), &Ash.CiString.new/1)
    ])
  end

  # `Generators.adversarial_text/0` is biased toward the values that break *value
  # comparison* — case folding, Unicode normalization, whitespace. Those matter here
  # too, but escaping breaks along a different axis, so the SQL metacharacters are
  # enumerated alongside it rather than left to chance: a random alphanumeric string
  # will not produce `E'` or a lone backslash in any number of runs.
  defp sql_hostile_text do
    one_of([
      Generators.adversarial_text(),
      member_of([
        "'",
        "''",
        "\\",
        "\\\\",
        "\\'",
        "''\\''",
        "E'",
        "e'\\'",
        "U&'\\0041'",
        "$$",
        "$tag$",
        "--",
        "/*",
        "*/",
        ";",
        "?",
        "$1",
        "%",
        "%s",
        "' OR 1=1 --",
        "'); DROP VIEW strangler.users; --"
      ]),
      string(:printable, min_length: 0, max_length: 12),
      # Assembles the metacharacters into arbitrary sequences, which is where the
      # interesting failures live: `\\` immediately before `'` is a different case
      # from either alone, and only a generator finds the arrangement.
      map(
        list_of(member_of(["'", "\\", "\"", "E", "n", "0", " ", ";", "-"]), max_length: 8),
        &Enum.join/1
      )
    ])
  end

  # --- expression fixtures -----------------------------------------------------

  # Every renderable node, each paired with what it is here to prove. Executed rather
  # than string-compared: the point is that the output *runs*.
  defp executable_expressions do
    [
      {expr(login), "a bare reference"},
      {@forward, "Ash's `||` and `<>`, inverted relative to SQL"},
      {expr(not is_nil(deleted_at)), "%Ash.Query.Not{} over is_nil, collapsed"},
      {expr(not (id > 0)), "%Ash.Query.Not{} over anything else"},
      {expr(is_nil(deleted_at) and id > 0), "%Ash.Query.BooleanExpression{} with :and"},
      {expr(is_nil(deleted_at) or id > 0), "%Ash.Query.BooleanExpression{} with :or"},
      {expr(id in [1, 2, 3]), "`in` as a parenthesised list"},
      {expr(state == :active), "an atom literal against a text column"},
      {nil_comparison(:==, :email), "a nil comparison becoming IS NULL"},
      {nil_comparison(:!=, :email), "a nil comparison becoming IS NOT NULL"},
      {expr(id * 2 + 1 - 1), "arithmetic"},
      {expr(id / 2), "division"},
      {expr(-id), "unary minus"},
      {expr(id >= 1 and id <= 1_000_000 and id < 1_000_000 and id > 0), "the comparisons"},
      {expr(abs(id)), "abs"},
      {expr(round(id)), "round"},
      {expr(ceil(id / 2)), "ceil"},
      {expr(floor(id / 2)), "floor"},
      {expr(least(id, 1)), "least"},
      {expr(greatest(id, 1)), "greatest"},
      {expr(string_downcase(email)), "string_downcase"},
      {expr(string_upcase(email)), "string_upcase"},
      {expr(string_trim(first_name)), "string_trim"},
      {expr(string_length(login)), "string_length"},
      {expr(type(email, :ci_string)), "an explicit cast resolved through pg_type!/1"},
      {expr(type(id, "text")), "an explicit cast to a raw Postgres type name"},
      {expr(if is_nil(first_name), do: "none", else: first_name), "`if` with an else branch"},
      {expr(if is_nil(first_name), do: "none"), "`if` with no else branch"},
      {expr(fragment("upper(?::text)", state)), "a fragment with a placeholder"},
      {expr(fragment("now()")), "a fragment with none"},
      {expr(now()), "now()"},
      {expr(today()), "today()"},
      {[1, 2, 3], "a bare list, which renders as an array"}
    ]
  end

  # Built by hand rather than written as `expr(email == nil)`. Elixir warns on a
  # literal `== nil` comparison in any AST it compiles, including the one `expr/1` is
  # handed — and the node is what is under test here, not the syntax that produces
  # it.
  defp nil_comparison(operator, column) do
    %Ash.Query.Call{
      name: operator,
      args: [Lens.column_ref(column), nil],
      operator?: true,
      relationship_path: []
    }
  end

  defp diagram_twin, do: AshStrangler.DiagramTest.Legacy.Accounts

  defp selected!(expression, login) do
    sql = Printer.to_sql(expression, ref: Printer.bare_frame(LegacyUsers))

    %Postgrex.Result{rows: [[value]]} =
      TestRepo.query!("SELECT #{sql} FROM legacy.users WHERE login = $1", [login])

    value
  end

  defp refusal(expression) do
    Printer.to_sql(expression, ref: Printer.bare_frame())
    flunk("expected #{inspect(expression)} to be refused")
  rescue
    error in ArgumentError -> Exception.message(error)
  end
end
