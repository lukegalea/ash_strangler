# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Expr do
  @moduledoc """
  Structural walks over the **unhydrated** `Ash.Expr` tree a mapping stores.

  ## Why unhydrated, and why this module exists at all

  `Ash.Expr.expr/1` does not build `Ash.Query.Operator.*` or
  `Ash.Query.Function.*` structs. It builds `%Ash.Query.Call{}` for operators
  *and* for `fragment`, with `%Ash.Query.Ref{attribute: :first_name, resource:
  nil}` leaves — bare atoms, no resource. Those become real operator and function
  structs only when `Ash.Filter.hydrate_refs/2` runs, and that needs a resource.

  A `strangler` block is expanded while the resource is still being built, so the
  tree it stores is the unhydrated one. Everything downstream — the view, the
  triggers, the reverse view, the index, the lineage graph, the reconciler —
  needs to read that tree, and none of it needs types. So the walks live here and
  operate on the stored form directly.

  That has a second benefit worth stating, because the alternative was tried
  first. `Ash.Filter.map/2` — the obvious tool — **does not descend into
  `Ash.Query.Parent`, `Ash.Query.Exists` or `Ash.Query.Ref`**; each clause says
  so, and says the caller must handle the internals. A mapping containing
  `exists(...)` would therefore lose every column inside the `exists` from the
  lineage graph, silently, which is the exact failure the deleted regex heuristic
  had.

  `exists/2` is the one node that needs its own clause here regardless of which
  walker is used, because it is where the reference frame *changes*:
  `expr(exists(payments, amount > 0))` builds an `%Ash.Query.Exists{path:
  [:payments], expr: …}`, and `amount` inside it has an empty
  `relationship_path` — it is relative to `payments`, not to the primary
  relation. `refs/1` therefore walks with a path prefix and re-roots those
  references, which is why it is a hand-written recursion rather than a fold over
  `reduce/3`. Getting that wrong would put an edge on the wrong table, which is
  worse than missing it.

  ## Not everything `expr/1` builds is a `Call`

  Four node kinds are not, and each was found by rendering something and watching
  it fail rather than by reading the source, so they are named here:

  | Written | Built |
  |---|---|
  | `a and b`, `a or b` | `%Ash.Query.BooleanExpression{op:, left:, right:}` |
  | `not a` | `%Ash.Query.Not{expression:}` |
  | `exists(rel, …)` | `%Ash.Query.Exists{path:, expr:, at_path:}` |
  | `cond do … end` | nested `%Ash.Query.Call{name: :if}` — desugared by `expr/1` itself |

  Hydration is still needed for **types** — `Ash.Expr.determine_types/4` and the
  type-agreement obligation — and `AshStrangler.Lens.hydrate/2` is the one
  place that crosses the boundary.

  ## The closed node set

  `refs/1` and `AshStrangler.Sql.Printer` accept only the nodes the combinator
  grammar can produce, plus free-form `expr(...)` restricted to the same set.
  Anything else is refused by name, with `fragment(...)` named as the way to say
  "I know, do it anyway". A walker that silently ignored a node it did not
  recognise would drop edges from the lineage graph, which is what the graph
  exists to prevent.
  """

  alias Ash.Query.{BooleanExpression, Call, Exists, Not, Ref}

  @typedoc "An unhydrated expression as stored by the DSL."
  @type t() :: term()

  @typedoc """
  One legacy reference an expression reads: the relationship path it was
  qualified by (empty for the primary relation) and the attribute name.
  """
  @type ref() :: {[atom()], atom()}

  @doc """
  Every reference the expression reads, in first-appearance order.

  This is the lineage primitive: exact rather than inferred, because the tree was
  constructed rather than parsed.

      iex> import Ash.Expr
      iex> AshStrangler.Expr.refs(expr((first_name || "") <> " " <> (last_name || "")))
      [{[], :first_name}, {[], :last_name}]

      iex> import Ash.Expr
      iex> AshStrangler.Expr.refs(expr(if is_deleted, do: "archived", else: "pending"))
      [{[], :is_deleted}]

      iex> import Ash.Expr
      iex> AshStrangler.Expr.refs(expr(exists(payments, amount > 0)))
      [{[], :payments}, {[:payments], :amount}]
  """
  @spec refs(t()) :: [ref()]
  def refs(expr), do: expr |> collect_refs([], []) |> Enum.reverse() |> Enum.uniq()

  defp collect_refs(%Ref{relationship_path: path, attribute: attribute}, prefix, acc)
       when is_atom(attribute) do
    [{prefix ++ path, attribute} | acc]
  end

  defp collect_refs(%Ref{relationship_path: path, attribute: %{name: name}}, prefix, acc) do
    [{prefix ++ path, name} | acc]
  end

  # The relationship an `exists` traverses is itself a reference — a diagram that
  # drew the columns inside the subquery but not the edge to the relation they
  # live on would be describing a table that appeared from nowhere.
  defp collect_refs(%Exists{at_path: at_path, path: path, expr: inner}, prefix, acc) do
    collect_refs(inner, prefix ++ at_path ++ path, [{prefix ++ at_path, List.first(path)} | acc])
  end

  defp collect_refs(%BooleanExpression{left: left, right: right}, prefix, acc) do
    collect_refs(right, prefix, collect_refs(left, prefix, acc))
  end

  defp collect_refs(%Not{expression: inner}, prefix, acc), do: collect_refs(inner, prefix, acc)

  defp collect_refs(%Ash.CustomExpression{expression: inner}, prefix, acc),
    do: collect_refs(inner, prefix, acc)

  defp collect_refs(%Call{args: args}, prefix, acc),
    do: Enum.reduce(args, acc, &collect_refs(&1, prefix, &2))

  defp collect_refs(list, prefix, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_refs(&1, prefix, &2))

  defp collect_refs({key, value}, prefix, acc) when is_atom(key),
    do: collect_refs(value, prefix, acc)

  defp collect_refs(_leaf, _prefix, acc), do: acc

  @doc """
  Folds `fun` over every node of the tree, pre-order.

  Descends into `Call` arguments, `BooleanExpression`, `Not`, `Exists`, keyword
  arguments (`if`'s `do:`/`else:`), lists, and `Ash.CustomExpression`'s
  `.expression`. `Ref`s are leaves — their `relationship_path` is data, not a
  subtree.

  Use `refs/1` rather than this for lineage: `reduce/3` does not re-root the
  references inside an `exists`, and a reference attributed to the wrong relation
  is worse than a missing one.
  """
  @spec reduce(t(), acc, (t(), acc -> acc)) :: acc when acc: term()
  def reduce(expr, acc, fun) do
    acc = fun.(expr, acc)

    case expr do
      %Call{args: args} -> Enum.reduce(args, acc, &reduce(&1, &2, fun))
      %BooleanExpression{left: left, right: right} -> reduce(right, reduce(left, acc, fun), fun)
      %Not{expression: inner} -> reduce(inner, acc, fun)
      %Exists{expr: inner} -> reduce(inner, acc, fun)
      %Ash.CustomExpression{expression: inner} -> reduce(inner, acc, fun)
      %Ref{} -> acc
      list when is_list(list) -> Enum.reduce(list, acc, &reduce(&1, &2, fun))
      {key, value} when is_atom(key) -> reduce(value, acc, fun)
      _other -> acc
    end
  end

  @doc """
  Rewrites the tree bottom-up: `fun` sees each node after its children have been
  rewritten, and whatever it returns replaces the node.

  Used to retarget references — the same forward expression is rendered against
  legacy columns for the view, against `NEW.*` for a trigger, and against the new
  table for the reverse view — and to substitute values in when an obligation is
  enumerated in the BEAM.
  """
  @spec map(t(), (t() -> t())) :: t()
  def map(expr, fun) do
    case expr do
      %Call{args: args} = call ->
        fun.(%{call | args: Enum.map(args, &map(&1, fun))})

      %BooleanExpression{left: left, right: right} = boolean ->
        fun.(%{boolean | left: map(left, fun), right: map(right, fun)})

      %Not{expression: inner} = negation ->
        fun.(%{negation | expression: map(inner, fun)})

      %Exists{expr: inner} = exists ->
        fun.(%{exists | expr: map(inner, fun)})

      %Ash.CustomExpression{expression: inner} = custom ->
        fun.(%{custom | expression: map(inner, fun)})

      %Ref{} = ref ->
        fun.(ref)

      list when is_list(list) ->
        fun.(Enum.map(list, &map(&1, fun)))

      {key, value} when is_atom(key) ->
        fun.({key, map(value, fun)})

      other ->
        fun.(other)
    end
  end

  @doc """
  True when the expression is a single bare reference to the primary relation —
  the shape PostgreSQL calls *a simple reference to an updatable column*, and
  therefore the shape that needs no mechanism at all.

  See `AshStrangler.Mechanism`.

      iex> import Ash.Expr
      iex> AshStrangler.Expr.simple_reference(expr(login))
      {:ok, :login}

      iex> import Ash.Expr
      iex> AshStrangler.Expr.simple_reference(expr(address.city))
      :error

      iex> import Ash.Expr
      iex> AshStrangler.Expr.simple_reference(expr(login <> "!"))
      :error
  """
  @spec simple_reference(t()) :: {:ok, atom()} | :error
  def simple_reference(%Ref{relationship_path: [], attribute: attribute}) when is_atom(attribute),
    do: {:ok, attribute}

  def simple_reference(_other), do: :error

  @doc """
  True when the expression contains a `fragment(...)` anywhere inside it.

  A single `fragment` makes the whole expression opaque: it cannot be evaluated
  in the BEAM, so the obligations in `AshStrangler.Obligations` cannot decide it
  and must be re-emitted as SQL assertions instead.
  """
  @spec opaque?(t()) :: boolean()
  def opaque?(expr) do
    reduce(expr, false, fn
      %Call{name: :fragment}, _acc -> true
      _node, acc -> acc
    end)
  end
end
