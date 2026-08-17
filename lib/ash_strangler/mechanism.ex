# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Mechanism do
  @moduledoc """
  Which PostgreSQL mechanism carries each write, chosen as the **weakest one that
  works**.

  This is the largest practical result in DSL v2, and it comes from the PostgreSQL
  manual rather than from any of the type theory. `CREATE VIEW` documents a
  **column-level** rule that is easy to read past:

  > A column is updatable if it is a **simple reference to an updatable column of
  > the underlying base relation**; otherwise the column is read-only, and an error
  > will be raised if an `INSERT`, `UPDATE`, or `MERGE` statement attempts to
  > assign a value to it.

  So an automatically updatable view may hold a **mix** of updatable and read-only
  columns. A computed column does not force a trigger; it forces an error only if
  something assigns to it.

  ## What 0.1 got wrong, and what it cost

  `AshStrangler.Info`'s `derive_writes/1` used to treat *any* writable computed
  mapping as forcing `INSTEAD OF` triggers for the whole resource. Measured on
  PostgreSQL 17.10, on a view with two plain references and two computed columns
  and **no triggers**:

      column     | pg_column_is_updatable
      -----------+------------------------
      id         | t
      email      | t
      full_name  | f
      state_code | f

      UPDATE mixed_v SET email = 'b@example.com';        -- succeeds
      UPDATE mixed_v SET full_name = 'Nope';
        ERROR:  cannot update column "full_name" of view "users_v"
      DELETE FROM mixed_v WHERE id = 1;                  -- succeeds
      INSERT INTO mixed_v (email) VALUES ('c@example.com')
        ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email
        RETURNING id, email, full_name, state_code;      -- works, insert and conflict alike

  **Upserts, `RETURNING` and `WITH CHECK OPTION` are lost to the trigger, not to
  the computation.** That correction matters beyond tidiness: the reference
  application's migration plan concluded that *authentication must cut over first*,
  because one computed-but-writable mapping drags in a trigger, which costs
  upserts, which breaks `ash_authentication`'s OAuth2 strategies — and those
  strategies cannot be defined without an upsert. The reasoning was sound and the
  premise was wrong. With mechanism tiering the view stays auto-updatable and the
  recommended *order* of a real migration changes.

  ## The four tiers

  | Shape | Mechanism | Cost |
  |---|---|---|
  | a simple reference — a rename | `:plain`, the auto-updatable view | **none** |
  | immutable, single-row, derived, never written back | `:generated` — `GENERATED ALWAYS AS (…) STORED` on the base table | declarative DDL, indexable, no trigger, no backfill |
  | row-local derivation that must be written back | `:base_trigger` — a `BEFORE` trigger on the **base table** plus a shadow column (pgroll's design) | one trigger on the legacy table; the view stays auto-updatable |
  | multi-table write, or no reverse at all | `:instead_of` | loses upserts, correct `RETURNING`, `WITH CHECK OPTION` |

  A resource needs `INSTEAD OF` triggers only when at least one mapping lands in
  the last tier, which is what `AshStrangler.Info.writes/1` now asks.

  ## What this version actually emits, and what it does not

  **`:plain` and `:instead_of` are emitted. `:generated` and `:base_trigger` are
  classified but not emitted**, and `emitted/1` folds them up to `:instead_of` so
  nothing silently has no write path.

  Saying that plainly matters, because it is a limit on the headline result above.
  Both unemitted tiers require DDL against the **legacy** table — a shadow column,
  which means `ALTER TABLE legacy.users ADD COLUMN`, and for `:generated` a full
  table rewrite under an `ACCESS EXCLUSIVE` lock. A migration generator should not
  do that to a table this package does not own without an operator deciding to.
  pgroll does exactly this and is right to; it is also an interactive tool driven by
  a person, not a `mix` task that runs in CI.

  So the practical win in this version is narrower than the classification, and it
  is worth being exact about which part is real:

  - **Real, and tested.** A resource whose computed columns are all *read-only* —
    the common shape — keeps `writes: :auto`, and upserts, `RETURNING` and
    `WITH CHECK OPTION` survive on that mixed view. `AshStrangler.Test.MixedUser`
    proves it against a live database.
  - **Real, and stricter than 0.1.** A writable `zone:` or cast mapping now gets a
    write path. 0.1's rule was "any mapping with an explicit `to:` forces triggers",
    so a `cast: :timestamptz, from_zone:` mapping got `:auto` and its view column
    was not auto-updatable — an `UPDATE` of it errored at runtime, and only the
    presence of some *other* mapping with a `to:` accidentally covered it.
  - **Classified, not yet emitted.** A `decode`d status column deserves
    `:base_trigger` and is emitted as `:instead_of`.
    `mix ash_strangler.check` prints both, so the cost of the gap — and the DDL that
    would close it — is visible rather than assumed.

  That last row is the one that qualifies the correction to the reference
  application's *authentication must cut over first* conclusion. The premise really
  is wrong — a `decode`d `state_code` does not *require* a trigger — but closing it
  requires a shadow column on `legacy.users`, so the migration order changes only
  once somebody adds one. `report/1` is what tells them it is worth doing.

  Two PostgreSQL facts constrain the two unemitted tiers, and they are recorded
  here so they are not rediscovered:

  1. **Generated columns cannot be chained, and cannot be read from a `BEFORE`
     trigger.** So a composed mapping has to be *inlined* by the compiler into one
     flat expression — possible only because the layer is structured — and exactly
     one mechanism has to be chosen per column.
  2. **`GENERATED ALWAYS AS` requires an `IMMUTABLE` expression.** `zone:` clears
     that bar (`timezone(text, timestamp)` is `IMMUTABLE`); a bare
     `::timestamptz`, `date(timestamptz)`, `to_char(timestamp, text)` and the
     zero-argument timezone forms do not. Never resolve such a complaint with
     `ALTER FUNCTION … IMMUTABLE`: a mismarked function produces an index that
     disagrees with the heap, and the symptom is wrong rows with no error.
  """

  alias AshStrangler.{Expr, Lens}

  @typedoc """
  The weakest mechanism that carries a mapping's write.

  `:none` is a mapping with no write direction at all — a `constant`, an
  `unmapped`, a `read_only?` mapping. It costs nothing because nothing is written.
  """
  @type t() :: :none | :plain | :generated | :base_trigger | :instead_of

  @doc """
  The mechanism for one lens.

  ## Examples

      iex> import Ash.Expr
      iex> source = %AshStrangler.Source{twin: nil, mappings: [], keys: []}
      iex> lens = AshStrangler.Lens.of(%AshStrangler.Map{attribute: :login, from: :login}, source, %{})
      iex> AshStrangler.Mechanism.classify(lens)
      :plain
  """
  @spec classify(Lens.t()) :: t()
  def classify(%Lens{writes: []}), do: :none

  def classify(%Lens{invertible: :no}), do: :none

  def classify(%Lens{} = lens) do
    cond do
      # A rename is a simple reference to a column of the base relation, which is
      # the exact wording of the `CREATE VIEW` rule. Nothing to emit.
      lens.combinator == :rename and single_column?(lens) -> :plain
      # More than one legacy column written, or a column read through a
      # relationship: the write is not row-local to one base table, so nothing
      # weaker than an INSTEAD OF trigger can carry it.
      cross_relation?(lens) -> :instead_of
      length(lens.writes) > 1 -> :instead_of
      # Row-local and reversible. A base-table BEFORE trigger plus a shadow column
      # would do it and keep the view auto-updatable -- classified, not emitted.
      true -> :base_trigger
    end
  end

  @doc """
  The mechanism this version actually emits for a lens.

  `:generated` and `:base_trigger` fold up to `:instead_of`, because emitting them
  would mean DDL against the legacy table. Folding *up* rather than down is the
  only safe direction: folding down would leave a writable computed column with no
  write path at all, and PostgreSQL would report that as an error on the first
  `UPDATE` rather than at compile time.
  """
  @spec emitted(Lens.t()) :: :none | :plain | :instead_of
  def emitted(lens) do
    case classify(lens) do
      :none -> :none
      :plain -> :plain
      _ -> :instead_of
    end
  end

  @doc """
  The strongest mechanism any mapping on the resource needs — the one that decides
  whether the whole view gets `INSTEAD OF` triggers.

  Ordered, so `max` is meaningful: `:none < :plain < :generated < :base_trigger <
  :instead_of`.
  """
  @spec resource_mechanism(Spark.Dsl.t() | Ash.Resource.t()) :: t()
  def resource_mechanism(resource_or_dsl) do
    resource_or_dsl
    |> Lens.for_resource()
    |> Enum.map(&emitted/1)
    |> strongest()
    |> escalate_for_joins(resource_or_dsl)
  end

  # A join makes the whole VIEW non-updatable, not just the columns that cross it,
  # and that is a fact about `CREATE VIEW` rather than about any one mapping:
  # automatic updatability requires exactly one base relation.
  #
  # So per-column classification is not sufficient on its own. A resource whose only
  # *writable* mapping is a plain rename, alongside a read-only `expr(address.city)`,
  # classifies every column `:plain` or `:none` -- and resolves to `writes: :auto`,
  # emitting no triggers, on a view PostgreSQL will not accept a write to.
  # `pg_relation_is_updatable` on such a view returns `0` for every column, and the
  # only symptom is an error on the first `UPDATE`.
  #
  # Measured, and worth stating plainly because the per-column rule is the headline
  # result of this module and this is its boundary: the rule narrows *which* mappings
  # force a trigger within one base relation. It does not survive a second one.
  defp escalate_for_joins(:none, _resource_or_dsl), do: :none

  defp escalate_for_joins(mechanism, resource_or_dsl) do
    if AshStrangler.Info.joins(resource_or_dsl) == [], do: mechanism, else: :instead_of
  end

  @order [:none, :plain, :generated, :base_trigger, :instead_of]

  @doc false
  @spec strongest([t()]) :: t()
  def strongest([]), do: :none

  def strongest(mechanisms),
    do: Enum.max_by(mechanisms, &Enum.find_index(@order, fn m -> m == &1 end))

  @doc """
  The classification for every mapping, as `{attribute, ideal, emitted}` in
  declaration order.

  This is what `mix ash_strangler.check` prints, and it is the answer to the
  question a migration actually turns on: *which* mapping is costing me upserts,
  and would anything cheaper do.

  Reporting both columns is the point. One number would either overstate what the
  generator does or hide what the schema could support.
  """
  @spec report(Spark.Dsl.t() | Ash.Resource.t()) :: [{atom(), t(), t()}]
  def report(resource_or_dsl) do
    resource_or_dsl
    |> Lens.for_resource()
    |> Enum.reject(&(&1.combinator == :key))
    |> Enum.map(&{&1.attribute, classify(&1), emitted(&1)})
  end

  defp single_column?(%Lens{writes: [{_column, _expr}], sources: sources}) do
    length(sources) <= 1
  end

  defp single_column?(_lens), do: false

  # A mapping reading through a relationship writes to a relation the trigger
  # cannot identify a row in: nothing in the declaration says which joined row a
  # view row came from, and under a LEFT JOIN there may not be one. The correct
  # answer is its own resource -- see `AshStrangler.Verifiers.VerifyJoinedWritesRefused`.
  defp cross_relation?(%Lens{sources: sources, forward: forward}) do
    Enum.any?(sources, fn {path, _attribute} -> path != [] end) or
      (not is_nil(forward) and forward_crosses?(forward))
  end

  defp forward_crosses?(forward) do
    forward
    |> Expr.refs()
    |> Enum.any?(fn {path, _attribute} -> path != [] end)
  end
end
