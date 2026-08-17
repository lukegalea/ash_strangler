# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ExprTest do
  @moduledoc """
  The walkers over the unhydrated `Ash.Expr` tree, and mostly about one of them.

  `refs/1` is the lineage primitive: every consumer that draws, exports or verifies
  a mapping learns which legacy columns it reads by asking this function. So the
  interesting failure is not a crash, it is a **plausible wrong answer** — and one
  shape produces exactly that.

  `expr(exists(payments, amount > 0))` builds an `%Ash.Query.Exists{path:
  [:payments], expr: …}`, and `amount` inside it has an *empty*
  `relationship_path`: it is relative to `payments`, not to the primary relation.
  A walker that folded over the tree without re-rooting would report
  `{[], :amount}` — an edge on the wrong table, drawn confidently, in a diagram
  whose whole purpose is convincing somebody nothing was lost. That is worse than a
  missing edge, which at least looks missing.

  `Ash.Filter.map/2` — the obvious tool, tried first — makes the other version of
  the same mistake: each of its clauses says it does not descend into
  `Ash.Query.Parent`, `Ash.Query.Exists` or `Ash.Query.Ref`, so every column inside
  an `exists` would vanish. That is the failure the deleted regex heuristic had.

  Both are asserted here rather than argued: `refs/1` is compared against a fold
  over `reduce/3`, which descends into `Exists` and does *not* re-root, and the two
  are shown to disagree in precisely the way the moduledoc claims.
  """

  use ExUnit.Case, async: true

  # The moduledoc's `refs/1` examples are the module's central argument written out,
  # and one of them claimed `[{[], :payments}, {[], :amount}]` -- an `amount`
  # attributed to the primary relation rather than to `payments`, which is exactly
  # the mistake the module exists to prevent. Nothing ran the doctests, so it stood.
  doctest AshStrangler.Expr

  import Ash.Expr

  alias Ash.Query.{BooleanExpression, Call, Exists, Not, Ref}
  alias AshStrangler.Expr, as: StranglerExpr

  describe "refs/1 inside exists(...)" do
    test "a reference inside an exists is re-rooted onto the relationship it belongs to" do
      # `amount` is relative to `payments`. Reporting it as `{[], :amount}` would put
      # the edge on the primary relation, which is where a column of that name is
      # most likely to also exist — so the wrong answer is not only wrong, it is
      # wrong in the way least likely to be noticed.
      assert StranglerExpr.refs(expr(exists(payments, amount > 0))) == [
               {[], :payments},
               {[:payments], :amount}
             ]
    end

    test "the relationship the exists traverses is itself a reference" do
      # Without it the diagram draws the columns inside the subquery but no edge to
      # the relation they live on, which describes a table that appeared from
      # nowhere.
      refs = StranglerExpr.refs(expr(exists(payments, amount > 0)))

      assert {[], :payments} in refs
    end

    test "a multi-hop path re-roots every inner reference onto the whole path" do
      assert StranglerExpr.refs(expr(exists(payments.refunds, amount > 0 and is_nil(voided_at)))) ==
               [
                 {[], :payments},
                 {[:payments, :refunds], :amount},
                 {[:payments, :refunds], :voided_at}
               ]
    end

    test "an exists that is itself reached through a relationship re-roots onto both" do
      # `at_path` is the path to the `exists` and `path` is the path it traverses, and
      # a reference inside is relative to their concatenation. Built by hand because
      # `expr/1` produces this shape only from a mapping written against a twin with
      # the relationships in place, and the arithmetic on the two paths is what is
      # under test.
      exists = %Exists{
        at_path: [:employer],
        path: [:payments],
        expr: expr(amount > 0)
      }

      assert StranglerExpr.refs(exists) == [
               {[:employer], :payments},
               {[:employer, :payments], :amount}
             ]
    end

    test "references outside the exists keep their own frame" do
      # The prefix is threaded, not accumulated: leaving the subquery has to restore
      # the outer frame, and a fold that mutated one prefix as it went would attribute
      # everything after an `exists` to the relationship the `exists` traversed.
      assert StranglerExpr.refs(expr(not is_nil(login) and exists(payments, amount > 0))) == [
               {[], :login},
               {[], :payments},
               {[:payments], :amount}
             ]

      assert StranglerExpr.refs(expr(exists(payments, amount > 0) and not is_nil(login))) == [
               {[], :payments},
               {[:payments], :amount},
               {[], :login}
             ]
    end

    test "a fold over reduce/3 gets the relation wrong, which is why refs/1 is hand-written" do
      # The claim `AshStrangler.Expr`'s moduledoc makes, measured. `reduce/3` descends
      # into `Exists` — so nothing is *missing* — but it carries no path prefix, so
      # `amount` comes back attributed to the primary relation. That is the plausible
      # wrong answer, and it is the reason `refs/1` is a hand-written recursion rather
      # than a fold over the general walker.
      via_reduce =
        StranglerExpr.reduce(expr(exists(payments, amount > 0)), [], fn
          %Ref{relationship_path: path, attribute: attribute}, acc when is_atom(attribute) ->
            [{path, attribute} | acc]

          _node, acc ->
            acc
        end)

      assert {[], :amount} in Enum.reverse(via_reduce)
      refute {[:payments], :amount} in via_reduce

      assert {[:payments], :amount} in StranglerExpr.refs(expr(exists(payments, amount > 0)))
    end
  end

  describe "refs/1 descends into the nodes expr/1 builds that are not Calls" do
    test "a BooleanExpression, in both operand positions" do
      assert StranglerExpr.refs(expr(is_nil(first_name) and is_nil(last_name))) == [
               {[], :first_name},
               {[], :last_name}
             ]

      assert StranglerExpr.refs(expr(is_nil(first_name) or is_nil(last_name))) == [
               {[], :first_name},
               {[], :last_name}
             ]
    end

    test "a Not" do
      assert StranglerExpr.refs(expr(not is_nil(deleted_at))) == [{[], :deleted_at}]
    end

    test "an Ash.CustomExpression, through its .expression" do
      # A custom expression is a package's own operator with a real subtree inside it,
      # and the subtree reads legacy columns like any other. Constructed directly
      # rather than registered in `:ash, :custom_expressions`: the walker's contract is
      # about the `.expression` field, and registering one would test Ash's expansion.
      custom = %Ash.CustomExpression{
        module: __MODULE__,
        arguments: [],
        expression: expr((first_name || "") <> last_name),
        simple_expression: :unknown
      }

      assert StranglerExpr.refs(custom) == [{[], :first_name}, {[], :last_name}]
    end

    test "an `if`'s do: and else: branches, which arrive as a keyword list" do
      # `expr/1` desugars `cond` into nested `if`s and stores the branches as
      # `[do: …, else: …]`, so a walker that only descended into positional arguments
      # would see the condition and lose both results.
      assert StranglerExpr.refs(expr(if is_deleted, do: first_name, else: last_name)) == [
               {[], :is_deleted},
               {[], :first_name},
               {[], :last_name}
             ]
    end

    test "a hydrated Ref, which carries the attribute struct rather than its name" do
      # `AshStrangler.Lens.hydrate/2` is the one place the hydration boundary is
      # crossed, and an expression that has been through it still has to answer this
      # question.
      hydrated = %Ref{
        attribute: %Ash.Resource.Attribute{name: :first_name, type: Ash.Type.String},
        relationship_path: [:employer],
        resource: nil
      }

      assert StranglerExpr.refs(hydrated) == [{[:employer], :first_name}]
    end
  end

  describe "refs/1 ordering and duplication" do
    test "references come back in first-appearance order" do
      # The order is what the diagram lays out and what the OpenLineage facet lists,
      # so it has to be the declaration's order rather than whatever a MapSet
      # produces. A set would make the exported lineage reorder itself between runs
      # and every regenerated artefact would show a spurious diff.
      assert StranglerExpr.refs(expr((last_name || "") <> " " <> (first_name || ""))) == [
               {[], :last_name},
               {[], :first_name}
             ]
    end

    test "a column read twice is reported once" do
      assert StranglerExpr.refs(expr(if is_nil(first_name), do: "none", else: first_name)) == [
               {[], :first_name}
             ]
    end

    test "the same column name on two relations is two references" do
      # De-duplication is on `{path, attribute}` and not on the attribute alone, which
      # is what keeps a joined `city` distinct from a primary `city`. Collapsing them
      # would drop one relation out of the lineage graph entirely.
      assert StranglerExpr.refs(expr(is_nil(city) and is_nil(address.city))) == [
               {[], :city},
               {[:address], :city}
             ]
    end

    test "an expression that reads nothing reports nothing" do
      # A `constant` mapping's forward expression. Reporting `[]` is a statement — the
      # column has no legacy source — rather than a failure to work one out, which is
      # the distinction the deleted `:unresolved` value could not make.
      assert StranglerExpr.refs(expr(type("00000000-0000-0000-0000-000000000000", :uuid))) == []
      assert StranglerExpr.refs(nil) == []
      assert StranglerExpr.refs(expr(fragment("now()"))) == []
    end
  end

  describe "reduce/3" do
    test "visits every node pre-order, including inside an exists" do
      calls =
        StranglerExpr.reduce(expr(exists(payments, string_downcase(memo) == "x")), [], fn
          %Call{name: name}, acc -> [name | acc]
          _node, acc -> acc
        end)

      assert :string_downcase in calls
      assert :== in calls
    end

    test "treats a Ref as a leaf, because its relationship_path is data and not a subtree" do
      # Descending into it would visit the path atoms as though they were nodes, and
      # every consumer counting nodes or looking for a `fragment` would see them.
      count =
        StranglerExpr.reduce(expr(address.city), 0, fn _node, acc -> acc + 1 end)

      assert count == 1
    end
  end

  describe "map/2" do
    test "retargets references, which is the whole reason it exists" do
      # One forward expression is rendered against legacy columns for the view,
      # against `NEW.*` for a trigger and against the new table for the reverse view.
      # The frame handles the spelling; this handles the cases where the *reference
      # itself* has to change.
      renamed =
        StranglerExpr.map(expr((first_name || "") <> last_name), fn
          %Ref{attribute: :first_name} = ref -> %{ref | attribute: :given_name}
          node -> node
        end)

      assert StranglerExpr.refs(renamed) == [{[], :given_name}, {[], :last_name}]
    end

    test "rewrites bottom-up, so a callback sees children already rewritten" do
      # The order is load-bearing for substitution: replacing a subtree and then
      # rewriting its replacement's children would apply the callback to values the
      # callback produced.
      seen =
        StranglerExpr.map(expr(not is_nil(deleted_at)), fn
          %Ref{attribute: attribute} -> %Ref{attribute: attribute, relationship_path: [:audit]}
          %Not{expression: %Call{args: [%Ref{relationship_path: [:audit]}]}} = node -> node
          node -> node
        end)

      assert StranglerExpr.refs(seen) == [{[:audit], :deleted_at}]
    end

    test "descends into every node kind the tree can hold" do
      # A node kind `map/2` did not descend into would be handed to the callback whole
      # and replaced by whatever the callback made of it — which is how a subtree gets
      # silently swallowed rather than rewritten.
      substituted =
        StranglerExpr.map(
          expr(exists(payments, amount > 0) and not is_nil(login)),
          fn
            %Ref{attribute: attribute} = ref -> %{ref | attribute: :"#{attribute}_x"}
            node -> node
          end
        )

      assert %BooleanExpression{} = substituted

      # The `exists`'s own `path` is untouched, and deliberately so: it is a
      # relationship name on the twin, not a reference to a column, and rewriting it
      # would retarget the subquery rather than the value it reads. `refs/1` still
      # reports it, because lineage needs the relation — so the two functions
      # disagree about `payments` on purpose.
      assert StranglerExpr.refs(substituted) == [
               {[], :payments},
               {[:payments], :amount_x},
               {[], :login_x}
             ]
    end
  end

  describe "simple_reference/1" do
    test "a bare reference to the primary relation is the shape that needs no mechanism" do
      # PostgreSQL's own rule: a view column is updatable when it is *a simple
      # reference to an updatable column of the underlying base relation*. This
      # function is where `AshStrangler.Mechanism` gets that answer, so its boundary
      # is the boundary between a view that needs an `INSTEAD OF` trigger and one that
      # does not — and a trigger costs the resource its ability to upsert at all.
      assert StranglerExpr.simple_reference(expr(login)) == {:ok, :login}
    end

    test "anything else is not, including the shapes that look close" do
      # A reference through a relationship is not a column of the base relation; a
      # cast and a concatenation are not references. Each of the three would cost the
      # column its auto-updatability if it were let through, and PostgreSQL would only
      # say so at write time.
      assert StranglerExpr.simple_reference(expr(address.city)) == :error
      assert StranglerExpr.simple_reference(expr(login <> "!")) == :error
      assert StranglerExpr.simple_reference(expr(type(login, :ci_string))) == :error
      assert StranglerExpr.simple_reference(nil) == :error
      assert StranglerExpr.simple_reference("login") == :error
    end
  end

  describe "opaque?/1" do
    test "a fragment anywhere makes the whole expression opaque" do
      # Opaque means the obligations in `AshStrangler.Obligations` cannot be decided in
      # the BEAM and have to be re-emitted as SQL assertions. It is a property of the
      # whole expression rather than of the node, because one unevaluable leaf is
      # enough to make the expression unevaluable — so it has to be found at any
      # depth.
      assert StranglerExpr.opaque?(expr(fragment("now()")))
      assert StranglerExpr.opaque?(expr(string_downcase(fragment("upper(?)", login))))
      assert StranglerExpr.opaque?(expr(not is_nil(fragment("x"))))
      assert StranglerExpr.opaque?(expr(is_nil(login) and fragment("x")))
      assert StranglerExpr.opaque?(expr(if is_nil(login), do: fragment("x"), else: login))
      assert StranglerExpr.opaque?(expr(exists(payments, fragment("x"))))
    end

    test "an expression built only from the grammar is not opaque" do
      refute StranglerExpr.opaque?(expr(login))
      refute StranglerExpr.opaque?(expr((first_name || "") <> " " <> (last_name || "")))
      refute StranglerExpr.opaque?(expr(if is_deleted, do: "archived", else: "pending"))
      refute StranglerExpr.opaque?(nil)
    end
  end
end
