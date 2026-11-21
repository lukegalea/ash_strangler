# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.EvalDifferential do
  @moduledoc """
  PostgreSQL as the oracle for `AshStrangler.Eval`.

  A lens expression is printed by `AshStrangler.Sql.Printer` with every reference
  replaced by a typed literal, executed as `SELECT <expr>`, and the result is
  compared with the value the BEAM evaluator computes from the same values. The
  two read one expression tree; a disagreement means the evaluator's meaning of a
  node is not PostgreSQL's.
  """

  use ExUnitProperties
  import StreamData

  alias AshStrangler.Sql.Printer
  alias AshStrangler.Test.Generators
  alias AshStrangler.TestRepo

  @doc "A generator of `%{attribute => value}` for every attribute of `resource`."
  def row(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attribute -> {attribute.name, value(attribute)} end)
    |> fixed_map()
  end

  defp value(%{type: type, constraints: constraints, allow_nil?: allow_nil?} = attribute) do
    generator = typed(Ash.Type.get_type(type), constraints, attribute)
    if allow_nil?, do: Generators.nilable(generator), else: generator
  end

  defp typed(_type, [{:one_of, values} | _], _attribute), do: member_of(values)

  defp typed(Ash.Type.Atom, constraints, _attribute) do
    case Keyword.get(constraints, :one_of) do
      nil -> member_of([:alpha, :beta])
      values -> member_of(values)
    end
  end

  defp typed(Ash.Type.UUID, _constraints, _attribute),
    do: map(integer(), fn _ -> Ash.UUID.generate() end)

  defp typed(Ash.Type.Boolean, _constraints, _attribute), do: boolean()
  defp typed(Ash.Type.Integer, _constraints, _attribute), do: integer(-100_000..100_000)

  defp typed(type, _constraints, _attribute) when type in [Ash.Type.String, Ash.Type.CiString],
    do: Generators.adversarial_text()

  defp typed(Ash.Type.NaiveDatetime, _constraints, _attribute), do: naive()

  defp typed(type, _constraints, _attribute)
       when type in [Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime, Ash.Type.DateTime],
       do: map(naive(), &DateTime.from_naive!(&1, "Etc/UTC"))

  defp naive do
    gen all(seconds <- integer(0..2_000_000_000), micro <- integer(0..999_999)) do
      ~N[2000-01-01 00:00:00.000000]
      |> NaiveDateTime.add(seconds, :second)
      |> Map.put(:microsecond, {micro, 6})
    end
  end

  @doc "The value PostgreSQL computes for `expression` with `values` bound by `types`."
  def sql(expression, values, resource, opts \\ []) do
    frame = fn {[], name} -> typed_literal(Map.fetch!(values, name), resource, name) end
    printed = Printer.to_sql(expression, [ref: frame] ++ opts)

    %Postgrex.Result{rows: [[result]]} = TestRepo.query!("SELECT " <> printed, [])
    result
  end

  defp typed_literal(value, resource, name) do
    type = Ash.Resource.Info.attribute(resource, name).type
    pg = Printer.pg_type!(type)
    if is_nil(value), do: "NULL::#{pg}", else: "(#{Printer.literal(value)})::#{pg}"
  end

  @doc "True when two results are the same value once representation is set aside."
  def same?(beam, <<_::128>> = sql) when is_binary(beam) and byte_size(beam) == 36,
    do: beam == Ecto.UUID.load!(sql)

  def same?(beam, sql), do: norm(beam) == norm(sql)

  def norm(%Ash.CiString{} = value), do: Ash.CiString.value(value)
  def norm(%DateTime{} = value), do: {:instant, DateTime.to_unix(value, :microsecond)}
  def norm(%NaiveDateTime{} = value), do: {:naive, NaiveDateTime.to_iso8601(value)}
  def norm(%Decimal{} = value), do: Decimal.to_string(Decimal.normalize(value))

  def norm(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def norm(value) when is_float(value), do: Float.round(value, 9)
  def norm(value), do: value
end
