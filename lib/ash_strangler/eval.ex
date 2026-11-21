# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Eval do
  @moduledoc """
  The BEAM evaluator for a `%AshStrangler.Lens{}`: `get` and `put` over plain
  values, with no database and no twin.

  `AshStrangler.Sql.Printer` renders a lens into SQL for a view or a trigger.
  This module evaluates the **same expression trees** in the BEAM, for a caller
  that holds rows already read (a façade over an Ash resource) and has no
  relation to render SQL against. The two are held to one meaning by a property
  test: for generated rows, the value this module computes equals the value
  PostgreSQL computes from the printed SQL.

  ## SQL semantics, not Elixir semantics

  A value of `nil` is SQL `NULL`. Comparison and arithmetic with `NULL` give
  `NULL`; `and`, `or` and `not` are three-valued; `CASE` takes the `ELSE` when its
  condition is `NULL`; `||` (Ash's null-default) is `coalesce`; `<>` is SQL's
  `||` and propagates `NULL`. An atom compares equal to the string it prints as,
  because that is what the printer's literal does.

  ## `get` and `put`

    * `forward/3` is `get`: the attribute's value from a source row.
    * `put/3` is the reverse: `{:ok, [{column, value}]}` from the attribute values
      being written, or `{:error, {:read_only, because}}` when the lens has no
      reverse. It reads only the incoming attributes; the one exception is a
      `touch()` or a held column, which read the stored row given as `:prior`.

  ## Tiers

  Tier 1 is the single-source combinators: `map` (rename, derived cast, `zone:`),
  `decode`, `negate`, `affine`, `coalesce`, `constant` and `unmapped`. Tier 2 adds
  `concat`, `collapse` over source-attribute guards, and `reference`.
  `evaluable?/1` is the boundary: a `fragment` (other than the `split_part` a
  `concat` writes), an extension column, a join, or an `exists` is refused with
  `AshStrangler.Eval.Unsupported`, naming the node.

  ## Forbidden fields

  A source value that is an `Ash.ForbiddenField` makes the result a
  `%Ash.ForbiddenField{}` named for the lens's attribute, and nothing is
  computed from it. A reader without the source column's grant therefore sees a
  forbidden field through the lens, never the value, and never a value derived
  from it.
  """

  alias Ash.Query.{BooleanExpression, Call, Exists, Not, Ref}
  alias AshStrangler.{Expr, Lens}

  defmodule Unsupported do
    @moduledoc "Raised for an expression outside the evaluable tiers."
    defexception [:message]
  end

  @doc """
  The value of `lens`'s attribute from `row`, a map keyed by source attribute.

  Options: `:now` (a `DateTime`, for `now()`).
  """
  @spec forward(Lens.t(), map(), keyword()) :: term()
  def forward(%Lens{forward: nil, combinator: :unmapped}, _row, _opts), do: nil

  def forward(%Lens{forward: nil}, _row, _opts),
    do: unsupported!("a key lens, which has no expression,")

  def forward(%Lens{} = lens, row, opts) do
    case Enum.find_value(lens.sources, &forbidden(row, &1)) do
      nil ->
        eval(lens.forward, context(opts, fn ref -> fetch!(row, ref) end))

      %Ash.ForbiddenField{} ->
        # Fresh, never the source's struct: it can carry `original_value`.
        %Ash.ForbiddenField{field: lens.attribute, type: :attribute}
    end
  end

  def forward(lens, row), do: forward(lens, row, [])

  @doc """
  The legacy columns a write of `attributes` stores, through `lens`.

  `attributes` maps attribute names to the incoming values. Options: `:now`, and
  `:prior` (`%{attributes: %{}, columns: %{}}`, the stored row an update starts
  from; without it the write is an insert).
  """
  @spec put(Lens.t(), map(), keyword()) ::
          {:ok, [{atom(), term()}]} | {:error, {:read_only, String.t() | nil}}
  def put(%Lens{writes: []} = lens, _attributes, _opts), do: {:error, {:read_only, lens.because}}

  def put(%Lens{writes: writes}, attributes, opts) do
    ctx =
      opts
      |> context(fn ref -> fetch!(attributes, ref) end)
      |> Map.put(:prior, Keyword.get(opts, :prior))

    {:ok, Enum.map(writes, fn {column, expression} -> {column, eval(expression, ctx)} end)}
  end

  def put(lens, attributes), do: put(lens, attributes, [])

  @doc """
  True when `lens` can be evaluated here, in both directions: it holds no node
  outside the evaluable set.
  """
  @spec evaluable?(Lens.t()) :: boolean()
  def evaluable?(%Lens{forward: forward, writes: writes, combinator: combinator}) do
    combinator not in [:extension, :tenant, :opaque] and
      Enum.all?([forward | Enum.map(writes, &elem(&1, 1))], &evaluable_tree?/1)
  end

  defp evaluable_tree?(expression) when is_map(expression) and not is_struct(expression),
    do: Enum.all?(Map.values(expression), &evaluable_tree?/1)

  defp evaluable_tree?(expression) do
    Expr.reduce(expression, true, fn
      %Call{name: name}, ok when name in [:strangler_ext, :strangler_ext_state] ->
        ok and false

      %Call{name: :fragment, args: ["split_part(?, ?, ?)" | _]}, ok ->
        ok

      %Call{name: :fragment}, _ok ->
        false

      %Exists{}, _ok ->
        false

      %Ref{relationship_path: [_ | _]}, _ok ->
        false

      _node, ok ->
        ok
    end)
  end

  # --- context -----------------------------------------------------------------

  defp context(opts, ref) do
    %{ref: ref, now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0), prior: nil}
  end

  defp fetch!(source, {[], name}) do
    case Map.fetch(source, name) do
      {:ok, %Ash.NotLoaded{}} -> raise ArgumentError, "#{inspect(name)} is not loaded"
      {:ok, value} -> value
      :error -> raise ArgumentError, "no value for #{inspect(name)}"
    end
  end

  defp fetch!(_source, {path, name}),
    do: unsupported!("the reference #{inspect(Enum.join(path ++ [name], "."))} crosses a join")

  defp forbidden(row, {[], name}) do
    case Map.get(row, name) do
      %Ash.ForbiddenField{} = forbidden -> forbidden
      _ -> nil
    end
  end

  defp forbidden(_row, _source), do: nil

  # --- references and literals ---------------------------------------------------

  defp eval(%Ref{relationship_path: path, attribute: attribute}, ctx) when is_atom(attribute),
    do: ctx.ref.({path, attribute})

  defp eval(%Ref{relationship_path: path, attribute: %{name: name}}, ctx),
    do: ctx.ref.({path, name})

  defp eval(%Ash.CustomExpression{expression: inner}, ctx), do: eval(inner, ctx)

  defp eval(%BooleanExpression{op: :and, left: left, right: right}, ctx),
    do: and3(eval(left, ctx), fn -> eval(right, ctx) end)

  defp eval(%BooleanExpression{op: :or, left: left, right: right}, ctx),
    do: or3(eval(left, ctx), fn -> eval(right, ctx) end)

  defp eval(%Not{expression: inner}, ctx), do: not3(eval(inner, ctx))

  defp eval(%Exists{}, _ctx), do: unsupported!("exists(...)")

  # --- operators ---------------------------------------------------------------

  defp eval(%Call{name: :==, args: [left, nil]}, ctx), do: is_nil(eval(left, ctx))
  defp eval(%Call{name: :==, args: [nil, right]}, ctx), do: is_nil(eval(right, ctx))
  defp eval(%Call{name: :!=, args: [left, nil]}, ctx), do: not is_nil(eval(left, ctx))
  defp eval(%Call{name: :!=, args: [nil, right]}, ctx), do: not is_nil(eval(right, ctx))

  defp eval(%Call{name: :<>, args: [left, right]}, ctx) do
    with left when not is_nil(left) <- eval(left, ctx),
         right when not is_nil(right) <- eval(right, ctx) do
      text(left) <> text(right)
    end
  end

  defp eval(%Call{name: :||, args: [left, right]}, ctx) do
    case eval(left, ctx) do
      nil -> eval(right, ctx)
      value -> value
    end
  end

  defp eval(%Call{name: :not, args: [arg]}, ctx), do: not3(eval(arg, ctx))
  defp eval(%Call{name: :and, args: [l, r]}, ctx), do: and3(eval(l, ctx), fn -> eval(r, ctx) end)
  defp eval(%Call{name: :or, args: [l, r]}, ctx), do: or3(eval(l, ctx), fn -> eval(r, ctx) end)
  defp eval(%Call{name: :-, args: [arg]}, ctx), do: arithmetic(:-, 0, eval(arg, ctx))

  defp eval(%Call{name: :in, args: [left, values]}, ctx) when is_list(values) do
    case eval(left, ctx) do
      nil ->
        nil

      value ->
        results = Enum.map(values, &compare(:==, value, eval(&1, ctx)))

        cond do
          Enum.any?(results, &(&1 == true)) -> true
          Enum.any?(results, &is_nil/1) -> nil
          true -> false
        end
    end
  end

  defp eval(%Call{name: name, args: [left, right]}, ctx)
       when name in [:==, :!=, :>, :>=, :<, :<=],
       do: compare(name, eval(left, ctx), eval(right, ctx))

  defp eval(%Call{name: name, args: [left, right]}, ctx) when name in [:+, :-, :*, :/],
    do: arithmetic(name, eval(left, ctx), eval(right, ctx))

  # --- functions ---------------------------------------------------------------

  defp eval(%Call{name: :is_nil, args: [arg]}, ctx), do: is_nil(eval(arg, ctx))

  defp eval(%Call{name: :if, args: [condition, branches]}, ctx) when is_list(branches) do
    if eval(condition, ctx) == true do
      eval(Keyword.get(branches, :do), ctx)
    else
      eval(Keyword.get(branches, :else), ctx)
    end
  end

  defp eval(%Call{name: :strangler_case, args: [subject, pairs, default]}, ctx) do
    subject = eval(subject, ctx)

    Enum.find_value(pairs, :no_match, fn {match, result} ->
      if compare(:==, subject, eval(match, ctx)) == true, do: {:match, result}
    end)
    |> case do
      {:match, result} -> eval(result, ctx)
      :no_match when default == :none -> nil
      :no_match -> eval(default, ctx)
    end
  end

  defp eval(%Call{name: :strangler_hold, args: [column, fallback]}, ctx) do
    case ctx.prior do
      nil -> eval(fallback, ctx)
      %{columns: columns} -> stored(columns, column)
    end
  end

  defp eval(%Call{name: :strangler_touch, args: [column, attribute]}, ctx) do
    case ctx.prior do
      nil ->
        ctx.now

      %{attributes: attributes, columns: columns} ->
        if distinct?(Map.get(attributes, attribute), ctx.ref.({[], attribute})),
          do: ctx.now,
          else: stored(columns, column)
    end
  end

  defp eval(%Call{name: :strangler_v8, args: [registry, kind, parts]}, ctx) do
    AshStrangler.KeyKinds.encode(registry, kind, Enum.map(parts, &eval(&1, ctx)))
  end

  defp eval(%Call{name: :strangler_v8_part, args: [registry, kind, index, uuid]}, ctx) do
    case eval(uuid, ctx) do
      nil ->
        nil

      uuid ->
        {:ok, parts} = AshStrangler.KeyKinds.decode(registry, kind, uuid)
        Enum.at(parts, index)
    end
  end

  defp eval(%Call{name: :type, args: [value, type | _rest]}, ctx),
    do: cast(eval(value, ctx), type)

  defp eval(%Call{name: :at_zone, args: [value, zone]}, ctx), do: at_zone(eval(value, ctx), zone)

  defp eval(
         %Call{name: :fragment, args: ["split_part(?, ?, ?)", string, separator, position]},
         ctx
       ) do
    with string when not is_nil(string) <- eval(string, ctx),
         separator when not is_nil(separator) <- eval(separator, ctx),
         position when not is_nil(position) <- eval(position, ctx) do
      split_part(text(string), text(separator), position)
    end
  end

  defp eval(%Call{name: :fragment, args: [template | _]}, _ctx),
    do: unsupported!("fragment(#{inspect(template)})")

  defp eval(%Call{name: :now, args: []}, ctx), do: ctx.now
  defp eval(%Call{name: :today, args: []}, ctx), do: DateTime.to_date(ctx.now)

  defp eval(%Call{name: name, args: args}, ctx)
       when name in [
              :string_downcase,
              :string_upcase,
              :string_trim,
              :string_length,
              :abs,
              :round,
              :ceil,
              :floor,
              :least,
              :greatest
            ] do
    function(name, Enum.map(args, &eval(&1, ctx)))
  end

  defp eval(%Call{name: name, args: args}, _ctx),
    do: unsupported!("#{name}/#{length(args)}")

  defp eval(literal, _ctx), do: literal

  # --- three-valued logic ------------------------------------------------------

  defp not3(nil), do: nil
  defp not3(value), do: not value

  defp and3(false, _right), do: false

  defp and3(left, right) do
    case {left, right.()} do
      {_, false} -> false
      {true, true} -> true
      _ -> nil
    end
  end

  defp or3(true, _right), do: true

  defp or3(left, right) do
    case {left, right.()} do
      {_, true} -> true
      {false, false} -> false
      _ -> nil
    end
  end

  # --- values ------------------------------------------------------------------

  # Atoms print as the string they name, so they compare as that string. A
  # `CiString` compares case-insensitively, as `citext` does.
  defp normalize(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp normalize(%Ash.CiString{} = value), do: Ash.CiString.to_comparable_string(value)
  defp normalize(value), do: value

  defp text(%Ash.CiString{} = value), do: Ash.CiString.value(value)
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  defp compare(_op, nil, _right), do: nil
  defp compare(_op, _left, nil), do: nil

  defp compare(op, left, right) do
    left = normalize(left)
    right = normalize(right)
    order = order(left, right)

    case op do
      :== -> order == :eq
      :!= -> order != :eq
      :> -> order == :gt
      :>= -> order in [:gt, :eq]
      :< -> order == :lt
      :<= -> order in [:lt, :eq]
    end
  end

  defp order(%Decimal{} = l, r), do: Decimal.compare(l, decimal(r)) |> decimal_order()
  defp order(l, %Decimal{} = r), do: Decimal.compare(decimal(l), r) |> decimal_order()
  defp order(%DateTime{} = l, %DateTime{} = r), do: DateTime.compare(l, r)
  defp order(%NaiveDateTime{} = l, %NaiveDateTime{} = r), do: NaiveDateTime.compare(l, r)
  defp order(%Date{} = l, %Date{} = r), do: Date.compare(l, r)
  defp order(l, r) when l == r, do: :eq
  defp order(l, r) when l < r, do: :lt
  defp order(_l, _r), do: :gt

  defp decimal_order(:eq), do: :eq
  defp decimal_order(:lt), do: :lt
  defp decimal_order(:gt), do: :gt

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp stored(columns, column),
    do: Enum.find_value(columns, fn {name, value} -> if to_string(name) == column, do: value end)

  defp distinct?(left, right),
    do: if(is_nil(left) and is_nil(right), do: false, else: left != right)

  defp arithmetic(_op, nil, _right), do: nil
  defp arithmetic(_op, _left, nil), do: nil

  defp arithmetic(op, left, right) when is_struct(left, Decimal) or is_struct(right, Decimal) do
    left = decimal(left)
    right = decimal(right)

    case op do
      :+ -> Decimal.add(left, right)
      :- -> Decimal.sub(left, right)
      :* -> Decimal.mult(left, right)
      :/ -> Decimal.div(left, right)
    end
  end

  # SQL's `integer / integer` truncates toward zero, as `div/2` does.
  defp arithmetic(:/, left, right) when is_integer(left) and is_integer(right),
    do: div(left, right)

  defp arithmetic(:/, left, right), do: left / right
  defp arithmetic(:+, left, right), do: left + right
  defp arithmetic(:-, left, right), do: left - right
  defp arithmetic(:*, left, right), do: left * right

  # The casts a lens derives. An Ash type is cast as Ash would; a Postgres type
  # name is a small closed table, because the evaluator will not guess at one it
  # does not know.
  defp cast(nil, _type), do: nil

  defp cast(value, type) when is_binary(type) do
    case String.replace_suffix(type, "[]", "") do
      t when t in ["text", "varchar", "character varying"] -> text(value)
      "citext" -> Ash.CiString.new(text(value))
      t when t in ["integer", "int4", "bigint", "int8", "smallint"] -> to_integer(value)
      t when t in ["numeric", "decimal"] -> decimal(value)
      t when t in ["double precision", "float8", "real"] -> to_float(value)
      "boolean" -> value
      "uuid" -> text(value)
      _other -> unsupported!("a cast to #{inspect(type)}")
    end
  end

  defp cast(value, type) do
    case Ash.Type.cast_input(Ash.Type.get_type(type), value, []) do
      {:ok, cast} -> cast
      _ -> unsupported!("a cast of #{inspect(value)} to #{inspect(type)}")
    end
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: round(value)
  defp to_integer(%Decimal{} = value), do: value |> Decimal.round() |> Decimal.to_integer()
  defp to_integer(value), do: value |> text() |> String.to_integer()

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  # `timestamp AT TIME ZONE z` is the instant that wall-clock time is in `z`;
  # `timestamptz AT TIME ZONE z` is the wall-clock time `z` shows for the instant.
  defp at_zone(nil, _zone), do: nil

  defp at_zone(value, zone) do
    if String.upcase(zone) in ["UTC", "ETC/UTC"],
      do: shift_to_utc(value),
      else: shift_to_zone(value, zone)
  end

  defp shift_to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp shift_to_utc(%DateTime{} = instant),
    do: instant |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp shift_to_zone(%NaiveDateTime{} = naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, instant} ->
        instant

      _ ->
        unsupported!(
          "the time zone #{inspect(zone)} (no time zone database, or an ambiguous time)"
        )
    end
  end

  defp shift_to_zone(%DateTime{} = instant, zone) do
    case DateTime.shift_zone(instant, zone) do
      {:ok, shifted} -> DateTime.to_naive(shifted)
      _ -> unsupported!("the time zone #{inspect(zone)} (no time zone database)")
    end
  end

  # PostgreSQL's `split_part`: 1-based, `''` past the last part.
  defp split_part(string, separator, position) when position > 0 do
    string |> String.split(separator) |> Enum.at(position - 1, "")
  end

  defp function(name, args) do
    if name not in [:least, :greatest] and Enum.any?(args, &is_nil/1) do
      nil
    else
      apply_function(name, args)
    end
  end

  defp apply_function(:string_downcase, [v]), do: v |> text() |> String.downcase(:ascii)
  defp apply_function(:string_upcase, [v]), do: v |> text() |> String.upcase(:ascii)
  defp apply_function(:string_trim, [v]), do: v |> text() |> String.trim(" ")
  defp apply_function(:string_length, [v]), do: v |> text() |> String.length()
  defp apply_function(:abs, [v]), do: if(is_struct(v, Decimal), do: Decimal.abs(v), else: abs(v))
  defp apply_function(:round, [v]), do: to_integer(v)
  defp apply_function(:ceil, [v]), do: Float.ceil(v * 1.0) |> trunc()
  defp apply_function(:floor, [v]), do: Float.floor(v * 1.0) |> trunc()
  defp apply_function(:least, args), do: args |> Enum.reject(&is_nil/1) |> extreme(:lt)
  defp apply_function(:greatest, args), do: args |> Enum.reject(&is_nil/1) |> extreme(:gt)

  defp extreme([], _direction), do: nil

  defp extreme(values, direction),
    do:
      Enum.reduce(values, fn value, best ->
        if order(value, best) == direction, do: value, else: best
      end)

  defp unsupported!(what),
    do: raise(Unsupported, "#{what} is outside the expressions AshStrangler.Eval evaluates")
end
