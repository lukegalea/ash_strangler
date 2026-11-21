# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Translate do
  @moduledoc """
  Filter and sort translation through a forward lens.

  A façade filters and sorts on its own attributes, and the rows come from a
  source resource that has never heard of them. This module rewrites a filter
  or a sort over the façade's attributes into one over the source's, so the
  source's data layer does the work (and the source's policies still decide what
  it may see).

  `lenses` is the map `AshStrangler.Lens.over/3` returns.

  ## Two rewrites

    * **Forward substitution** (always sound). Each façade attribute becomes
      its lens's forward expression over the source: a rename is the source
      attribute, a `decode` is a `CASE`, a `concat` is the concatenation.
    * **Backward rewrite** (an optimisation, taken only when it is exact). A
      comparison of an invertible, single-column lens with a literal (`==`,
      `!=`, `in`) is rewritten to compare the source column with the literal put
      through the lens. `state == :finished` becomes `status == :done` with no
      `CASE`, so the source's index applies. It is not taken when the put of a
      literal has no encoding (the forward substitution is then the answer), and
      never for a lens whose reverse is not exact (`affine`, a cast, `concat`).

  ## What is refused

  A reference with a relationship path, `exists/2`, `parent/1`, and any
  expression whose forward direction needs SQL the Ash expression language does
  not have (`fragment`, a time-zone shift, an extension column). The error names
  the node: a filter that cannot be translated must not be silently dropped,
  because that widens the result.

  Filtering or sorting on a field the viewer may not read is the source's
  decision, not this module's: the translated expression names the source
  column, and the source's own secured-field check refuses it there.
  """

  alias Ash.Query.Ref
  alias AshStrangler.{Eval, Expr, Lens}

  # The combinators whose reverse is exact for a comparison with a literal: a
  # rename, a decode table and a negation. An `affine` is not (integer division
  # makes `3 * x + 7 == 8` true of `x == 0`), a `cast` is not (a case-insensitive
  # comparison must stay case-insensitive), and a `concat` is not injective.
  @exact [:rename, :decode, :negate]

  @comparisons [Ash.Query.Operator.Eq, Ash.Query.Operator.NotEq, Ash.Query.Operator.In]

  @doc """
  Translates a filter expression over the façade's attributes (hydrated against
  the façade, as `query.filter` is) into one over `source`, hydrated against it.
  """
  @spec filter(%{atom() => Lens.t()}, term(), Ash.Resource.t()) ::
          {:ok, term()} | {:error, term()}
  def filter(lenses, %Ash.Filter{expression: expression}, source),
    do: filter(lenses, expression, source)

  def filter(_lenses, nil, _source), do: {:ok, nil}

  def filter(lenses, expression, source) do
    {:ok,
     Ash.Filter.map(expression, fn
       %Ref{relationship_path: [_ | _]} = ref ->
         refuse!(ref, "a reference through a relationship")

       %Ref{} = ref ->
         {:halt, forward_expression!(lenses, ref, source)}

       %{__struct__: struct} = node when struct in [Ash.Query.Exists, Ash.Query.Parent] ->
         refuse!(node, inspect(struct))

       %{__struct__: struct, left: %Ref{relationship_path: []} = ref} = node
       when struct in @comparisons ->
         rewrite_comparison(lenses, node, ref, source)

       other ->
         other
     end)}
  catch
    {:untranslatable, reason} -> {:error, {:untranslatable, reason}}
  end

  @doc """
  Translates a sort over the façade's attributes into one over the source.

  Each `{attribute, direction}` becomes `{source_attribute, direction}` when the
  lens is a rename, and `{expression, direction}` (the forward expression, which
  the source's data layer sorts by) otherwise. A decode therefore sorts by the
  decoded value, which is the order the façade's reader sees.
  """
  @spec sort(%{atom() => Lens.t()}, [{atom() | struct(), atom()}]) ::
          {:ok, [{atom() | term(), atom()}]} | {:error, term()}
  def sort(lenses, sort) do
    {:ok,
     Enum.map(sort, fn {field, direction} ->
       lens = lens!(lenses, field_name(field))

       case Expr.simple_reference(lens.forward) do
         {:ok, column} -> {column, direction}
         :error -> {ash_expression!(lens.forward), direction}
       end
     end)}
  catch
    {:untranslatable, reason} -> {:error, {:untranslatable, reason}}
  end

  # --- forward substitution ---------------------------------------------------

  defp forward_expression!(lenses, %Ref{attribute: attribute}, source) do
    lens = lens!(lenses, field_name(attribute))
    expression = ash_expression!(lens.forward)

    case Ash.Filter.hydrate_refs(expression, %{resource: source, public?: false}) do
      {:ok, hydrated} -> hydrated
      {:error, error} -> refuse!(expression, "it does not hydrate against the source: #{inspect(error)}")
    end
  end

  defp lens!(lenses, name) do
    case Map.get(lenses, name) do
      %Lens{forward: forward} = lens when not is_nil(forward) or lens.combinator == :unmapped ->
        lens

      _ ->
        refuse!(name, "it has no forward lens")
    end
  end

  defp field_name(%{name: name}), do: name
  defp field_name(name) when is_atom(name), do: name

  # --- backward rewrite -------------------------------------------------------

  defp rewrite_comparison(lenses, node, %Ref{attribute: attribute}, source) do
    with %Lens{combinator: combinator, writes: [{column, _backward}]} = lens
         when combinator in @exact <- Map.get(lenses, field_name(attribute)),
         true <- Eval.evaluable?(lens),
         {:ok, values} <- encode(lens, column, node.right),
         {:ok, source_ref} <- source_ref(column, source) do
      {:halt, %{node | left: source_ref, right: values}}
    else
      # Not rewritten: the walk goes on to the reference, which forward
      # substitution replaces.
      _ -> node
    end
  end

  defp encode(lens, column, %MapSet{} = values) do
    with {:ok, encoded} <- encode_all(lens, column, MapSet.to_list(values)),
         do: {:ok, MapSet.new(encoded)}
  end

  defp encode(lens, column, values) when is_list(values), do: encode_all(lens, column, values)

  defp encode(lens, column, value) do
    with {:ok, [encoded]} <- encode_all(lens, column, [value]), do: {:ok, encoded}
  end

  defp encode_all(lens, column, values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      nil, _acc ->
        {:halt, :error}

      value, {:ok, acc} ->
        case Eval.put(lens, %{lens.attribute => value}) do
          {:ok, [{^column, encoded}]} when not is_nil(encoded) -> {:cont, {:ok, [encoded | acc]}}
          _ -> {:halt, :error}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp source_ref(column, source) do
    Ash.Filter.hydrate_refs(
      %Ref{attribute: column, relationship_path: [], resource: nil},
      %{resource: source, public?: false}
    )
  end

  # --- the Ash expression a lens renders to -----------------------------------

  # The lens expression is a closed node set; the SQL printer renders it, this
  # renders it to plain Ash expression nodes. Only `strangler_case` has no Ash
  # spelling and becomes an `if` chain; a node with no Ash equivalent is refused.
  defp ash_expression!(expression) do
    Expr.map(expression, fn
      %Ash.Query.Call{name: :strangler_case, args: [subject, pairs, default]} ->
        otherwise = if default == :none, do: nil, else: default

        pairs
        |> Enum.reverse()
        |> Enum.reduce(otherwise, fn {match, result}, rest ->
          condition = %Ash.Query.Call{name: :==, args: [subject, match], operator?: true, relationship_path: []}
          %Ash.Query.Call{name: :if, args: [condition, [do: result, else: rest]], operator?: false, relationship_path: []}
        end)

      %Ash.Query.Call{name: name} = call
      when name in [:strangler_ext, :strangler_ext_state, :strangler_hold, :strangler_touch,
                    :strangler_v8, :strangler_v8_part, :at_zone, :fragment] ->
        refuse!(call, "#{name} has no Ash expression")

      %Ash.Query.Call{name: :type, args: [_value, type | _]} = call when is_binary(type) ->
        refuse!(call, "a cast to the Postgres type #{inspect(type)}")

      other ->
        other
    end)
  end

  defp refuse!(node, why), do: throw({:untranslatable, {why, node}})
end
