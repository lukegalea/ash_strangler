# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Dsl.Combinators do
  @moduledoc """
  The helpers the `strangler` section imports alongside `Ash.Expr`, and the
  option validator that accepts an expression.

  Two things live here. `touch/0` is the timestamp-preservation marker a
  `collapse` clause's `set:` uses. `expression/1` is the `{:custom, …, :expression, []}`
  validator that lets an option hold an `Ash.Expr` tree, in the same shape
  `Ash.Resource.Calculation.expr_calc/1` uses for `calculate`.
  """

  @touch {:ash_strangler, :touch}

  @doc """
  Marks a `collapse` clause's timestamp column as *preserve unless this is an
  actual transition*.

      state :cancelled, when: expr(not is_nil(cancelled_at)),
                        set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]

  It renders as `now()` on insert, and on update as

      cancelled_at = CASE WHEN <the state is changing> THEN now() ELSE cancelled_at END

  — reading the *old* value straight out of the bare column name, which is what a
  bare column means inside an `UPDATE ... SET`.

  This is the one declared `PutPut` violation in the design, and it is a marker in
  the DSL rather than a generator detail for that reason. Round-tripping
  `:cancelled` cannot recover the original instant; naming the loss is the
  alternative to pretending it does not happen.
  """
  @spec touch() :: {:ash_strangler, :touch}
  def touch, do: @touch

  @doc false
  @spec touch?(term()) :: boolean()
  def touch?(value), do: value == @touch

  @doc false
  # Spark hands an option value here to be validated. Anything that is not a
  # recognised expression node is refused now rather than at SQL-generation time,
  # because a DslError names the file and line and an ArgumentError from a printer
  # names neither.
  #
  # A bare string is refused HERE and allowed by `constant_expression/1`, and the
  # asymmetry is deliberate. `from:` took SQL as a string in 0.1; accepting one
  # would silently reclassify every v1 mapping as an opaque literal instead of
  # failing with an error that names the replacement. `constant`'s expression
  # never had that meaning, so a string there is just a string.
  @spec expression(term()) :: {:ok, term()} | {:error, String.t()}
  def expression(value) when is_binary(value) do
    {:error,
     """
     expected an expression, got the string #{inspect(value)}.

     A raw SQL string is not accepted here. That was 0.1's `from:`, and replacing
     it is the whole of DSL v2 — see `documentation/topics/the-transform-layer.md`.

     For a plain column:            from: #{inspect(String.to_atom(value))}
     For a projection:              from: expr(first_name <> " " <> last_name)
     For SQL with no combinator:    from: expr(fragment(#{inspect(value)}))

     The last form classifies the mapping opaque, which means no derived write
     path, so it also needs `read_only?: true` and a `because:`.
     """}
  end

  def expression(value) do
    if expression?(value) do
      {:ok, value}
    else
      {:error, "expected an expression built with `expr/1`, or a literal, got: #{inspect(value)}"}
    end
  end

  @doc false
  # `constant`'s expression, where a bare string literal is meaningful.
  @spec constant_expression(term()) :: {:ok, term()} | {:error, String.t()}
  def constant_expression(value) when is_binary(value), do: {:ok, value}
  def constant_expression(value), do: expression(value)

  defp expression?(%Ash.Query.Call{}), do: true
  defp expression?(%Ash.Query.Ref{}), do: true
  defp expression?(%Ash.Query.BooleanExpression{}), do: true
  defp expression?(%Ash.Query.Not{}), do: true
  defp expression?(%Ash.Query.Exists{}), do: true
  defp expression?(%Ash.CustomExpression{}), do: true
  defp expression?(%Decimal{}), do: true
  defp expression?(%Date{}), do: true
  defp expression?(%Time{}), do: true
  defp expression?(%NaiveDateTime{}), do: true
  defp expression?(%DateTime{}), do: true
  defp expression?(%Ash.CiString{}), do: true
  defp expression?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp expression?(value) when is_atom(value), do: true
  defp expression?(value) when is_list(value), do: Enum.all?(value, &expression?/1)

  defp expression?(_other), do: false
end
