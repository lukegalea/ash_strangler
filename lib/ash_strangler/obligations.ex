# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Obligations do
  @moduledoc """
  The proof obligations a mapping has to discharge, decided by **finite-domain
  enumeration** and reported as counterexamples.

  Named after the literature so an error message is searchable.

  | Obligation | Source | The failure it refuses |
  |---|---|---|
  | `GetTotal` | PODS 2006 | a legacy value the forward direction cannot turn into a valid attribute value |
  | `PutTotal` | PODS 2006 | an attribute value with **no** legal legacy encoding |
  | `PutGet` | lens laws | forward ∘ backward ≠ identity |
  | `GetPut` | lens laws | backward ∘ forward ≠ identity |
  | completeness | DMN / Calvanese et al. BPM 2016 | an uncovered cell in the guard lattice — a *missing rule* |
  | non-overlap / masked rule | DMN hit policies `UNIQUE` / `FIRST` | a clause no input can ever reach |
  | surjectivity | — | a declared state no clause can produce, so reads never show it |
  | linearity | the relevance condition from reversible languages | two mappings writing one legacy column; two producing one attribute |
  | type agreement | `Ash.Expr.determine_types/4` | the forward expression's type is not the target attribute's |

  Redundancy — pgroll's `ColumnMigrationRedundantError` — is the tenth, and it is
  `AshStrangler.Verifiers.VerifyNotRedundant` rather than a finding here, because
  it is decidable from the declaration alone with no enumeration.

  ## Why enumeration and not a solver

  Not implementation cost. Diagnostics, and Calvanese et al. state it directly: a
  solver *"leads to a boolean output (is the set of rules satisfiable?), and cannot
  natively highlight specific sets of rules that need to be added to a table
  (missing rules), nor specific overlaps between pairs of rules"*. `unsat` is not a
  next step; *"you have no clause for `:pending`"* is. And the input space is
  small — guards range over booleans and `is_null` abstractions of a handful of
  columns, so it is 2ⁿ with n around six.

  ## Proven, or measured — never asserted

  Some obligations cannot be decided at compile time, and this module does not
  pretend otherwise. Two cases:

  - A value space with no `one_of` constraint has no enumerable domain.
  - A `fragment(...)` cannot be evaluated in the BEAM at all.

  For those, the *same* obligation is emitted as a **SQL assertion** in the
  finding's `:assertion` field, and `mix ash_strangler.check` runs it against the
  real legacy data. A `GetTotal` that cannot be proven becomes

      SELECT DISTINCT state FROM legacy.users WHERE state IS NOT NULL AND state NOT IN (...)

  which answers the same question with the fifteen years of rows the tool did not
  create. That is the rule the whole design follows from: **round-tripping must be
  checked over the legacy value space, because that is the only space containing
  rows the tool did not create.**

  ## What this catches that 0.1 shipped

  The `state_code` mapping in this package's own fixtures projected five legacy
  lifecycle values onto `{0, 1}` and wrote `1` back as `'suspended'`, so reading a
  `passive` user and writing it back unchanged silently rewrote it. Written as a
  `decode`, that is a `GetTotal` violation and this module names the three values
  it loses.
  """

  alias Ash.Query.{BooleanExpression, Call, Not, Ref}
  alias AshStrangler.{Collapse, Concat, Decode, Info, Lens}
  alias AshStrangler.Sql.Printer

  @typedoc """
  One finding.

  `:severity` is `:error` for something decided against the mapping, and
  `:warning` for something the abstraction can only suspect — guard overlap that
  may hold for no value the data ever contains, which reporting as an error would
  refuse correct mappings.

  `:assertion` carries SQL when the obligation could not be decided and has to be
  measured instead.
  """
  @type finding() :: %{
          obligation: atom(),
          attribute: atom(),
          severity: :error | :warning,
          message: String.t(),
          assertion: String.t() | nil
        }

  @doc """
  Every finding for a resource, in obligation order.

  Accepts a compiled resource module or the mid-transform `dsl_state`.
  """
  @spec check(Spark.Dsl.t() | Ash.Resource.t()) :: [finding()]
  def check(resource_or_dsl) do
    if Info.strangled?(resource_or_dsl) do
      source = Info.source(resource_or_dsl)
      twin = source.twin
      attributes = attribute_index(resource_or_dsl)

      context = %{resource: resource_or_dsl, twin: twin, attributes: attributes, source: source}

      Enum.flat_map(source.mappings, &per_mapping(&1, context)) ++ linearity(resource_or_dsl)
    else
      []
    end
  end

  @doc "Only the findings that are errors — what a verifier refuses on."
  @spec errors(Spark.Dsl.t() | Ash.Resource.t()) :: [finding()]
  def errors(resource_or_dsl),
    do: resource_or_dsl |> check() |> Enum.filter(&(&1.severity == :error))

  @doc """
  Only the findings that could not be decided and carry a SQL assertion — what
  `mix ash_strangler.check` runs against real data.
  """
  @spec assertions(Spark.Dsl.t() | Ash.Resource.t()) :: [finding()]
  def assertions(resource_or_dsl),
    do: resource_or_dsl |> check() |> Enum.reject(&is_nil(&1.assertion))

  # --- dispatch ----------------------------------------------------------------
  #
  # Grouped here rather than beside each combinator's obligations, so the set of
  # things that HAVE obligations is readable in one place. A mapping absent from
  # this list has none, which is a claim worth being able to check at a glance.

  defp per_mapping(%Decode{} = entry, context), do: decode_obligations(entry, context)
  defp per_mapping(%Collapse{} = entry, context), do: collapse_obligations(entry, context)

  defp per_mapping(%AshStrangler.Coalesce{} = entry, context),
    do: coalesce_obligations(entry, context)

  defp per_mapping(%Concat{} = entry, context), do: concat_obligations(entry, context)
  defp per_mapping(_entry, _context), do: []

  # --- decode ------------------------------------------------------------------

  defp decode_obligations(%Decode{} = entry, context) do
    legacy_values = one_of(context.twin, entry.from)
    modern_values = Map.get(context.attributes, entry.attribute) |> constraint_one_of()

    Enum.reject(
      [
        get_total(entry, legacy_values, context),
        put_total(entry, modern_values),
        put_get(entry),
        type_agreement(entry, context)
      ],
      &is_nil/1
    )
  end

  # GetTotal: every value the legacy column can hold must decode to something.
  #
  # This is the obligation that catches the shipped bug. `state` ranges over
  # `passive | pending | active | suspended | deleted`; a table listing only
  # `active` and `suspended` cannot produce an attribute value for the other three,
  # and 0.1's `CASE ... ELSE 1 END` hid that by producing a *wrong* one.
  defp get_total(%Decode{} = entry, nil, context) do
    %{
      obligation: :GetTotal,
      attribute: entry.attribute,
      severity: :warning,
      message: """
      `decode #{inspect(entry.attribute)}, from: #{inspect(entry.from)}` cannot be proven total:
      the twin does not constrain #{inspect(entry.from)} to a known value set, so there is
      no domain to enumerate.

      Two ways to make this decidable. Give the twin column a `one_of` constraint,
      which `mix ash_strangler.gen.twin` does automatically when the legacy table has
      a CHECK constraint or an enum type:

          attribute #{inspect(entry.from)}, :string, constraints: [one_of: #{inspect(Map.keys(entry.values))}]

      Or leave it, and let `mix ash_strangler.check` measure it against the real
      data -- which is the stronger answer, since it reports what fifteen years
      actually put in the column rather than what the schema permits.
      """,
      assertion: unknown_values_assertion(entry, context)
    }
  end

  defp get_total(%Decode{} = entry, legacy_values, _context) do
    case legacy_values -- Map.keys(entry.values) do
      [] ->
        nil

      missing ->
        %{
          obligation: :GetTotal,
          attribute: entry.attribute,
          severity: :error,
          message: """
          `decode #{inspect(entry.attribute)}, from: #{inspect(entry.from)}` is not total.

          The twin says #{inspect(entry.from)} ranges over #{inspect(legacy_values)}, and the
          `values:` table has no entry for:

            #{Enum.map_join(missing, "\n  ", &inspect/1)}

          A legacy row holding one of those has no attribute value to project to. The
          tempting fix -- a catch-all `ELSE` -- is exactly the bug this obligation
          exists to refuse: it produces a value that is *wrong* rather than absent,
          and then writes that wrong value back. Reading a #{inspect(List.first(missing))}
          row and saving it unchanged would rewrite it.

          Add an entry for each.
          """,
          assertion: nil
        }
    end
  end

  # PutTotal: every value the attribute can hold must have a legacy encoding.
  #
  # This is what catches `state_code: 7`. It is decidable only against a bounded
  # target, so an unbounded one is itself the finding -- and an error rather than a
  # warning, because a `decode` is a declared *bijection* and a bijection onto an
  # unbounded set is not one.
  defp put_total(%Decode{} = entry, nil) do
    %{
      obligation: :PutTotal,
      attribute: entry.attribute,
      severity: :error,
      message: """
      `decode #{inspect(entry.attribute)}` declares a bijection onto an unbounded value space.

      #{inspect(entry.attribute)} has no `one_of` constraint, so nothing stops a value the
      `values:` table cannot encode. The write path would then either fail at 3am or,
      worse, fall through to whatever the last branch happens to say -- which is how
      `state_code: 7` came to write `'suspended'` and read back as `1`.

      Constrain the attribute. The table already knows what the values are:

          attribute #{inspect(entry.attribute)}, :integer do
            constraints one_of: #{inspect(entry.values |> Map.values() |> Enum.sort())}
          end

      An `AshStateMachine` state list counts too -- it is read from the resource, not
      restated here.
      """,
      assertion: nil
    }
  end

  defp put_total(%Decode{} = entry, modern_values) do
    encodable = entry.values |> Map.values() |> MapSet.new()

    case Enum.reject(modern_values, &MapSet.member?(encodable, &1)) do
      [] ->
        nil

      missing ->
        %{
          obligation: :PutTotal,
          attribute: entry.attribute,
          severity: :error,
          message: """
          `decode #{inspect(entry.attribute)}` cannot encode every value the attribute allows.

          #{inspect(entry.attribute)} is constrained to #{inspect(modern_values)}, and the
          `values:` table produces no legacy value for:

            #{Enum.map_join(missing, "\n  ", &inspect/1)}

          A write of one of those has nowhere to go. Either add it to the table, or
          narrow the attribute's `one_of` so the two agree.
          """,
          assertion: nil
        }
    end
  end

  # PutGet and GetPut together. A `decode` built from a map is a bijection exactly
  # when the map is injective; if two legacy values share an attribute value, the
  # write direction has to pick one and round-tripping the other loses it.
  defp put_get(%Decode{} = entry) do
    entry.values
    |> Enum.group_by(fn {_legacy, modern} -> modern end, fn {legacy, _modern} -> legacy end)
    |> Enum.filter(fn {_modern, legacy} -> length(legacy) > 1 end)
    |> case do
      [] ->
        nil

      collisions ->
        %{
          obligation: :PutGet,
          attribute: entry.attribute,
          severity: :error,
          message: """
          `decode #{inspect(entry.attribute)}` is not injective, so it is not a bijection.

          #{counterexample_table(entry, collisions)}

          Reading one of the colliding legacy values and writing the row back unchanged
          rewrites it to the other. That is a `PutGet` violation: forward ∘ backward is
          not the identity.

          If the collapse is deliberate -- several legacy values genuinely meaning one
          modern state -- then the mapping is not a bijection and should say so:

              map #{inspect(entry.attribute)}, from: expr(...), read_only?: true, because: "..."
          """,
          assertion: nil
        }
    end
  end

  defp counterexample_table(_entry, collisions) do
    rows =
      Enum.flat_map(collisions, fn {modern, legacy_values} ->
        Enum.map(legacy_values, fn legacy ->
          written_back = legacy_values |> Enum.sort_by(&inspect/1) |> List.first()

          verdict = if written_back == legacy, do: "ok", else: "PUTGET VIOLATION"

          " #{pad(inspect(legacy), 12)} | #{pad(inspect(modern), 11)} | #{pad(inspect(written_back), 14)} | #{verdict}"
        end)
      end)

    """
     legacy_value | projects_to | writes_back_as | verdict
    --------------+-------------+----------------+------------------
    #{Enum.join(rows, "\n")}
    """
  end

  defp pad(text, width), do: String.pad_trailing(text, width)

  defp type_agreement(%Decode{} = entry, context) do
    case Map.get(context.attributes, entry.attribute) do
      nil ->
        nil

      %{type: type, constraints: constraints} ->
        entry.values
        |> Map.values()
        |> Enum.reject(&match?({:ok, _}, Ash.Type.cast_input(type, &1, constraints)))
        |> case do
          [] ->
            nil

          bad ->
            %{
              obligation: :type_agreement,
              attribute: entry.attribute,
              severity: :error,
              message: """
              `decode #{inspect(entry.attribute)}` produces values that are not of the attribute's type.

              #{inspect(entry.attribute)} is #{inspect(type)}, and these do not cast to it:

                #{Enum.map_join(bad, "\n  ", &inspect/1)}
              """,
              assertion: nil
            }
        end
    end
  end

  # --- collapse ----------------------------------------------------------------

  defp collapse_obligations(%Collapse{} = entry, context) do
    modern_values = Map.get(context.attributes, entry.attribute) |> constraint_one_of()

    case atoms(entry) do
      {:ok, atoms} ->
        Enum.reject(
          [
            completeness(entry, atoms, context),
            overlap(entry, atoms),
            surjectivity(entry, modern_values)
          ],
          &is_nil/1
        )

      :undecidable ->
        [undecidable_guards(entry, context)]
    end
  end

  # The propositional abstraction: every distinct atomic proposition across every
  # guard becomes a variable, and the lattice is 2^n assignments over them.
  #
  # This is sound for COMPLETENESS -- if every assignment is covered, no row can
  # miss -- and deliberately coarse for OVERLAP, because the abstraction admits
  # combinations no value can produce (`col == 'a'` and `col == 'b'` both true).
  # That coarseness is why overlap is a warning; see `overlap/2`.
  defp atoms(%Collapse{states: states}) do
    states
    |> Enum.reject(&(&1.when == :otherwise))
    |> Enum.reduce_while({:ok, []}, fn state, {:ok, acc} ->
      case collect_atoms(state.when, acc) do
        {:ok, atoms} -> {:cont, {:ok, atoms}}
        :undecidable -> {:halt, :undecidable}
      end
    end)
    |> case do
      {:ok, atoms} -> {:ok, Enum.uniq(atoms)}
      :undecidable -> :undecidable
    end
  end

  defp collect_atoms(%BooleanExpression{left: left, right: right}, acc) do
    case collect_atoms(left, acc) do
      {:ok, acc} -> collect_atoms(right, acc)
      :undecidable -> :undecidable
    end
  end

  defp collect_atoms(%Not{expression: inner}, acc), do: collect_atoms(inner, acc)
  defp collect_atoms(%Call{name: :not, args: [inner]}, acc), do: collect_atoms(inner, acc)
  defp collect_atoms(%Call{name: :is_nil, args: [%Ref{}]} = call, acc), do: {:ok, acc ++ [call]}
  defp collect_atoms(%Ref{} = ref, acc), do: {:ok, acc ++ [ref]}

  defp collect_atoms(%Call{name: name, args: [%Ref{}, literal]} = call, acc)
       when name in [:==, :!=, :>, :>=, :<, :<=] and not is_struct(literal) do
    {:ok, acc ++ [call]}
  end

  defp collect_atoms(_other, _acc), do: :undecidable

  defp evaluate(%BooleanExpression{op: :and, left: left, right: right}, assignment),
    do: evaluate(left, assignment) and evaluate(right, assignment)

  defp evaluate(%BooleanExpression{op: :or, left: left, right: right}, assignment),
    do: evaluate(left, assignment) or evaluate(right, assignment)

  defp evaluate(%Not{expression: inner}, assignment), do: not evaluate(inner, assignment)
  defp evaluate(%Call{name: :not, args: [inner]}, assignment), do: not evaluate(inner, assignment)
  defp evaluate(atom, assignment), do: Map.fetch!(assignment, atom)

  defp assignments(atoms) do
    Enum.reduce(atoms, [%{}], fn atom, acc ->
      Enum.flat_map(acc, fn assignment ->
        [Map.put(assignment, atom, true), Map.put(assignment, atom, false)]
      end)
    end)
  end

  defp completeness(%Collapse{states: states} = entry, atoms, context) do
    if Enum.any?(states, &(&1.when == :otherwise)) do
      nil
    else
      guards = states |> Enum.reject(&(&1.when == :otherwise)) |> Enum.map(& &1.when)

      atoms
      |> assignments()
      |> Enum.reject(fn assignment -> Enum.any?(guards, &evaluate(&1, assignment)) end)
      |> case do
        [] ->
          nil

        uncovered ->
          %{
            obligation: :completeness,
            attribute: entry.attribute,
            severity: :error,
            message: """
            `collapse #{inspect(entry.attribute)}` has a missing rule.

            No clause matches when:

            #{Enum.map_join(Enum.take(uncovered, 3), "\n\n", &describe_assignment/1)}

            A legacy row in that state projects to NULL, and #{inspect(entry.attribute)}
            would read as nothing at all. Add a clause, or add the fallback -- which
            is what `:otherwise` is for and is almost always the right answer, because
            the old application was never stopped from writing whatever it liked:

                state :some_value, when: :otherwise, set: [...]
            """,
            assertion: uncovered_rows_assertion(entry, context)
          }
      end
    end
  end

  defp describe_assignment(assignment) do
    assignment
    |> Enum.map(fn {atom, truth} ->
      "  #{if truth, do: "    ", else: "NOT "}#{Printer.to_sql(atom, ref: fn {_p, n} -> to_string(n) end)}"
    end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  # A clause no assignment can reach is a MASKED RULE -- DMN's term, and an error
  # under either hit policy, because a clause that can never fire is dead code that
  # a reader will believe.
  #
  # Two clauses that CAN both fire is an overlap. Under `:unique` it is an error;
  # under `:first` it is legal by construction -- that is what "first match wins"
  # means -- and is not reported at all.
  defp overlap(%Collapse{hit_policy: policy, states: states} = entry, atoms) do
    guarded = Enum.reject(states, &(&1.when == :otherwise))
    space = assignments(atoms)

    masked =
      guarded
      |> Enum.with_index()
      |> Enum.filter(fn {state, index} ->
        earlier = guarded |> Enum.take(index) |> Enum.map(& &1.when)

        Enum.all?(space, fn assignment ->
          not evaluate(state.when, assignment) or Enum.any?(earlier, &evaluate(&1, assignment))
        end)
      end)
      |> Enum.map(fn {state, _index} -> state.value end)

    overlapping =
      if policy == :unique do
        for a <- guarded,
            b <- guarded,
            a.value < b.value,
            Enum.any?(space, &(evaluate(a.when, &1) and evaluate(b.when, &1))),
            do: {a.value, b.value}
      else
        []
      end

    cond do
      masked != [] ->
        %{
          obligation: :masked_rule,
          attribute: entry.attribute,
          severity: :error,
          message: """
          `collapse #{inspect(entry.attribute)}` has clauses that can never be reached:

            #{Enum.map_join(masked, "\n  ", &inspect/1)}

          Every input matching one of them matches an earlier clause first, so
          #{inspect(List.first(masked))} is a state reads will never show. Either reorder the
          clauses, or narrow the earlier guard.
          """,
          assertion: nil
        }

      overlapping != [] ->
        %{
          obligation: :non_overlap,
          attribute: entry.attribute,
          severity: :warning,
          message: """
          `collapse #{inspect(entry.attribute)}` declares `hit_policy: :unique`, but these clause
          pairs can both match:

            #{Enum.map_join(overlapping, "\n  ", fn {a, b} -> "#{inspect(a)} and #{inspect(b)}" end)}

          Reported as a warning rather than an error because the guard lattice is a
          propositional abstraction: it admits combinations no actual value can
          produce, so an overlap here may hold for no row that will ever exist.
          `mix ash_strangler.check` decides it against the real data.

          If the clauses are meant to be an ordered cascade rather than independent
          facts, `hit_policy: :first` says so and this stops being a question.
          """,
          assertion: nil
        }

      true ->
        nil
    end
  end

  defp surjectivity(%Collapse{}, nil), do: nil

  defp surjectivity(%Collapse{states: states} = entry, modern_values) do
    produced = MapSet.new(states, & &1.value)

    case Enum.reject(modern_values, &MapSet.member?(produced, &1)) do
      [] ->
        nil

      unreachable ->
        %{
          obligation: :surjectivity,
          attribute: entry.attribute,
          severity: :warning,
          message: """
          `collapse #{inspect(entry.attribute)}` can never produce:

            #{Enum.map_join(unreachable, "\n  ", &inspect/1)}

          #{inspect(entry.attribute)} declares those as legal values, but no clause yields
          them, so a read will never show one. That is usually a clause somebody meant
          to write; occasionally it is a state only the new application creates, in
          which case it is correct and this is noise.
          """,
          assertion: nil
        }
    end
  end

  defp undecidable_guards(%Collapse{} = entry, context) do
    %{
      obligation: :completeness,
      attribute: entry.attribute,
      severity: :warning,
      message: """
      `collapse #{inspect(entry.attribute)}` cannot be checked for completeness at compile time.

      At least one guard is outside the propositional abstraction -- a `fragment`, a
      subquery, or an expression over more than a column and a literal -- so there is
      no finite lattice to enumerate.

      The same obligation is emitted as SQL for `mix ash_strangler.check`, which
      answers it against the real legacy data. That is the stronger answer anyway:
      it reports the rows that actually exist rather than the states the schema
      permits.
      """,
      assertion: uncovered_rows_assertion(entry, context)
    }
  end

  # --- coalesce and concat: the side conditions the schema cannot decide --------

  defp coalesce_obligations(%AshStrangler.Coalesce{} = entry, context) do
    [
      %{
        obligation: :GetPut,
        attribute: entry.attribute,
        severity: :warning,
        message: """
        `coalesce #{inspect(entry.attribute)}, default: #{inspect(entry.default)}` is an isomorphism only
        if #{inspect(entry.default)} is not *otherwise* a legal value in #{inspect(entry.from)}.

        If it is, the reverse -- `NULLIF` -- maps a real stored value back to NULL, and
        a row round-trips from #{inspect(entry.default)} to nothing. This is the relational-lens
        side condition `{A = a} ∈ P[A]` (Bohannon, Pierce & Vaughan, PODS 2006), and it
        is a fact about the data rather than about the schema, so it is measured
        rather than proven.
        """,
        assertion: """
        SELECT count(*) AS rows_where_the_default_is_a_real_value
        FROM #{relation(context)}
        WHERE #{column(context, entry.from)} = #{Printer.literal(entry.default)}
        """
      }
    ]
  end

  defp concat_obligations(%Concat{} = entry, context) do
    predicates =
      Enum.map_join(entry.from, "\n   OR ", fn column ->
        "position(#{Printer.literal(entry.separator)} in coalesce(#{column(context, column)}, '')) > 0"
      end)

    [
      %{
        obligation: :GetPut,
        attribute: entry.attribute,
        severity: :warning,
        message: """
        `concat #{inspect(entry.attribute)}, separator: #{inspect(entry.separator)}` reverses with
        `split_part`, which is correct only while #{inspect(entry.separator)} is absent from every
        operand.

        This is the degraded form of Boomerang's regex-ambiguity condition (Bohannon,
        Foster, Pierce, Pilkiewicz & Schmitt, POPL 2008), and absence is a fact about
        the data, so it is measured rather than proven.

        There is a second, unconditional loss, and it is why this combinator is
        `invertible: :semi` even when the count below is zero: each operand is
        null-defaulted on the way out, because SQL's `||` propagates NULL and a
        single absent operand would otherwise blank the whole value. `split_part`
        cannot tell a NULL operand from an empty one on the way back, so a row whose
        #{inspect(List.last(entry.from))} was NULL round-trips to `''`.

        If the count below is not zero, the honest mapping is read-only -- which is
        what `full_name` is in this package's own fixtures, because `'de la Cruz'`
        splits wrong and no separator fixes it.
        """,
        assertion: """
        SELECT count(*) AS rows_whose_operands_contain_the_separator
        FROM #{relation(context)}
        WHERE #{predicates}
        """
      }
    ]
  end

  # --- linearity ---------------------------------------------------------------

  # The relevance condition from reversible languages: a value may be produced
  # once and consumed once. Two mappings writing one legacy column means the
  # trigger's `SET` clause has two assignments for it and one silently wins.
  defp linearity(resource_or_dsl) do
    resource_or_dsl
    |> Lens.for_resource()
    |> Enum.reject(&(&1.combinator == :key))
    |> Enum.flat_map(fn lens -> Enum.map(lens.writes, fn {column, _} -> {column, lens} end) end)
    |> Enum.group_by(fn {column, _lens} -> column end, fn {_column, lens} -> lens.attribute end)
    |> Enum.filter(fn {_column, attributes} -> length(attributes) > 1 end)
    |> Enum.map(fn {column, attributes} ->
      %{
        obligation: :linearity,
        attribute: List.first(attributes),
        severity: :error,
        message: """
        Legacy column #{inspect(column)} is written by more than one mapping:

          #{Enum.map_join(attributes, "\n  ", &inspect/1)}

        The generated trigger's `SET` clause would carry two assignments for one
        column. One of them silently wins, and which one depends on declaration
        order -- so a reordering of the DSL changes what is stored, with nothing
        reporting it.

        This is the relevance condition from reversible languages: a value is
        produced once and consumed once. Decide which mapping owns the column, and
        make the other `read_only?: true`.
        """,
        assertion: nil
      }
    end)
  end

  # --- helpers -----------------------------------------------------------------

  defp unknown_values_assertion(%Decode{} = entry, context) do
    known = entry.values |> Map.keys() |> Enum.map_join(", ", &Printer.literal/1)

    """
    SELECT DISTINCT #{column(context, entry.from)} AS value_with_no_decode_entry
    FROM #{relation(context)}
    WHERE #{column(context, entry.from)} IS NOT NULL
      AND #{column(context, entry.from)} NOT IN (#{known})
    """
  end

  defp uncovered_rows_assertion(%Collapse{states: states} = entry, context) do
    frame = fn {_path, name} -> column(context, name) end

    guards =
      states
      |> Enum.reject(&(&1.when == :otherwise))
      |> Enum.map_join("\n   OR ", &Printer.to_sql(&1.when, ref: frame))

    """
    -- rows `collapse #{inspect(entry.attribute)}` has no clause for
    SELECT count(*) AS rows_matching_no_clause
    FROM #{relation(context)}
    WHERE NOT (#{guards})
    """
  end

  defp relation(%{twin: twin}), do: AshStrangler.Twin.relation(twin)

  defp column(%{twin: twin}, attribute) do
    AshStrangler.Twin.column!(twin, attribute)
  rescue
    _ -> to_string(attribute)
  end

  defp one_of(twin, column) do
    twin |> Ash.Resource.Info.attribute(column) |> constraint_one_of()
  rescue
    _ -> nil
  end

  # The largest number of integers worth enumerating. Past this, `min`/`max` stop
  # describing a value SET and start describing a sanity bound -- `min: 0, max:
  # 2_000_000_000` on a counter is not a claim that every value in it is a legal
  # encoding, and treating it as one would produce an unreadable finding.
  @enumerable_range 256

  # The attribute's value space, read off the attribute rather than restated in the
  # mapping.
  #
  # Two forms are enumerable, and between them they cover what a `decode` targets:
  #
  #   * `one_of` -- `Ash.Type.Atom`'s and `Ash.Type.String`-like types'. An
  #     `AshStateMachine` state list lands here too, because that extension writes
  #     its states into the attribute's constraints, so nothing here has to know it
  #     exists.
  #   * `min`/`max` on an integer. `Ash.Type.Integer` has no `one_of` at all, so a
  #     `decode` onto an integer code would otherwise be undecidable -- and integer
  #     codes are the common case for exactly the kind of legacy column a `decode`
  #     exists to tame.
  #
  # `nil` means "no enumerable domain", which is a finding rather than a pass.
  defp constraint_one_of(nil), do: nil

  defp constraint_one_of(%{constraints: constraints}) when is_list(constraints) do
    case Keyword.get(constraints, :one_of) do
      nil -> integer_range(Keyword.get(constraints, :min), Keyword.get(constraints, :max))
      values -> values
    end
  end

  defp constraint_one_of(_attribute), do: nil

  defp integer_range(min, max)
       when is_integer(min) and is_integer(max) and max - min < @enumerable_range,
       do: Enum.to_list(min..max)

  defp integer_range(_min, _max), do: nil

  defp attribute_index(resource_or_dsl) do
    resource_or_dsl
    |> Ash.Resource.Info.attributes()
    |> Map.new(&{&1.name, &1})
  rescue
    _ -> %{}
  end
end
