# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.VerifiersTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.VerifiersTest.Legacy.Accounts
    resource AshStrangler.VerifiersTest.Legacy.Profiles
  end
end

defmodule AshStrangler.VerifiersTest.Legacy.Profiles do
  @moduledoc "A second relation, so a mapping can read through a relationship."
  use Ash.Resource,
    domain: AshStrangler.VerifiersTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "profiles"
    schema "verified_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :account_id, :integer, allow_nil?: false
    attribute :city, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.VerifiersTest.Legacy.Accounts do
  @moduledoc """
  The twin every probe in this file maps onto.

  Two of its columns exist to make a *refusal* reachable, and both are stated
  here rather than in the test that needs them, because the whole point of a twin
  is that the legacy schema is declared in one place:

    * `archived_at` is an **already-aware** timestamp, which is what makes
      `zone:` on it wrong rather than merely redundant. `AT TIME ZONE` applied to
      a `timestamptz` yields a naive value, so the mapping would strip the zone it
      was trying to establish.
    * `deleted_at` is naive, which is the shape `zone:` exists for — the zone a
      naive legacy column is recorded in is a fact about the *old application*
      and cannot be inferred from the schema.
  """
  use Ash.Resource,
    domain: AshStrangler.VerifiersTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "accounts"
    schema "verified_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :login, :string, allow_nil?: false
    attribute :email, :string
    attribute :first_name, :string
    attribute :last_name, :string
    attribute :login_attempts, :integer
    attribute :is_deleted, :boolean
    attribute :deleted_at, :naive_datetime
    attribute :archived_at, :utc_datetime_usec
    attribute :dollars, :integer

    attribute :state, :atom do
      constraints one_of: [:passive, :pending, :active, :suspended, :deleted]
    end
  end

  relationships do
    has_one :profile, AshStrangler.VerifiersTest.Legacy.Profiles do
      source_attribute :id
      destination_attribute :account_id
    end
  end

  identities do
    identity :index_accounts_on_login, [:login]
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.VerifiersTest do
  @moduledoc """
  The verifiers are what this package *is*, so these tests are the product rather
  than a safety net for it.

  Each case is phrased as the mistake being caught. A verifier that fails to
  reject is not a failing test in the ordinary sense — it is a strangler
  migration that compiles and loses data, which is the failure mode this package
  exists to prevent.

  ## How these are run, and why not with `assert_raise`

  Spark verifiers do **not** raise when the module is defined. They run inside
  `__verify_spark_dsl__/1`, which `Module.ParallelChecker` invokes *after*
  compilation, in another process — so a bad DSL surfaces as
  `warning: ** (Spark.Error.DslError)` and only fails a build through
  `--warnings-as-errors`.

  Both obvious spellings therefore assert nothing:

      assert_raise Spark.Error.DslError, fn -> defmodule Broken do ... end end
      assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end

  The first catches nothing. The second is worse, because it looks like it should
  work — the module really is checked — but the failure is *printed*, not raised.
  These tests compile the module and then call `verify/1` themselves, over
  `spark_dsl_config/0`, which is the function that actually decides.

  ## Which verifier, not whichever fires first

  `assert_rejected_by/3` names the verifier under test. Several verifiers
  legitimately reject the same bad mapping — a source with no `key` also leaves
  the primary key unaccounted for — and asserting on "the first error" would make
  these tests sensitive to the order of the list in `AshStrangler.Resource`
  rather than to the behaviour under test.

  `assert_only_rejected_by/3` is the stronger form: it additionally asserts that
  **no other verifier objects**, so the test fails if the verifier is deleted
  rather than passing because something else happened to catch the same mapping.
  It is used where a refusal is the only thing standing between a mapping and
  silent data loss.

  ## What moved, and where its coverage went

  Three verifiers were deleted outright, and each rule they were reaching for is
  tested here in the form that replaced it:

  | Deleted | Now |
  |---|---|
  | `VerifyTimestampZones` | `zone:` on an already-aware twin column, refused by `VerifyNotRedundant` |
  | `VerifyWritableMappingsReversible` | `VerifyDerivedWritability` — the reverse is *constructed*, so what is left to check is whether the prose agrees with it |
  | `VerifyJoinedMappingsReadOnly` | `VerifyJoinedWritesRefused`, over a relationship path rather than a substring match on SQL |

  `AshStrangler.ObligationsTest` carries the full set of proof obligations, and
  `AshStrangler.JoinTest` carries the relationship-shaped cases, since both need
  fixtures of their own.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Verifiers

  @twin "AshStrangler.VerifiersTest.Legacy.Accounts"
  @key ~S|key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}|

  # --- harness -----------------------------------------------------------------

  defp define(body, opts \\ []) do
    name = "AshStrangler.VerifiersTest.Probe#{System.unique_integer([:positive])}"
    migrate? = Keyword.get(opts, :migrate?, false)

    # The definition itself succeeds even for an invalid mapping; the verifier
    # complaint is emitted by the parallel checker afterwards. Capturing keeps
    # that noise out of the test output.
    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string("""
        defmodule #{name} do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshStrangler.Resource]

          postgres do
            table "probe"
            schema "verified"
            repo AshStrangler.TestRepo
            migrate? #{migrate?}
          end

          actions do
            defaults [:read]
          end

          #{body}
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module.spark_dsl_config()
  end

  defp rejections(dsl) do
    for verifier <- AshStrangler.Resource.verifiers(),
        {:error, error} <- [verifier.verify(dsl)],
        do: {verifier, Exception.message(error)}
  end

  defp assert_rejected_by(verifier, body, expected, opts \\ []) do
    dsl = define(body, opts)

    case verifier.verify(dsl) do
      {:error, error} ->
        message = Exception.message(error)

        assert message =~ expected,
               "expected #{inspect(verifier)} to mention #{inspect(expected)}, got:\n\n#{message}"

        message

      other ->
        flunk("expected #{inspect(verifier)} to reject this mapping, got #{inspect(other)}")
    end
  end

  # Rejected by this verifier, and by nothing else -- so deleting the verifier
  # makes the mapping compile clean rather than being caught by a neighbour.
  defp assert_only_rejected_by(verifier, body, expected) do
    dsl = define(body)
    others = for {v, _message} <- rejections(dsl), v != verifier, do: v

    assert others == [],
           "expected only #{inspect(verifier)} to object, but so did: #{inspect(others)}"

    case verifier.verify(dsl) do
      {:error, error} ->
        message = Exception.message(error)
        assert message =~ expected
        message

      other ->
        flunk("expected #{inspect(verifier)} to reject this mapping, got #{inspect(other)}")
    end
  end

  defp assert_accepted(body, opts \\ []) do
    case body |> define(opts) |> rejections() do
      [] ->
        :ok

      rejections ->
        flunk("""
        expected every verifier to accept this mapping, but these refused it:

        #{Enum.map_join(rejections, "\n\n", fn {verifier, message} -> "#{inspect(verifier)}:\n#{message}" end)}
        """)
    end
  end

  # --- the twin ----------------------------------------------------------------

  describe "VerifyTwin" do
    test "refuses a `source` that is not a twin, and says how to generate one" do
      # `AshStrangler.DiagramTest.Plain` is an ordinary Ash resource with no data
      # layer and no table. It satisfies the option's `{:behaviour, Ash.Resource}`
      # type, which is exactly why the check has to exist: passing the behaviour is
      # not the same as being a relation this package can read.
      message =
        assert_rejected_by(
          Verifiers.VerifyTwin,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          end

          strangler do
            phase :read_from_legacy
            source AshStrangler.DiagramTest.Plain do
              key :id, from: :id, strategy: :identity
            end
          end
          """,
          "not usable as a strangler `source`"
        )

      assert message =~ "mix ash_strangler.gen.twin"
    end

    test "refuses a column the twin does not declare, which 0.1 could not detect at all" do
      # In 0.1 both `source` and `from:` were strings, so a typo in a column name
      # reached Postgres at `mix ash.migrate` time -- or, if it happened to name a
      # *different real column*, never surfaced at all.
      message =
        assert_rejected_by(
          Verifiers.VerifyTwin,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :email, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :email, from: :emial
            end
          end
          """,
          "does not resolve"
        )

      # The two possible causes, both named, because the fix differs: a typo is
      # fixed here and a stale twin is fixed by regenerating it.
      assert message =~ ":emial"
      assert message =~ "snapshot"
      assert message =~ "mix ash_strangler.gen.twin"

      # And the columns it *does* declare, so the fix does not require opening
      # another file.
      assert message =~ ":email"
    end
  end

  # --- completeness ------------------------------------------------------------

  describe "VerifyCompleteMapping" do
    test "refuses an attribute that is neither mapped nor declared unmapped" do
      message =
        assert_rejected_by(
          Verifiers.VerifyCompleteMapping,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :email, :string, public?: true
            attribute :nickname, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :email, from: :email
            end
          end
          """,
          ":nickname"
        )

      # The message has to say WHY silence is not acceptable, or the reader will
      # assume the default is harmless and add the attribute to `unmapped`
      # without thinking.
      assert message =~ "NULL"
      assert message =~ "unmapped"
    end

    test "accepts an attribute declared unmapped with a reason" do
      assert_accepted("""
      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
        attribute :email, :string, public?: true
        attribute :nickname, :string, public?: true
      end

      strangler do
        phase :read_from_legacy
        source #{@twin} do
          #{@key}
          map :email, from: :email
          unmapped [:nickname], as: :null, because: "Never existed in legacy."
        end
      end
      """)
    end
  end

  # --- the view's own name -----------------------------------------------------

  describe "VerifyNotMigrated" do
    test "refuses `migrate? true` in a view-backed phase, since codegen would create a table" do
      message =
        assert_rejected_by(
          Verifiers.VerifyNotMigrated,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :email, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :email, from: :email
            end
          end
          """,
          "must set `migrate? false`",
          migrate?: true
        )

      # Both halves of the trap. `true` collides -- `mix ash.codegen` emits a
      # `create table` for the view's name -- and `false` means AshPostgres
      # produces no snapshot, which is where `custom_statements` are read from. So
      # there is no setting in which the ordinary codegen path can carry the DDL,
      # which is why `mix ash_strangler.gen.migration` exists.
      assert message =~ "names a VIEW"
      assert message =~ "custom_statements"
    end
  end

  # --- redundancy: the anti-restatement check ----------------------------------

  describe "VerifyNotRedundant" do
    test "refuses `zone:` on an already-aware twin column, which would strip the zone" do
      # What `VerifyTimestampZones` became. The old check refused
      # `cast: :timestamptz` without `from_zone:`, because a bare cast reads a naive
      # column as wall-clock time in the *session's* TimeZone -- measured at 10.5
      # hours of drift between two connections reading the same row.
      #
      # There is no `cast:` to forget a zone on any more: `zone:` is the only way
      # to say it, and it emits `AT TIME ZONE`, which is both deterministic and
      # `IMMUTABLE` enough to carry an index. So the remaining mistake is the
      # mirror image -- applying it to a column that is *already* aware, which
      # converts an instant back into a naive value.
      message =
        assert_rejected_by(
          Verifiers.VerifyNotRedundant,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :archived_at, :utc_datetime_usec, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :archived_at, from: :archived_at, zone: "UTC"
            end
          end
          """,
          ":archived_at"
        )

      # It has to say the transform is *wrong* rather than merely unnecessary,
      # because "redundant" would invite leaving it in.
      assert message =~ "worse than redundant"
      assert message =~ "WITHOUT time zone"
      assert message =~ "Drop the `zone:`"
    end

    test "accepts `zone:` on a naive column, which is the shape it exists for" do
      assert_accepted("""
      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
        attribute :archived_at, :utc_datetime_usec, public?: true
      end

      strangler do
        phase :read_from_legacy
        source #{@twin} do
          #{@key}
          map :archived_at, from: :deleted_at, zone: "UTC"
        end
      end
      """)
    end

    test "refuses `affine multiply: 1, add: 0`, which is the identity written out" do
      message =
        assert_rejected_by(
          Verifiers.VerifyNotRedundant,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :dollars, :integer, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              affine :dollars, from: :dollars, multiply: 1, add: 0
            end
          end
          """,
          "which is `x`"
        )

      assert message =~ "map :attribute, from: :legacy_column"
    end

    test "refuses a `concat` of one column, which joins it to nothing" do
      message =
        assert_rejected_by(
          Verifiers.VerifyNotRedundant,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :full_name, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              concat :full_name, from: [:first_name], separator: " "
            end
          end
          """,
          "joins it to nothing"
        )

      # The cost is the point of the refusal: `concat`'s reverse is `split_part`,
      # which is only correct while the separator is provably absent from every
      # operand -- a condition that has to be measured against real data. Paying
      # that for one column buys nothing.
      assert message =~ "split_part"
    end
  end

  # --- writability: derived, not declared --------------------------------------

  describe "VerifyDerivedWritability" do
    test "refuses a computed mapping with no reverse, and nothing else would catch it" do
      # The rule `VerifyWritableMappingsReversible` was reaching for and missed. It
      # checked that `to:` and `into:` were *present*, never that they inverted
      # `from:` -- so a `CASE` that mapped five legacy lifecycle values onto two
      # codes and wrote `1` back as `'suspended'` passed all nine verifiers, and
      # shipped, and rewrote three of five states on an UPDATE that assigned only
      # an email.
      #
      # There is no `to:` to check now. What is left is whether a mapping with no
      # constructible reverse says so -- and this is the only verifier that asks,
      # which is why the assertion is the exclusive form.
      message =
        assert_only_rejected_by(
          Verifiers.VerifyDerivedWritability,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :state_label, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :state_label, from: expr(fragment("upper(?::text)", state))
            end
          end
          """,
          "no constructible reverse"
        )

      # The alternative offered is a combinator, never a hand-written inverse.
      # That is the whole difference: one declaration from which both directions
      # are derived cannot disagree with itself.
      assert message =~ "decode"
      assert message =~ "read_only?: true"
      assert message =~ "because:"
    end

    test "refuses `read_only? true` with no `because:`, because that text is the runtime error" do
      message =
        assert_rejected_by(
          Verifiers.VerifyDerivedWritability,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :full_name, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :full_name,
                from: expr((first_name || "") <> " " <> (last_name || "")),
                read_only?: true
            end
          end
          """,
          "no `because:`"
        )

      # Why it is mandatory rather than encouraged: the text is quoted verbatim in
      # the trigger's own error, so it is what somebody reads at 3am. "Not
      # writable" tells them nothing.
      assert message =~ "runtime"
    end

    test "refuses a `because:` on a mapping whose reverse the grammar built" do
      # The direction the drift actually took in 0.1: a mapping claiming "not
      # decomposable" about something perfectly decomposable, with nothing
      # objecting. Prose asserting a limitation the mapping does not have is
      # exactly what this design exists to remove.
      message =
        assert_rejected_by(
          Verifiers.VerifyDerivedWritability,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :login, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :login, from: :login, because: "Not decomposable."
            end
          end
          """,
          "gives a `because:` but is not `read_only?: true`"
        )

      assert message =~ "Either drop the `because:`"
    end

    test "accepts a read-only computed mapping with a reason" do
      assert_accepted("""
      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
        attribute :full_name, :string, public?: true
      end

      strangler do
        phase :read_from_legacy
        source #{@twin} do
          #{@key}
          map :full_name,
            from: expr((first_name || "") <> " " <> (last_name || "")),
            read_only?: true,
            because: "Not decomposable: 'de la Cruz' splits wrong."
        end
      end
      """)
    end
  end

  # --- joined writes -----------------------------------------------------------

  describe "VerifyJoinedWritesRefused" do
    test "refuses a mapping that reads through a relationship and still writes" do
      # `VerifyJoinedMappingsReadOnly` detected this by looking for the join's
      # alias as a substring of the mapping's SQL -- `String.contains?(expression,
      # "addr.")` -- a heuristic with the same failure mode as the deleted lineage
      # regex: a column named `addr_line1` in a schema with a join aliased `addr`
      # is a false positive waiting to happen.
      #
      # The reference now carries its relationship path as data, so there is
      # nothing to match. A `collapse` is the shape that reaches this verifier: its
      # guards are expressions, so one can read a joined column, while its `set:`
      # writes columns of the primary relation.
      message =
        assert_rejected_by(
          Verifiers.VerifyJoinedWritesRefused,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :locality, :atom, public?: true, constraints: [one_of: [:local, :remote]]
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}

              collapse :locality do
                state :local, when: expr(profile.city == "London"), set: [is_deleted: false]
                state :remote, when: :otherwise, set: [is_deleted: true]
              end
            end
          end
          """,
          "profile.city"
        )

      # Why there is no write to generate: `__legacy_id` identifies one row of the
      # primary relation and nothing identifies the corresponding row of a joined
      # one -- and under a LEFT JOIN there may not be one.
      assert message =~ "__legacy_id"
      assert message =~ "LEFT JOIN"
      assert message =~ "its own resource"
    end
  end

  # --- the proof obligations ---------------------------------------------------

  describe "VerifyObligations" do
    test "refuses a decode that cannot produce a value for every legacy value" do
      # One case here so this file covers the verifier; `AshStrangler.ObligationsTest`
      # carries the full set, including the counterexample tables.
      message =
        assert_rejected_by(
          Verifiers.VerifyObligations,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :state_code, :integer, public?: true, constraints: [min: 0, max: 1]
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              decode :state_code, from: :state, values: %{active: 0, suspended: 1}
            end
          end
          """,
          "GetTotal"
        )

      # The three lifecycle values 0.1's `ELSE 1` silently rewrote, named.
      assert message =~ ":passive"
      assert message =~ ":pending"
      assert message =~ ":deleted"
    end
  end

  # --- the INSTEAD OF trade ----------------------------------------------------

  describe "VerifyNoUpserts" do
    test "refuses an upsert action when writes go through INSTEAD OF triggers" do
      message =
        assert_rejected_by(
          Verifiers.VerifyNoUpserts,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :login, :string, public?: true
          end

          identities do
            identity :unique_login, [:login]
          end

          actions do
            defaults [:read]
            create :create do
              upsert? true
              upsert_identity :unique_login
            end
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              writes :triggers
              #{@key}
              map :login, from: :login
            end
          end
          """,
          ":create"
        )

      # The message must explain the silent half of the failure. `DO UPDATE`
      # errors loudly; `DO NOTHING` is accepted and does nothing, and that is the
      # one that reaches production.
      assert message =~ "DO NOTHING"
      assert message =~ "writes: :auto"

      # And it must point at the mapping rather than at the action, because the
      # upsert is usually not removable: `ash_authentication`'s OAuth2 and OIDC
      # register actions cannot be defined without one.
      assert message =~ "WHICH mapping forced the triggers"
    end

    test "accepts the same upsert when writes rely on view auto-updatability" do
      assert_accepted("""
      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
        attribute :login, :string, public?: true
      end

      identities do
        identity :unique_login, [:login]
      end

      actions do
        defaults [:read]
        create :create do
          upsert? true
          upsert_identity :unique_login
        end
      end

      strangler do
        phase :read_from_legacy
        source #{@twin} do
          writes :auto
          #{@key}
          map :login, from: :login
        end
      end
      """)
    end
  end

  # --- the one-way door --------------------------------------------------------

  describe "VerifyReverseMappable" do
    test "refuses :read_from_new for a mapping that reverses only modulo a default" do
      # A tightening over 0.1, which refused only `invertible: :no`. A `coalesce`
      # reverses with `NULLIF`, which is an isomorphism *only* if the default is not
      # otherwise a legal value in the column -- a fact about the data, not the
      # schema. Modulo-something is fine for a dual-write trigger, where the legacy
      # row still exists to be compared against. It is not fine for the phase in
      # which the legacy table stops existing.
      message =
        assert_rejected_by(
          Verifiers.VerifyReverseMappable,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :attempts, :integer, public?: true
          end

          strangler do
            phase :read_from_new
            source #{@twin} do
              #{@key}
              coalesce :attempts, from: :login_attempts, default: 0
            end
          end
          """,
          ":attempts"
        )

      assert message =~ "modulo"

      # The cost, stated where it is decided: the legacy columns behind an
      # irreversible mapping read NULL for the old application from the moment the
      # cutover runs, which is the least recoverable moment in the migration.
      assert message =~ "point of no return"
    end
  end

  # --- identities --------------------------------------------------------------

  describe "VerifyIdentitiesBacked" do
    test "refuses an identity no uniqueness constraint on the twin backs" do
      message =
        assert_rejected_by(
          Verifiers.VerifyIdentitiesBacked,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :email, :string, public?: true
          end

          identities do
            identity :unique_email, [:email]
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              #{@key}
              map :email, from: :email
            end
          end
          """,
          "not backed by a uniqueness constraint"
        )

      # The reason this matters is the point of the check: Ash reports "already
      # been taken" for a constraint the database does not have, and accepts
      # duplicates with no error raised.
      assert message =~ "duplicates are accepted"

      # Uniqueness is an `identity` on the twin now, read from `pg_index` by the
      # generator rather than retyped as `index "...", unique: true`. So the fix
      # is to regenerate, and the error says so.
      assert message =~ "mix ash_strangler.gen.twin"
    end

    test "refuses an identity over a computed mapping, which cannot carry a constraint" do
      assert_rejected_by(
        Verifiers.VerifyIdentitiesBacked,
        """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :full_name, :string, public?: true
        end

        identities do
          identity :unique_name, [:full_name]
        end

        strangler do
          phase :read_from_legacy
          source #{@twin} do
            #{@key}
            map :full_name,
              from: expr((first_name || "") <> " " <> (last_name || "")),
              read_only?: true,
              because: "Not decomposable."
          end
        end
        """,
        "not mapped to a plain legacy column"
      )
    end

    test "accepts an identity the twin declares an identity for" do
      assert_accepted("""
      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
        attribute :login, :string, public?: true
      end

      identities do
        identity :unique_login, [:login]
      end

      strangler do
        phase :read_from_legacy
        source #{@twin} do
          #{@key}
          map :login, from: :login
        end
      end
      """)
    end
  end

  # --- phase -------------------------------------------------------------------

  describe "VerifyPhaseTransition" do
    test "refuses a source with no key derivation" do
      message =
        assert_rejected_by(
          Verifiers.VerifyPhaseTransition,
          """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            attribute :email, :string, public?: true
          end

          strangler do
            phase :read_from_legacy
            source #{@twin} do
              map :email, from: :email
            end
          end
          """,
          "declares no `key`"
        )

      # Deterministic is the requirement, and the message says why: a lookup table
      # is a second source of truth and a migration-time join on every row.
      assert message =~ "deterministic"
    end

    test "refuses a write phase with a read-only mapping whose reason is blank" do
      # Reaching this requires getting past `VerifyDerivedWritability`, which is
      # why `because:` is present but whitespace rather than absent. The two
      # verifiers are asking different questions -- one whether the prose exists,
      # the other whether writes are enabled while an attribute silently will not
      # propagate -- and this is the seam between them.
      assert_rejected_by(
        Verifiers.VerifyPhaseTransition,
        """
        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
          attribute :full_name, :string, public?: true
        end

        strangler do
          phase :dual_write
          source #{@twin} do
            #{@key}
            map :full_name,
              from: expr((first_name || "") <> " " <> (last_name || "")),
              read_only?: true,
              because: "   "
          end
        end
        """,
        "read-only without a stated reason"
      )
    end
  end
end
