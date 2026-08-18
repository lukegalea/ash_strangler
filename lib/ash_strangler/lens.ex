# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Lens do
  @moduledoc """
  What a mapping *means*, in both directions.

  One `%Lens{}` per mapping entity, and it is the single structure everything
  downstream reads: the view's `SELECT` list, the trigger's assignments, the
  reverse view's columns, the expression index, the lineage graph, the
  reconciler's comparison, the backfill and `mix ash_strangler.check`. In 0.1
  those six read five different string paths and a regex.

  ## Prisms, not lenses

  In the general lens formulation `put` reads the original source row. Here it
  does not: a column mapping is stateless, so `PutPut` holds for free and these
  are *very well behaved* lenses — partial isomorphisms with the semi-iso
  round-trip laws (Rendel & Ostermann 2010). That is why `writes/1` returns
  expressions over the **incoming** row only, and why no generated trigger has to
  thread the prior row through anything.

  There is exactly one deliberate exception, `touch()` in a `collapse` clause, and
  it is marked in the DSL rather than buried here for that reason.

  ## Grammar, not analysis

  `AshStrangler` does **not** accept an arbitrary expression and try to invert it.
  Every result in reversible computing points the same way — invertibility is
  guaranteed by a restricted grammar, never recovered by post-hoc analysis
  (Janus; Theseus; Sparcl, Matsuda & Wang ICFP 2020; surveyed in Glück &
  Yokoyama, *TCS* 2022). So each entity is a constructor whose reverse is
  *built*, and a free-form `expr(...)` that is not a simple reference has no
  reverse at all and must say so.

  This is the opposite of BIRDS (Tran, Kato & Hu, *PVLDB* 13(12), 2020), the
  closest existing system, in which the programmer writes **`put`** and `get` is
  derived — because `put` determines `get` uniquely while `get` does not determine
  `put`. Deriving `put` from `get` here is sound *only* because the grammar is
  restricted to (semi-)isomorphisms and demands an explicit choice wherever
  invertibility genuinely fails. Widen the invertible position to arbitrary
  expressions and this reasoning collapses; BIRDS's choice becomes the right one.
  """

  alias Ash.Query.Ref

  alias AshStrangler.{
    Affine,
    Coalesce,
    Collapse,
    Concat,
    Constant,
    Decode,
    Dsl,
    Expr,
    Key,
    Negate,
    Source,
    Unmapped
  }

  alias AshStrangler.Map, as: MapEntry
  alias AshStrangler.Sql.Printer

  @typedoc """
  The three-way classification, taken from OpenLineage's `columnLineage` facet so
  the diagram and the writability decision compute from one source.

  `:identity` is a rename, `:transformation` changes the value, `:masked` cannot
  travel back, and `:structural` has no legacy source at all (a key, a constant,
  an unmapped attribute).
  """
  @type type() :: :identity | :transformation | :masked | :structural

  @typedoc """
  How well the reverse behaves.

  `:yes` — a total bijection, proven. `:semi` — a partial isomorphism: invertible
  modulo a declared default, a separator, or a `touch()`. `:no` — no reverse
  exists; the mapping is read-only.
  """
  @type invertible() :: :yes | :semi | :no

  defstruct [
    :attribute,
    :entry,
    :combinator,
    :forward,
    :writes,
    :invertible,
    :type,
    :because,
    :sources,
    subtypes: [],
    read_only?: false,
    opaque?: false
  ]

  @type t() :: %__MODULE__{}

  @doc """
  Every lens for a resource, in declaration order, with the key's lens first.

  Accepts a compiled resource module or the mid-transform `dsl_state`, exactly
  like `AshStrangler.Info`.
  """
  @spec for_resource(Spark.Dsl.t() | Ash.Resource.t()) :: [t()]
  def for_resource(resource_or_dsl) do
    case AshStrangler.Info.source(resource_or_dsl) do
      nil ->
        []

      source ->
        Enum.map(source.keys ++ source.mappings, &of(&1, source, resource_or_dsl))
    end
  end

  @doc """
  Just the mapping lenses, keyed by the attribute they populate.

  An `unmapped [:a, :b]` contributes one lens under each of its attributes, since
  every consumer looks a lens up by the attribute it is producing.
  """
  @spec by_attribute(Spark.Dsl.t() | Ash.Resource.t()) :: %{atom() => t()}
  def by_attribute(resource_or_dsl) do
    case AshStrangler.Info.source(resource_or_dsl) do
      nil ->
        %{}

      source ->
        Enum.reduce(source.mappings, %{}, fn
          %Unmapped{attributes: attributes} = entry, acc ->
            lens = of(entry, source, resource_or_dsl)

            Enum.reduce(attributes, acc, fn attribute, acc ->
              Map.put(acc, attribute, %{
                lens
                | attribute: attribute,
                  forward: unmapped_forward(lens, attribute)
              })
            end)

          entry, acc ->
            Map.put(acc, entry.attribute, of(entry, source, resource_or_dsl))
        end)
    end
  end

  @doc """
  The lens for one mapping entity.

  `source` carries the twin, which is where column names and legacy types come
  from; `resource_or_dsl` carries the target attributes, which is where the
  derived cast, `decode`'s exhaustiveness check and `unmapped as: :default` get
  their other half. Accepts a compiled module or a mid-transform `dsl_state`.
  """
  @spec of(struct(), Source.t(), Spark.Dsl.t() | Ash.Resource.t()) :: t()
  def of(entry, %Source{twin: twin} = source, resource_or_dsl) do
    context = %{
      twin: twin,
      resource: resource_or_dsl,
      attributes: attribute_index(resource_or_dsl)
    }

    entry
    |> build(context, source)
    |> apply_read_only(entry)
  end

  # `unmapped [:a, :b], as: :default` has one forward expression per attribute, so
  # the composite lens holds them keyed by attribute and the split picks one out.
  defp unmapped_forward(%__MODULE__{combinator: :default, forward: defaults}, attribute)
       when is_map(defaults),
       do: Map.get(defaults, attribute)

  defp unmapped_forward(%__MODULE__{forward: forward}, _attribute), do: forward

  defp attribute_index(resource_or_dsl) do
    resource_or_dsl
    |> Ash.Resource.Info.attributes()
    |> Map.new(&{&1.name, &1})
  rescue
    _ -> %{}
  end

  # --- dispatch ----------------------------------------------------------------
  #
  # Grouped here rather than beside each combinator, so the set of things the
  # grammar admits is readable in one place. A struct absent from this list is not
  # a mapping, which is a claim worth being able to check at a glance.

  defp build(%MapEntry{} = entry, context, source), do: map_build(entry, context, source)
  defp build(%Decode{} = entry, context, source), do: decode_build(entry, context, source)
  defp build(%Collapse{} = entry, context, source), do: collapse_build(entry, context, source)
  defp build(%Coalesce{} = entry, context, source), do: coalesce_build(entry, context, source)
  defp build(%Concat{} = entry, context, source), do: concat_build(entry, context, source)
  defp build(%Negate{} = entry, context, source), do: negate_build(entry, context, source)
  defp build(%Affine{} = entry, context, source), do: affine_build(entry, context, source)
  defp build(%Constant{} = entry, context, source), do: constant_build(entry, context, source)
  defp build(%Unmapped{} = entry, context, source), do: unmapped_build(entry, context, source)
  defp build(%Key{} = entry, context, source), do: key_build(entry, context, source)

  # --- map ---------------------------------------------------------------------

  defp map_build(%MapEntry{from: column, zone: zone} = entry, context, _source)
       when is_atom(column) do
    map_lens(entry, context, column_ref(column), column, zone)
  end

  defp map_build(%MapEntry{from: expression, zone: zone} = entry, context, _source) do
    case Expr.simple_reference(expression) do
      {:ok, column} ->
        map_lens(entry, context, expression, column, zone)

      :error ->
        %__MODULE__{
          attribute: entry.attribute,
          entry: entry,
          combinator: if(Expr.opaque?(expression), do: :opaque, else: :expression),
          forward: expression,
          writes: [],
          invertible: :no,
          type: :masked,
          subtypes: subtypes(expression),
          opaque?: Expr.opaque?(expression),
          because: entry.because,
          sources: Expr.refs(expression)
        }
    end
  end

  # A rename, with the two things that can decorate one: a `zone:`, and a cast
  # DERIVED from the twin's column type against the target attribute's type. In
  # 0.1 that cast was `cast: :citext`, typed by hand — which restated the
  # attribute's own Ash type, and then `normalize: %{email: :ci_string}` restated
  # it a third time.
  defp map_lens(%MapEntry{} = entry, context, forward, column, zone) do
    {forward, backward, combinator, type} =
      decorate(entry, context, forward, column, zone)

    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: combinator,
      forward: forward,
      writes: [{column, backward}],
      invertible: :yes,
      type: type,
      because: entry.because,
      sources: Expr.refs(forward)
    }
  end

  defp decorate(entry, _context, forward, _column, zone) when is_binary(zone) do
    {call(:at_zone, [forward, zone]), call(:at_zone, [attr_ref(entry.attribute), zone]), :zone,
     :transformation}
  end

  defp decorate(entry, context, forward, column, nil) do
    case derived_cast(context, column, entry.attribute) do
      nil ->
        {forward, attr_ref(entry.attribute), :rename, :identity}

      {to_attribute, to_legacy} ->
        {call(:type, [forward, to_attribute]),
         call(:type, [attr_ref(entry.attribute), to_legacy]), :cast, :transformation}
    end
  end

  # The cast, or `nil` when the two sides already agree.
  #
  # Compared on the PostgreSQL type name rather than on the Ash type, because that
  # is the comparison that decides whether a cast changes anything: `:string` and
  # `:atom` are different Ash types and the same `text` column, and casting
  # between them in a view would be noise. `:string` against `:ci_string` is
  # `text` against `citext` and the cast is load-bearing — without it the view
  # column's declared type stays `text`, so `WHERE email = 'X'` through the view is
  # case-SENSITIVE while the resource says it is not.
  defp derived_cast(context, column, attribute) do
    with %{type: target} <- Map.get(context.attributes, attribute),
         legacy when not is_nil(legacy) <- twin_type(context.twin, column),
         legacy_pg = Printer.pg_type!(legacy),
         target_pg = Printer.pg_type!(target),
         true <- legacy_pg != target_pg do
      {target_pg, legacy_pg}
    else
      _ -> nil
    end
  end

  # `nil` rather than a raise when the twin has no such column: that is a stale
  # twin, and `AshStrangler.Verifiers.VerifyTwin` reports it with the
  # column named and the regeneration command. Raising from inside cast derivation
  # would report it as "no function clause" from somewhere unhelpful.
  defp twin_type(twin, column) do
    case Ash.Resource.Info.attribute(twin, column) do
      nil -> nil
      %{type: type} -> type
    end
  rescue
    _ -> nil
  end

  # --- decode ------------------------------------------------------------------

  # Rendered as SQL's *simple* `CASE subject WHEN … THEN … END` rather than as a
  # chain of nested `if`s, which is what a fold over the value table would produce.
  # Both are correct; only one is readable in a `CREATE VIEW` somebody has to
  # review, and a compatibility view is read by people far more often than a
  # migration is.
  #
  # The pairs are sorted so the rendered SQL is stable across runs. Map iteration
  # order is not guaranteed, and unstable generated SQL would make every
  # golden-output test flake and every regenerated migration look like a change.
  defp decode_build(%Decode{} = entry, _context, _source) do
    pairs = Enum.sort_by(entry.values, fn {legacy, _modern} -> inspect(legacy) end)

    forward =
      call(:strangler_case, [
        column_ref(entry.from),
        Enum.map(pairs, fn {legacy, modern} -> {legacy, modern} end),
        :none
      ])

    backward =
      call(:strangler_case, [
        attr_ref(entry.attribute),
        Enum.map(pairs, fn {legacy, modern} -> {modern, legacy} end),
        :none
      ])

    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :decode,
      forward: forward,
      writes: [{entry.from, backward}],
      invertible: :yes,
      type: :transformation,
      subtypes: [:conditional],
      because: entry.because,
      sources: [{[], entry.from}]
    }
  end

  # --- collapse ----------------------------------------------------------------

  defp collapse_build(%Collapse{} = entry, context, _source) do
    forward =
      entry.states
      |> Enum.reverse()
      |> Enum.reduce(nil, fn state, acc ->
        case state.when do
          :otherwise -> state.value
          guard -> call(:if, [guard, [do: state.value, else: acc]])
        end
      end)

    columns =
      entry.states
      |> Enum.flat_map(fn state -> Keyword.keys(state.set) end)
      |> Enum.uniq()

    writes = Enum.map(columns, &{&1, collapse_write(entry, context, &1)})

    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :collapse,
      forward: forward,
      writes: writes,
      # `touch()` is a declared loss: round-tripping :cancelled cannot recover the
      # original instant. Without one the table is a total bijection.
      invertible: if(touches?(entry), do: :semi, else: :yes),
      type: :transformation,
      subtypes: [:conditional],
      because: entry.because,
      sources: Enum.flat_map(entry.states, &guard_refs/1)
    }
  end

  # The backward direction does NOT mirror the forward guards. Forward, a clause is
  # selected by an arbitrary predicate over legacy columns; backward, it is selected
  # by the attribute's own value -- which is a literal, so the whole thing is a
  # simple `CASE attr WHEN … END` rather than a nest of predicates. That is not only
  # shorter: it is what makes the reverse *total and canonical*, because `set:` names
  # every column and the attribute's value picks exactly one row of the table.
  defp collapse_write(%Collapse{} = entry, context, column) do
    {fallback, guarded} = Enum.split_with(entry.states, &(&1.when == :otherwise))

    pairs =
      Enum.map(guarded, fn state ->
        {state.value, collapse_value(entry, context, Keyword.get(state.set, column), column)}
      end)

    default =
      case fallback do
        [state] -> collapse_value(entry, context, Keyword.get(state.set, column), column)
        [] -> :none
      end

    call(:strangler_case, [attr_ref(entry.attribute), pairs, default])
  end

  # `touch()` becomes a marker node the printer turns into the preserve-or-bump
  # `CASE`. Kept as a node rather than resolved here because the two consumers
  # need different SQL: an INSERT has no prior row, so it is `now()`, while an
  # UPDATE reads the old value out of the bare column name.
  # The column reference inside a `touch()` is carried as a NAME rather than as a
  # `Ref`, and that is load-bearing. Every other reference in a write expression is
  # a *resource attribute*, rendered `NEW.<attribute>`; this one is the legacy
  # column's previously stored value, which on the right of `UPDATE ... SET` is the
  # bare column name. Left as a `Ref` it rendered `NEW.cancelled_at` -- a column the
  # view does not have -- and the generated trigger would have failed to compile in
  # plpgsql. One expression, two frames, so the frame cannot be a parameter of the
  # whole render.
  defp collapse_value(entry, context, value, column) do
    if Dsl.Combinators.touch?(value) do
      call(:strangler_touch, [legacy_column_name(context, column), attr_ref(entry.attribute)])
    else
      value
    end
  end

  defp legacy_column_name(%{twin: twin}, column) do
    AshStrangler.Twin.column!(twin, column)
  rescue
    _ -> to_string(column)
  end

  defp touches?(%Collapse{states: states}) do
    Enum.any?(states, fn state ->
      Enum.any?(state.set, fn {_column, value} -> Dsl.Combinators.touch?(value) end)
    end)
  end

  defp guard_refs(%Collapse.State{when: :otherwise}), do: []
  defp guard_refs(%Collapse.State{when: guard}), do: Expr.refs(guard)

  # --- coalesce ----------------------------------------------------------------

  defp coalesce_build(%Coalesce{} = entry, _context, _source) do
    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :coalesce,
      forward: call(:||, [column_ref(entry.from), entry.default], true),
      # NULLIF. An iso only if the default is not otherwise a legal value in the
      # column -- which cannot be decided from the schema, so
      # `AshStrangler.Obligations` emits it as a SQL assertion instead of guessing.
      writes: [
        {entry.from,
         call(:if, [
           call(:==, [attr_ref(entry.attribute), entry.default], true),
           [do: nil, else: attr_ref(entry.attribute)]
         ])}
      ],
      invertible: :semi,
      type: :transformation,
      because: entry.because,
      sources: [{[], entry.from}]
    }
  end

  # --- concat ------------------------------------------------------------------

  # Each operand is null-defaulted before being joined, and that is not a nicety:
  # SQL's `||` propagates NULL, so a single missing `last_name` would make the whole
  # concatenation NULL and the attribute would read as nothing at all for that row.
  # A projection that silently blanks a value because one input was absent is the
  # failure class this package exists to refuse.
  #
  # It is also part of why `concat` is `invertible: :semi` rather than `:yes`. The
  # reverse cannot tell a NULL operand from an empty one -- `split_part` returns
  # `''` for both -- so round-tripping a row whose `last_name` was NULL stores `''`.
  # `AshStrangler.Obligations` names that alongside the separator condition.
  defp concat_build(%Concat{} = entry, _context, _source) do
    forward =
      entry.from
      |> Enum.map(&call(:||, [column_ref(&1), ""], true))
      |> Enum.reduce(fn right, left ->
        call(:<>, [call(:<>, [left, entry.separator], true), right], true)
      end)

    writes =
      entry.from
      |> Enum.with_index(1)
      |> Enum.map(fn {column, position} ->
        {column,
         call(:fragment, [
           "split_part(?, ?, ?)",
           attr_ref(entry.attribute),
           entry.separator,
           position
         ])}
      end)

    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :concat,
      forward: forward,
      writes: writes,
      invertible: :semi,
      type: :transformation,
      because: entry.because,
      sources: Enum.map(entry.from, &{[], &1})
    }
  end

  # --- negate ------------------------------------------------------------------

  defp negate_build(%Negate{} = entry, _context, _source) do
    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :negate,
      forward: not_expr(column_ref(entry.from)),
      writes: [{entry.from, not_expr(attr_ref(entry.attribute))}],
      invertible: :yes,
      type: :transformation,
      because: entry.because,
      sources: [{[], entry.from}]
    }
  end

  # --- affine ------------------------------------------------------------------

  defp affine_build(%Affine{} = entry, _context, _source) do
    forward =
      call(:+, [call(:*, [column_ref(entry.from), entry.multiply], true), entry.add], true)

    backward =
      call(:/, [call(:-, [attr_ref(entry.attribute), entry.add], true), entry.multiply], true)

    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :affine,
      forward: forward,
      writes: [{entry.from, backward}],
      invertible: :yes,
      type: :transformation,
      because: entry.because,
      sources: [{[], entry.from}]
    }
  end

  # --- structural --------------------------------------------------------------

  defp constant_build(%Constant{} = entry, _context, _source) do
    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :constant,
      forward: entry.expression,
      writes: [],
      invertible: :no,
      type: :structural,
      sources: [],
      because: nil
    }
  end

  defp unmapped_build(%Unmapped{as: :null} = entry, _context, _source) do
    unmapped_lens(entry, nil)
  end

  # `as: :default` was a documented option that raised *"not yet implemented"* in
  # 0.1, because nothing turned an Ash default into a SQL literal. It does now:
  # `AshStrangler.Sql.Printer.literal/1` is that function, and it is the only one.
  defp unmapped_build(%Unmapped{as: :default} = entry, context, _source) do
    defaults = Map.new(entry.attributes, &{&1, default_expression!(context, &1)})

    %{unmapped_lens(entry, defaults) | combinator: :default}
  end

  defp unmapped_lens(entry, forward) do
    %__MODULE__{
      attribute: List.first(entry.attributes),
      entry: entry,
      combinator: :unmapped,
      forward: forward,
      writes: [],
      invertible: :no,
      type: :structural,
      sources: [],
      because: entry.because
    }
  end

  # A zero-arity function default is refused rather than called. Calling it would
  # freeze one instant into the view definition, so every legacy row would read
  # the moment the migration was generated -- which is a wrong answer that looks
  # like a right one, and there is no later point at which anything notices.
  defp default_expression!(context, attribute) do
    case Map.get(context.attributes, attribute) do
      nil ->
        raise ArgumentError,
              "unmapped #{inspect(attribute)}, as: :default -- but #{inspect(attribute)} is not an attribute"

      %{default: nil} = attr ->
        raise ArgumentError, """
        unmapped #{inspect(attribute)}, as: :default -- but #{inspect(attribute)} declares no default.

        The view would select NULL, which is what `as: :null` says out loud. Say
        that instead, or give the attribute a default:

            attribute #{inspect(attribute)}, #{inspect(attr.type)}, default: ...
        """

      %{default: default} when is_function(default) ->
        raise ArgumentError, """
        unmapped #{inspect(attribute)}, as: :default -- but its default is a function.

        Evaluating it here would freeze one instant into the view definition, so
        every legacy row would read the moment the migration was generated. That is
        a wrong answer that looks like a right one.

        Use a `constant` with the SQL you actually mean:

            constant #{inspect(attribute)}, expr(now())
        """

      %{default: default} ->
        default
    end
  end

  defp key_build(%Key{} = entry, _context, _source) do
    %__MODULE__{
      attribute: entry.attribute,
      entry: entry,
      combinator: :key,
      forward: nil,
      writes: [],
      invertible: :no,
      type: :structural,
      sources: [{[], entry.from}],
      because: nil
    }
  end

  # --- read-only opt-out -------------------------------------------------------

  # Applied after the lens is built rather than instead of building it, so
  # `AshStrangler.Verifiers.VerifyDerivedWritability` can see that a reverse *was*
  # constructible and refuse a `read_only? true` that is not telling the truth.
  # In 0.1 nothing objected to a mapping claiming "not decomposable" about
  # something perfectly decomposable.
  defp apply_read_only(lens, entry) do
    if Map.get(entry, :read_only?, false) do
      %{lens | writes: [], invertible: :no, type: :masked, read_only?: true}
    else
      lens
    end
  end

  # --- accessors ---------------------------------------------------------------

  @doc """
  `{legacy_column, expression_over_resource_attributes}` for every column this
  mapping writes.

  Empty when the mapping has no reverse. The expressions reference *resource
  attributes*, not legacy columns, so they are rendered with
  `AshStrangler.Sql.Printer.new_frame/0` inside a trigger and with
  `bare_frame/1` inside the `:read_from_new` reverse view. That frame difference
  is what the deleted `String.replace(to, "$NEW.", …)` pair was doing by hand.
  """
  @spec writes(t()) :: [{atom(), AshStrangler.Expr.t()}]
  def writes(%__MODULE__{writes: writes}), do: writes

  @doc """
  The classification the diagram and the writability decision both read.

      {:identity, invertible: :yes}
  """
  @spec classify(t()) :: {type(), [invertible: invertible()]}
  def classify(%__MODULE__{type: type, invertible: invertible}),
    do: {type, invertible: invertible}

  @doc """
  Hydrates a forward expression against the twin, for the work that genuinely
  needs types.

  **The one place the hydration boundary is crossed.** Everything else in this
  package reads the unhydrated tree — see `AshStrangler.Expr` for why. Types are
  needed by exactly two callers: the type-agreement obligation, and
  `Ash.Expr.determine_types/4` behind it.

  Returns `{:error, reason}` rather than raising, because a mapping over a stale
  twin is a condition `mix ash_strangler.check` reports rather than a crash.
  """
  @spec hydrate(t(), Ash.Resource.t()) :: {:ok, AshStrangler.Expr.t()} | {:error, term()}
  def hydrate(%__MODULE__{forward: nil}, _twin), do: {:error, :no_expression}

  def hydrate(%__MODULE__{forward: forward}, twin) do
    Ash.Filter.hydrate_refs(forward, %{resource: twin, public?: false})
  end

  # `Ash.Query.Ref` carries a `defstruct` but declares no `@type t/0`, so writing
  # `Ref.t()` in a spec is an *unknown* type rather than a loose one: dialyzer
  # runs with `warnings: [:unknown]` under ash-project's shared CI workflow and
  # fails the build instead of degrading it to `any()`.
  #
  # The alias below says the same thing in a form both tools accept. It cannot be
  # written inline as `%Ref{}` in the `@spec` -- that is dialyzer-clean but trips
  # `Credo.Check.Warning.SpecWithStruct`, which only inspects `@spec`. Declaring
  # the struct once here keeps both gates green, and the day Ash publishes its own
  # `Ash.Query.Ref.t/0` this becomes a one-line delegation.
  @typedoc false
  @type ref :: %Ref{}

  @doc false
  @spec column_ref(atom()) :: ref()
  def column_ref(column), do: %Ref{attribute: column, relationship_path: [], resource: nil}

  @doc false
  @spec attr_ref(atom()) :: ref()
  def attr_ref(attribute), do: %Ref{attribute: attribute, relationship_path: [], resource: nil}

  defp not_expr(inner), do: %Ash.Query.Not{expression: inner}

  defp call(name, args, operator? \\ false),
    do: %Ash.Query.Call{name: name, args: args, operator?: operator?, relationship_path: []}

  defp subtypes(expression) do
    case Expr.refs(expression) do
      refs ->
        if Enum.any?(refs, fn {path, _attribute} -> path != [] end), do: [:join], else: []
    end
  end
end
