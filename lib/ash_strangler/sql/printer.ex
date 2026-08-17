# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.Printer do
  @moduledoc """
  The one `Ash.Expr` → SQL renderer. Everything this package emits goes through
  it.

  Six generators used to emit SQL by five different string paths: the view's
  `from:` string, the trigger's `String.replace(to, "$NEW.", "NEW.")`, the reverse
  view's `String.replace(to, "$NEW.", "")`, the expression index, and the
  reconciler's `normalize:` templates. Two restatements of one expression can
  drift, and when the *index* expression drifts from the *query* expression
  PostgreSQL silently stops using the index — the only symptom is a sequential
  scan at production data volumes. `AshStrangler.Sql.View` already protected the
  key expression by building both from one function and said why; this
  generalises that protection to every mapping.

  ## Reference frames — why this is not `Ecto.Adapters.SQL.to_sql/4`

  `AshPostgres.Merge` is the in-tree precedent for assembling SQL Ecto cannot
  express: it renders each clause with `Ecto.Adapters.SQL.to_sql/4` and a
  `:counter` offset so `$n` placeholders line up. Reaching for the same trick here
  was the first plan, and it does not fit, for a reason that only becomes obvious
  once the write side exists.

  **One forward expression has to be rendered in four different reference
  frames.** `map :archived_at, from: :deleted_at, zone: "UTC"` renders as:

  | Consumer | Rendering |
  |---|---|
  | the compatibility view | `(deleted_at AT TIME ZONE 'UTC')` |
  | the same view under a join | `(accounts.deleted_at AT TIME ZONE 'UTC')` |
  | the `INSTEAD OF` trigger's write side | `NEW.archived_at AT TIME ZONE 'UTC'` |
  | the `:read_from_new` reverse view | `archived_at AT TIME ZONE 'UTC'` |

  Ecto's renderer knows exactly one frame — `s0."deleted_at"` — and no option
  changes that. So the frame is a parameter here (`:ref`), and the four consumers
  differ by one function rather than by four string paths. That is the whole
  point.

  Two lesser reasons, recorded because they were part of the decision: Ecto's
  `s0.`-prefixed aliasing makes generated view DDL unreadable and makes it churn
  across `ash_postgres` versions, which would break byte-identical golden tests
  for no gain; and `to_sql/4` needs a started repo, which a Spark verifier does
  not have.

  ## Parameters, and the one function that owns escaping

  `AshSql` parameterises every literal and **DDL cannot be parameterised**. That
  is the hard part of this module, and the mitigation is structural: literal
  rendering is `literal/1`, one function, and nothing else in the package
  produces a SQL literal. Get it wrong once and it is an injection in DDL
  generated at compile time, so it is property-tested against PostgreSQL itself as
  a differential oracle — the printed literal is executed and compared against the
  same value sent as a bound parameter, which is a stronger check than comparing
  two renderings.

  `literal/1` mirrors PostgreSQL's own `quote_literal()`: single quotes are
  doubled, and a value containing a backslash is emitted in `E'…'` form with
  backslashes escaped, so the result is correct whether or not
  `standard_conforming_strings` is on.

  ## The closed node set

  Only the nodes the combinator grammar produces are renderable. Anything else is
  refused **by name**, with `fragment(...)` named as the deliberate escape. There
  is no fallback clause: a printer that guessed at a node it did not recognise
  would emit SQL nobody wrote.
  """

  alias Ash.Query.{BooleanExpression, Call, Exists, Not, Ref}
  alias AshStrangler.Expr, as: StranglerExpr

  @typedoc """
  How a reference renders. Given `{relationship_path, attribute}` it returns the
  SQL for that reference — the frame described in the moduledoc.
  """
  @type ref_fun() :: (AshStrangler.Expr.ref() -> String.t())

  @doc """
  Renders `expr` to parameter-free SQL.

  ## Options

    * `:ref` (required) — the reference frame, a `t:ref_fun/0`.
    * `:touch` — how a `collapse` clause's `touch()` renders. `:now` (the default)
      for an INSERT, or `{:preserve, frame}` for an UPDATE, where `frame` renders
      the *prior* value of an attribute. See the `:strangler_touch` clause.

  ## Examples

      iex> import Ash.Expr
      iex> AshStrangler.Sql.Printer.to_sql(
      ...>   expr((first_name || "") <> " " <> (last_name || "")),
      ...>   ref: fn {_path, name} -> to_string(name) end
      ...> )
      "(coalesce(first_name, '') || (' ' || coalesce(last_name, '')))"

      iex> import Ash.Expr
      iex> AshStrangler.Sql.Printer.to_sql(
      ...>   expr(if is_deleted, do: "archived", else: "pending"),
      ...>   ref: fn {_path, name} -> to_string(name) end
      ...> )
      "(CASE WHEN is_deleted THEN 'archived' ELSE 'pending' END)"
  """
  @spec to_sql(AshStrangler.Expr.t(), keyword()) :: String.t()
  def to_sql(expr, opts) do
    ref =
      Keyword.get(opts, :ref) ||
        raise ArgumentError, "AshStrangler.Sql.Printer.to_sql/2 requires a `:ref` frame"

    print(expr, %{ref: ref, touch: Keyword.get(opts, :touch, :now)})
  end

  # --- references and literals -------------------------------------------------

  defp print(%Ref{relationship_path: path, attribute: attribute}, ctx)
       when is_atom(attribute) do
    ctx.ref.({path, attribute})
  end

  # A hydrated Ref carries the attribute struct rather than its name. Handled so
  # an expression that has been through `Ash.Filter.hydrate_refs/2` — which
  # `AshStrangler.Lens.hydrate/2` does, for the type-agreement obligation — still
  # prints.
  defp print(%Ref{relationship_path: path, attribute: %{name: name}}, ctx) do
    ctx.ref.({path, name})
  end

  defp print(%Ash.CustomExpression{expression: inner}, ref), do: print(inner, ref)

  # --- the nodes `expr/1` builds that are not Calls ----------------------------

  defp print(%BooleanExpression{op: op, left: left, right: right}, ref) do
    keyword = if op == :and, do: "AND", else: "OR"
    "(#{print(left, ref)} #{keyword} #{print(right, ref)})"
  end

  # `not is_nil(x)` is the single most common guard in a `collapse`, and the
  # mechanical rendering — `(NOT (x IS NULL))` — is correct and hard to read four
  # levels into a nested `CASE`. A compatibility view is reviewed by people.
  defp print(%Not{expression: %Call{name: :is_nil, args: [inner]}}, ref),
    do: "(#{print(inner, ref)} IS NOT NULL)"

  defp print(%Not{expression: inner}, ref), do: "(NOT #{print(inner, ref)})"

  defp print(%Exists{}, _ref) do
    raise ArgumentError, """
    `exists(...)` is not renderable by this printer.

    A subquery is not part of the invertible grammar: nothing can write a value
    back through it, and its fan-out depends on the data rather than on the
    declaration. Lineage *does* see the columns inside it — `AshStrangler.Expr.refs/1`
    re-roots them onto the relation they belong to — so it is not silently dropped
    from the diagram.

    If a mapping genuinely needs one, say so:

        map :has_paid,
          from: expr(fragment("EXISTS (SELECT 1 FROM legacy.payments p WHERE p.account_id = id)")),
          read_only?: true,
          because: "..."
    """
  end

  # --- operators ---------------------------------------------------------------

  defp print(%Call{name: :==, args: [left, nil]}, ref), do: "(#{print(left, ref)} IS NULL)"
  defp print(%Call{name: :==, args: [nil, right]}, ref), do: "(#{print(right, ref)} IS NULL)"
  defp print(%Call{name: :!=, args: [left, nil]}, ref), do: "(#{print(left, ref)} IS NOT NULL)"
  defp print(%Call{name: :!=, args: [nil, right]}, ref), do: "(#{print(right, ref)} IS NOT NULL)"

  # Ash's `<>` is SQL's `||`, and Ash's `||` is SQL's `coalesce`. Both symbols
  # mean the other thing, which is why they are the two most specific clauses in
  # this module and why `:coalesce` is refused by name below.
  defp print(%Call{name: :<>, args: [left, right]}, ref),
    do: "(#{print(left, ref)} || #{print(right, ref)})"

  defp print(%Call{name: :||, args: [left, right]}, ref),
    do: "coalesce(#{print(left, ref)}, #{print(right, ref)})"

  defp print(%Call{name: :&&, args: _args}, _ref) do
    raise ArgumentError, """
    `&&` is not renderable.

    In Ash `&&` returns the *value* of one side rather than a boolean, so there is
    no single SQL operator for it. Use `and` for a boolean conjunction, or `||`
    for null-defaulting.
    """
  end

  defp print(%Call{name: :not, args: [arg]}, ref), do: "(NOT #{print(arg, ref)})"
  defp print(%Call{name: :-, args: [arg]}, ref), do: "(-#{print(arg, ref)})"

  # `IN` takes a parenthesised list, not an array. `x IN ARRAY[1, 2]` is a type
  # error in Postgres, and the fix is not `= ANY` — it renders differently and
  # would make the index expression and the query expression two spellings of one
  # thing, which is what this module exists to prevent.
  defp print(%Call{name: :in, args: [left, values]}, ref) when is_list(values) do
    "(#{print(left, ref)} IN (#{Enum.map_join(values, ", ", &print(&1, ref))}))"
  end

  @binary_operators %{
    ==: "=",
    !=: "<>",
    >: ">",
    >=: ">=",
    <: "<",
    <=: "<=",
    +: "+",
    -: "-",
    *: "*",
    /: "/",
    and: "AND",
    or: "OR",
    in: "IN"
  }

  for {name, sql} <- @binary_operators do
    defp print(%Call{name: unquote(name), args: [left, right]}, ref) do
      "(#{print(left, ref)} #{unquote(sql)} #{print(right, ref)})"
    end
  end

  # --- functions ---------------------------------------------------------------

  defp print(%Call{name: :is_nil, args: [arg]}, ref), do: "(#{print(arg, ref)} IS NULL)"

  # `expr/1` desugars `cond` into nested `if`s, and the final `true ->` arm
  # therefore arrives as `if true, do: …`. Rendering it literally produces a
  # trailing `ELSE (CASE WHEN TRUE THEN 'pending' END)`, which is correct SQL and
  # unreadable in a view definition somebody has to review. Collapsed here, which
  # is also what makes a `collapse` block's `:otherwise` clause render as a plain
  # `ELSE`.
  defp print(%Call{name: :if, args: [true, branches]}, ref) when is_list(branches) do
    print(Keyword.get(branches, :do), ref)
  end

  defp print(%Call{name: :if, args: [condition, branches]}, ref) when is_list(branches) do
    then_sql = print(Keyword.get(branches, :do), ref)

    case Keyword.fetch(branches, :else) do
      {:ok, otherwise} ->
        "(CASE WHEN #{print(condition, ref)} THEN #{then_sql} ELSE #{print(otherwise, ref)} END)"

      :error ->
        "(CASE WHEN #{print(condition, ref)} THEN #{then_sql} END)"
    end
  end

  # A `decode`'s value table, as SQL's *simple* `CASE subject WHEN … THEN … END`.
  #
  # A fold over the table into nested `if`s renders correctly and is unreadable —
  # five values produce five levels of `CASE WHEN (state = 'x') THEN … ELSE (CASE
  # …)`. A compatibility view is reviewed by people far more often than a migration
  # is, so the shorter form earns its own node.
  #
  # No `ELSE`, deliberately. An unlisted value yields SQL NULL, and that is the
  # honest rendering: `AshStrangler.Obligations`' `GetTotal` refuses a table that
  # does not cover the column's declared value set, so reaching the `ELSE` means
  # the value space was not decidable at compile time — in which case a NULL is a
  # visible absence, and the catch-all that 0.1's `CASE … ELSE 1 END` used is
  # exactly how three of five lifecycle states came to be silently rewritten.
  defp print(%Call{name: :strangler_case, args: [subject, pairs, default]}, ref)
       when is_list(pairs) do
    arms =
      Enum.map_join(pairs, " ", fn {match, result} ->
        "WHEN #{print(match, ref)} THEN #{print(result, ref)}"
      end)

    otherwise =
      case default do
        :none -> ""
        value -> " ELSE #{print(value, ref)}"
      end

    "(CASE #{print(subject, ref)} #{arms}#{otherwise} END)"
  end

  defp print(%Call{name: :cond, args: [clauses]}, ref) when is_list(clauses) do
    body =
      Enum.map_join(clauses, " ", fn
        {:->, _meta, [[condition], result]} ->
          "WHEN #{print(condition, ref)} THEN #{print(result, ref)}"

        other ->
          raise ArgumentError, "unsupported `cond` clause: #{inspect(other)}"
      end)

    "(CASE #{body} END)"
  end

  # `type/2`'s second argument is an Ash type or a Postgres type name. The
  # storage type is asked of Ash rather than guessed, so `:ci_string` becomes
  # `citext` because `Ash.Type.CiString` says so — not because this module
  # keeps a table that could disagree with it.
  defp print(%Call{name: :type, args: [value, type | _rest]}, ref) do
    "(#{print(value, ref)})::#{pg_type!(type)}"
  end

  # `zone:`'s node. Deliberately `AT TIME ZONE '<literal>'` and never
  # `::timestamptz`: a bare cast on a naive `timestamp` reads it as wall-clock
  # time in the *session's* TimeZone, which was measured at 10.5 hours of drift
  # between two connections reading the same row. `timezone(text, timestamp)` is
  # also `IMMUTABLE`, where the one-argument form a bare cast resolves to is
  # `STABLE` — so this is the only form that can carry an expression index.
  defp print(%Call{name: :at_zone, args: [value, zone]}, ref) when is_binary(zone) do
    "(#{print(value, ref)} AT TIME ZONE #{literal(zone)})"
  end

  defp print(%Call{name: :fragment, args: args}, ref), do: fragment(args, ref)

  # `touch()` from a `collapse` clause. Two renderings, because the two write
  # paths genuinely know different things:
  #
  #   * `:now` — an INSERT. There is no prior row, so a transition into this state
  #     is the only possibility.
  #   * `{:preserve, attribute}` — an UPDATE. `now()` only when the state actually
  #     changed; otherwise the stored value, read straight out of the bare column
  #     name, which is what a bare column means on the right-hand side of
  #     `UPDATE ... SET`.
  #
  # This is the one declared `PutPut` violation in the design. Rendering it in two
  # forms is not a special case bolted on: it is what "preserve unless this is a
  # transition" means, and the alternative — always `now()` — silently rewrites the
  # timestamp of every row a write touched for any reason.
  defp print(%Call{name: :strangler_touch, args: [column, attribute]}, ctx)
       when is_binary(column) do
    case ctx.touch do
      :now ->
        "now()"

      {:preserve, frame} ->
        old = frame.({[], attribute_name(attribute)})
        new = "NEW.#{attribute_name(attribute)}"

        # `column` is a bare legacy column name, not a reference rendered through
        # `ctx.ref`. On the right-hand side of `UPDATE ... SET` a bare column name is
        # the row's stored value, which is exactly what "preserve" means -- and it is
        # the one place in a write expression where a reference is NOT a resource
        # attribute. See `AshStrangler.Lens.collapse_value/4`.
        "(CASE WHEN #{old} IS DISTINCT FROM #{new} THEN now() ELSE #{column} END)"
    end
  end

  @sql_functions %{
    string_downcase: "lower",
    string_upcase: "upper",
    string_trim: "btrim",
    string_length: "length",
    abs: "abs",
    round: "round",
    ceil: "ceil",
    floor: "floor",
    least: "least",
    greatest: "greatest"
  }

  for {name, sql} <- @sql_functions do
    defp print(%Call{name: unquote(name), args: args}, ref) do
      "#{unquote(sql)}(#{Enum.map_join(args, ", ", &print(&1, ref))})"
    end
  end

  defp print(%Call{name: :now, args: []}, _ref), do: "now()"
  defp print(%Call{name: :today, args: []}, _ref), do: "current_date"

  defp print(%Call{name: :coalesce, args: _args}, _ref) do
    raise ArgumentError, """
    Ash has no `coalesce/2`.

    `expr(coalesce(a, b))` parses — it becomes a call to a function that does not
    exist, and fails later — so it is refused here by name rather than rendered.
    Ash spells null-defaulting `||`:

        expr(first_name || "")

    Note that the two symbols are inverted relative to SQL: Ash's `||` is SQL's
    `coalesce`, and Ash's `<>` is SQL's `||`.
    """
  end

  defp print(%Call{name: name, args: args}, _ref) do
    raise ArgumentError, """
    #{inspect(name)}/#{length(args)} is not in the renderable node set.

    #{inspect(__MODULE__)} renders only the nodes the combinator grammar produces,
    because a printer that guessed at an unrecognised node would emit SQL nobody
    wrote. Renderable: #{renderable()}.

    To use something outside that set, say so:

        from: expr(fragment("#{name}(?)", some_column))
    """
  end

  defp print(list, ref) when is_list(list) do
    "ARRAY[#{Enum.map_join(list, ", ", &print(&1, ref))}]"
  end

  defp print(literal, _ref), do: literal(literal)

  defp renderable do
    ([:<>, :||, :not, :is_nil, :if, :cond, :type, :at_zone, :fragment, :now, :today] ++
       Map.keys(@binary_operators) ++ Map.keys(@sql_functions))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(", ", &inspect/1)
  end

  # --- fragments ---------------------------------------------------------------

  # Two shapes reach here. The unhydrated form is `["template with ?", arg, ...]`,
  # and the hydrated form — which `Ash.Query.Function.Fragment` produces, and
  # which `AshPostgres.Extensions.ImmutableRaiseError` hand-builds — is a keyword
  # list of `raw:`/`expr:` parts.
  defp fragment([template | args], ref) when is_binary(template) do
    parts = String.split(template, "?")
    expected = length(parts) - 1

    if expected != length(args) do
      raise ArgumentError,
            "fragment #{inspect(template)} has #{expected} `?` placeholder(s) but #{length(args)} argument(s)"
    end

    parts
    |> Enum.zip(Enum.map(args, &print(&1, ref)) ++ [""])
    |> Enum.map_join("", fn {part, arg} -> part <> arg end)
  end

  defp fragment(parts, ref) when is_list(parts) do
    Enum.map_join(parts, "", fn
      {:raw, raw} -> raw
      {:expr, expr} -> print(expr, ref)
      {:casted_expr, expr} -> print(expr, ref)
    end)
  end

  # --- literals ----------------------------------------------------------------

  @doc """
  Renders a value as a SQL literal. **The only place in this package that does.**

  Mirrors PostgreSQL's own `quote_literal()`: single quotes are doubled, and a
  value containing a backslash is emitted as `E'…'` with backslashes escaped, so
  the result is correct under `standard_conforming_strings` either way.

  A NUL byte is refused rather than escaped. PostgreSQL cannot store one in a
  `text` value at all, so any encoding of it would be a lie about what the
  database will hold.

      iex> AshStrangler.Sql.Printer.literal("de la Cruz")
      "'de la Cruz'"

      iex> AshStrangler.Sql.Printer.literal("O'Brien")
      "'O''Brien'"

      iex> AshStrangler.Sql.Printer.literal("back\\\\slash")
      "E'back\\\\\\\\slash'"

      iex> AshStrangler.Sql.Printer.literal(nil)
      "NULL"

      iex> AshStrangler.Sql.Printer.literal(~U[2024-06-15 12:00:00.000000Z])
      "'2024-06-15T12:00:00.000000Z'::timestamptz"
  """
  @spec literal(term()) :: String.t()
  def literal(nil), do: "NULL"
  def literal(true), do: "TRUE"
  def literal(false), do: "FALSE"
  def literal(value) when is_integer(value), do: Integer.to_string(value)
  def literal(value) when is_float(value), do: Float.to_string(value)
  # `Decimal.to_string/2` renders the non-finite values as the bare words `NaN` and
  # `Infinity`, so `literal/1` would return an unquoted identifier -- `SELECT NaN`
  # is `column "nan" does not exist`. Refused by name rather than quoted, because
  # `'NaN'::numeric` is accepted by PostgreSQL and is almost certainly not what a
  # mapping meant: a non-finite value in a legacy column is a fact to look at, not
  # something to render into a view definition.
  #
  # This is the only input to the only escaping function in the package that came out
  # without quotes, which is why it gets a clause of its own rather than a coercion.
  def literal(%Decimal{coef: coef} = value) when coef in [:NaN, :inf, :qNaN, :sNaN] do
    raise ArgumentError, """
    #{inspect(Decimal.to_string(value))} cannot be rendered as a SQL literal.

    `Decimal` renders the non-finite values as bare words, so this would emit an
    unquoted identifier rather than a value. If a legacy column genuinely holds NaN
    or an infinity, say so explicitly:

        from: expr(fragment("'NaN'::numeric"))
    """
  end

  def literal(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  def literal(%DateTime{} = value),
    do: "#{quote_string(DateTime.to_iso8601(value))}::timestamptz"

  def literal(%NaiveDateTime{} = value),
    do: "#{quote_string(NaiveDateTime.to_iso8601(value))}::timestamp"

  def literal(%Date{} = value), do: "#{quote_string(Date.to_iso8601(value))}::date"
  def literal(%Time{} = value), do: "#{quote_string(Time.to_iso8601(value))}::time"

  def literal(%Ash.CiString{} = value), do: "#{quote_string(Ash.CiString.value(value))}::citext"

  def literal(value) when is_atom(value), do: quote_string(Atom.to_string(value))
  def literal(value) when is_binary(value), do: quote_string(value)

  def literal(value) when is_list(value),
    do: "ARRAY[#{Enum.map_join(value, ", ", &literal/1)}]"

  def literal(other) do
    raise ArgumentError, """
    #{inspect(other)} cannot be rendered as a SQL literal.

    Supported: nil, booleans, integers, floats, Decimal, binaries, atoms,
    Date/Time/NaiveDateTime/DateTime, Ash.CiString, and lists of those.
    """
  end

  defp quote_string(value) when is_binary(value) do
    if String.contains?(value, <<0>>) do
      raise ArgumentError, """
      a SQL literal cannot contain a NUL byte.

      PostgreSQL rejects NUL in `text` values, so there is no escaping of it that
      would be honest about what the database will store.
      """
    end

    escaped = String.replace(value, "'", "''")

    if String.contains?(escaped, "\\") do
      # `E'…'` so the meaning does not depend on `standard_conforming_strings`,
      # which a legacy database may well have turned off. This is exactly what
      # PostgreSQL's own `quote_literal()` does.
      "E'" <> String.replace(escaped, "\\", "\\\\") <> "'"
    else
      "'" <> escaped <> "'"
    end
  end

  # --- types -------------------------------------------------------------------

  # The Ash types whose PostgreSQL spelling is not their `Ash.Type.storage_type/2`.
  #
  # Ash's storage type is an *Ecto* type, and the last mile from Ecto to Postgres
  # is where the interesting cases live: `Ash.Type.CiString`'s storage type is
  # `:ci_string`, which is not a Postgres type name at all, and `Ash.Type.String`'s
  # is `:string`, which Ecto renders as `varchar(255)` — wrong for a legacy `text`
  # column.
  #
  # This table mirrors `AshPostgres.MigrationGenerator`'s private
  # `migration_type/2` and `migration_type_from_storage_type/1`
  # (`deps/ash_postgres/lib/migration_generator/migration_generator.ex:4435-4482`
  # in ash_postgres 2.11.0), which are the same knowledge and not reachable from
  # outside the module. Keeping it short and citing where it came from is the
  # honest form of a restatement that cannot be avoided; asking Ecto is not an
  # option, because Ecto has no opinion about `citext`.
  #
  # `Ash.Type.UtcDatetime*` renders `timestamptz` here rather than AshPostgres's
  # `timestamp`, and the difference is deliberate. This function only ever renders
  # an *explicit* `type/2` cast, and a compatibility view is reading a legacy
  # column: an explicit cast to a UTC datetime means "produce an instant", which
  # is `timestamptz`. If the intent is instead "this naive column is recorded in
  # zone X", that is `zone:`, which never emits a cast at all — see the `:at_zone`
  # clause above for why the cast form could not carry an index anyway.
  @pg_types %{
    Ash.Type.CiString => "citext",
    Ash.Type.String => "text",
    Ash.Type.Atom => "text",
    Ash.Type.UUID => "uuid",
    Ash.Type.UUIDv7 => "uuid",
    Ash.Type.Integer => "bigint",
    Ash.Type.Float => "float",
    Ash.Type.Decimal => "decimal",
    Ash.Type.Boolean => "boolean",
    Ash.Type.Date => "date",
    Ash.Type.Time => "time",
    Ash.Type.TimeUsec => "time",
    Ash.Type.NaiveDatetime => "timestamp",
    Ash.Type.UtcDatetime => "timestamptz",
    Ash.Type.UtcDatetimeUsec => "timestamptz",
    Ash.Type.Map => "jsonb",
    Ash.Type.Keyword => "jsonb",
    Ash.Type.Struct => "jsonb",
    Ash.Type.Binary => "bytea"
  }

  @doc """
  The PostgreSQL type name for an Ash type.

  A bare string passes through, so `expr(type(x, "citext"))` and a Postgres type
  the table below does not know about both work.

      iex> AshStrangler.Sql.Printer.pg_type!(:ci_string)
      "citext"

      iex> AshStrangler.Sql.Printer.pg_type!(:uuid)
      "uuid"

      iex> AshStrangler.Sql.Printer.pg_type!("hstore")
      "hstore"
  """
  @spec pg_type!(term()) :: String.t()
  def pg_type!(type) when is_binary(type), do: type

  def pg_type!({:array, inner}), do: pg_type!(inner) <> "[]"

  def pg_type!(type) do
    case resolve_type(type) do
      {:ok, resolved} ->
        Map.get_lazy(@pg_types, resolved, fn -> from_storage_type(resolved) end)

      :error ->
        to_string(type)
    end
  end

  defp from_storage_type(resolved) do
    case Ash.Type.storage_type(resolved, []) do
      nil -> to_string(resolved)
      storage when is_atom(storage) -> to_string(storage)
      other -> to_string(other)
    end
  end

  defp resolve_type(type) do
    case Ash.Type.get_type(type) do
      nil -> :error
      resolved -> {:ok, resolved}
    end
  rescue
    _ -> :error
  end

  defp attribute_name(%Ref{attribute: attribute}) when is_atom(attribute), do: attribute
  defp attribute_name(%Ref{attribute: %{name: name}}), do: name

  @doc """
  A reference frame that renders every reference as a bare column name.

  Used by the expression index, where the primary relation is the only table in
  scope, and by the `:read_from_new` reverse view, where references are attributes
  of the stored table.
  """
  @spec bare_frame(Ash.Resource.t() | nil) :: ref_fun()
  def bare_frame(twin \\ nil) do
    fn {path, attribute} -> column_name(twin, path, attribute) end
  end

  @doc """
  A reference frame that qualifies every reference with the relation it came
  from — the primary alias for the primary relation, the relationship name for a
  joined one.
  """
  @spec qualified_frame(Ash.Resource.t(), String.t()) :: ref_fun()
  def qualified_frame(twin, primary_alias) do
    fn
      {[], attribute} ->
        "#{primary_alias}.#{column_name(twin, [], attribute)}"

      {path, attribute} ->
        "#{to_string(List.last(path))}.#{column_name(twin, path, attribute)}"
    end
  end

  @doc """
  A reference frame that renders references as `NEW.<attribute>` — the trigger
  frame, where references name *resource attributes* of the incoming view row
  rather than legacy columns.

  This is what the deleted `String.replace(to, "$NEW.", "NEW.")` was doing by
  hand, and why the DSL needed a `$NEW.` sigil for authors to type. The sigil is
  gone: an expression over attributes says what it means, and the frame decides
  how a reference to one is spelled.
  """
  @spec new_frame() :: ref_fun()
  def new_frame, do: fn {_path, attribute} -> "NEW.#{attribute}" end

  defp column_name(nil, _path, attribute), do: to_string(attribute)

  defp column_name(twin, path, attribute) do
    case AshStrangler.Twin.resource_at(twin, path) do
      {:ok, resource} -> AshStrangler.Twin.column!(resource, attribute)
      {:error, _} -> to_string(attribute)
    end
  end

  @doc """
  Rewrites every literal leaf into a raw `Ash.Query.Function.Fragment`, so an
  expression handed to `AshSql` renders with **zero** bound parameters.

  Not used by `to_sql/2`, which owns its own rendering — this exists for the
  differential oracle in `test/ash_strangler/sql/printer_test.exs`, where the
  same expression is rendered both by this module and by
  `AshSql.Expr.dynamic_expr/6` and the two are compared by executing them. It is
  the pass the design named as the primary implementation strategy; keeping it as
  the oracle rather than the renderer is what §8 of `the-transform-layer` records
  as the reason.
  """
  @spec inline_literals(AshStrangler.Expr.t()) :: AshStrangler.Expr.t()
  def inline_literals(expr) do
    StranglerExpr.map(expr, fn
      # Two argument positions are not values, and inlining them produces an
      # expression `AshSql` then rejects rather than a wrong one -- which is the
      # better failure, but only if it never happens. A `fragment`'s first argument
      # is its template (*"First argument to `fragment` must be a string"*) and
      # `type/2`'s second is a type (*"unsupported type"*).
      %Call{name: :fragment, args: [template | args]} = call when is_binary(template) ->
        %{call | args: [template | args]}

      %Call{name: :type, args: [value, type | rest]} = call ->
        %{call | args: [value, type | rest]}

      %Call{} = call ->
        call

      # `Ash.Filter.map/2` hands each of these to the callback as a whole node, so
      # without a pass-through they fall to the `leaf ->` clause and an entire
      # subtree is replaced by one raw fragment. Reproducer, before this existed:
      # `inline_literals(expr(id > 0 and not is_nil(login)))` raised
      # "not is_nil(login) cannot be rendered as a SQL literal".
      %BooleanExpression{} = boolean ->
        boolean

      %Not{} = negation ->
        negation

      %Exists{} = exists ->
        exists

      %Ref{} = ref ->
        ref

      %Ash.CustomExpression{} = custom ->
        custom

      list when is_list(list) ->
        list

      {key, value} when is_atom(key) ->
        {key, value}

      nil ->
        nil

      leaf ->
        %Ash.Query.Function.Fragment{arguments: [raw: literal(leaf)]}
    end)
  end
end
