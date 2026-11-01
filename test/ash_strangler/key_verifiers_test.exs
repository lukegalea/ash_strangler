# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.KeyVerifiersTest do
  @moduledoc """
  Negative compile fixtures for the key-kind registry (`VerifyKeyKinds`), V-KEY
  (`VerifyKey`), V-REF (`VerifyReferences`) and the twin policy
  (`AddTwinPolicy`).

  Verifier failures are printed by the parallel checker rather than raised
  (see `AshStrangler.VerifiersTest`), so each case compiles a probe and calls
  the verifier over its `spark_dsl_config/0`. A transformer error is raised
  during compilation, so those cases assert the raise.
  """

  # Serial: compiling probes swaps the global :standard_error device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Verifiers.{VerifyKey, VerifyKeyKinds, VerifyReferences}

  @catalog "test/fixtures/snapshot/library/catalog.json"
  @keys "AshStrangler.Test.Library.Keys"

  defp name, do: "AshStrangler.KeyVerifiersTest.Probe#{System.unique_integer([:positive])}"

  defp compile(source) do
    {module, _output} =
      with_io(:stderr, fn ->
        source |> Code.compile_string() |> Enum.map(&elem(&1, 0)) |> List.last()
      end)

    module
  end

  defp rejection(verifier, module) do
    case verifier.verify(module.spark_dsl_config()) do
      {:error, error} -> Exception.message(error)
      other -> flunk("#{inspect(verifier)} accepted #{inspect(module)}: #{inspect(other)}")
    end
  end

  defp registry(body, snapshot \\ nil) do
    compile("""
    defmodule #{name()} do
      use AshStrangler.KeyKinds

      key_kinds do
        estate 0x4C42
        #{if snapshot, do: "snapshot #{inspect(snapshot)}"}
        #{body}
      end
    end
    """)
  end

  # A resource over one of the library twins, in `phase`, with `body` inside
  # its source.
  defp resource(twin, body, opts \\ []) do
    attributes =
      Keyword.get(opts, :attributes, [:ref])
      |> Enum.map_join("\n", &"    attribute #{inspect(&1)}, :uuid, public?: true")

    compile("""
    defmodule #{name()} do
      use Ash.Resource,
        domain: AshStrangler.Test.Library,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

      postgres do
        table "probe_#{System.unique_integer([:positive])}"
        schema "lending"
        repo AshStrangler.TestRepo
        migrate? false
      end

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    #{attributes}
      end

      actions do
        defaults [:read]
      end

      strangler do
        phase #{inspect(Keyword.get(opts, :phase, :read_from_legacy))}

        source #{twin} do
          #{Keyword.get(opts, :source_opts, "")}
          #{body}
        end
      end
    end
    """)
  end

  defp library(table), do: "AshStrangler.Test.Library.Legacy.#{table}"

  describe "VerifyKeyKinds" do
    test "accepts the fixture registry" do
      assert VerifyKeyKinds.verify(AshStrangler.Test.Library.Keys.spark_dsl_config()) == :ok
    end

    test "refuses reused, reserved and out-of-range tags, over-wide kinds and bad parts" do
      module =
        registry("""
        reserved [0x00F]
        kind :a, 0x001, parts: [{"s.t.a", 32}]
        kind :b, 0x001, parts: [{"s.t.b", 32}]
        kind :c, 0x00F, parts: [{"s.t.c", 32}]
        kind :d, 0x1000, parts: [{"s.t.d", 32}]
        kind :e, 0x002, parts: [{"s.t.e", 64}, {"s.t.f", 64}]
        kind :f, 0x003, parts: [{"no_dots", 16}]
        kind :a, 0x004, parts: [{"s.t.g", 16}]
        """)

      message = rejection(VerifyKeyKinds, module)

      assert message =~ "tag 0x001 is used by :a and :b"
      assert message =~ "kind :c: tag 0x00F is reserved"
      assert message =~ "kind :d: tag 0x1000 is not a 12-bit tag"
      assert message =~ "kind :e: widths [64, 64] sum to 128 bits"
      assert message =~ ~s|kind :f: part "no_dots" is not|
      assert message =~ "kind :a is declared more than once"
    end

    test "refuses parts the snapshot contradicts, naming the column" do
      module =
        registry(
          """
          kind :nullable, 0x001, parts: [{"library.members.referrer_id", 32}]
          kind :text, 0x002, parts: [{"library.members.email", 32}]
          kind :narrow, 0x003, parts: [{"library.loans.id", 32}]
          kind :no_relation, 0x004, parts: [{"library.nope.id", 32}]
          kind :no_column, 0x005, parts: [{"library.members.nope", 32}]
          """,
          @catalog
        )

      message = rejection(VerifyKeyKinds, module)

      assert message =~ "`library.members.referrer_id` is nullable"
      assert message =~ "`library.members.email` is text, not smallint, integer or bigint"
      assert message =~ "`library.loans.id` is bigint (64 bits) but the kind packs it in 32"
      assert message =~ "no relation `library.nope`"
      assert message =~ "`library.members.nope`: the snapshot catalog has no such column"
    end
  end

  describe "VerifyKey (V-KEY)" do
    test "accepts the fixture resources" do
      for resource <- [
            AshStrangler.Test.Library.Member,
            AshStrangler.Test.Library.Copy,
            AshStrangler.Test.Library.Loan,
            AshStrangler.Test.Library.Card
          ] do
        assert VerifyKey.verify(resource.spark_dsl_config()) == :ok
      end
    end

    test "a packed key needs a pinned twin" do
      module =
        resource(
          "AshStrangler.Test.Legacy.Users",
          "key :id, from: :id, strategy: {:uuid_v8, #{@keys}, :member}",
          attributes: []
        )

      assert rejection(VerifyKey, module) =~ "is not pinned to a snapshot"
    end

    test "a packed key reads exactly its kind's columns, which must be unique" do
      module =
        resource(
          library("Loans"),
          "key :id, from: :member_id, strategy: {:uuid_v8, #{@keys}, :member}",
          attributes: []
        )

      message = rejection(VerifyKey, module)
      assert message =~ "kind :member packs `library.members.id`"
      assert message =~ "hold no primary key or non-partial unique index"
    end

    test "the arity must match the kind" do
      module =
        resource(
          library("Copies"),
          "key :id, from: :branch_id, strategy: {:uuid_v8, #{@keys}, :copy}",
          attributes: []
        )

      assert rejection(VerifyKey, module) =~ "names 1 column(s); kind :copy packs 2"
    end

    test "a column wider than its part is refused" do
      narrow =
        registry("""
        kind :member, 0x001, parts: [{"library.members.id", 16}]
        """)

      module =
        resource(
          library("Members"),
          "key :id, from: :id, strategy: {:uuid_v8, #{inspect(narrow)}, :member}",
          attributes: []
        )

      assert rejection(VerifyKey, module) =~
               "`id` is integer (32 bits); kind :member packs that part in 16"
    end

    test "an unknown kind is refused" do
      module =
        resource(
          library("Members"),
          "key :id, from: :id, strategy: {:uuid_v8, #{@keys}, :nope}",
          attributes: []
        )

      assert rejection(VerifyKey, module) =~ "declares no key kind :nope"
    end

    test "a composite key needs a packed strategy" do
      module =
        resource(
          library("Copies"),
          ~S|key :id, from: [:branch_id, :copy_no], strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}|,
          attributes: []
        )

      assert rejection(VerifyKey, module) =~ "a composite `from` needs a packed strategy"
    end

    test "a composite key stays read-only, and carries no notify or ledger" do
      key = "key :id, from: [:branch_id, :copy_no], strategy: {:uuid_v8, #{@keys}, :copy}"

      written = resource(library("Copies"), key, attributes: [], phase: :dual_write)
      assert rejection(VerifyKey, written) =~ "stays in :read_from_legacy"

      notified = resource(library("Copies"), key, attributes: [], source_opts: "notify? true")
      assert rejection(VerifyKey, notified) =~ "cannot carry `notify?` or `ledger?`"
    end

    test "an :identity key on a pinned twin must be a uuid" do
      module =
        resource(library("Members"), "key :id, from: :id, strategy: :identity", attributes: [])

      assert rejection(VerifyKey, module) =~
               "`id` is integer; an :identity key passes a uuid through"
    end
  end

  describe "VerifyReferences (V-REF)" do
    @key "key :id, from: :id, strategy: {:uuid_v8, #{@keys}, :member}"

    test "accepts the fixture resources" do
      for resource <- [
            AshStrangler.Test.Library.Member,
            AshStrangler.Test.Library.Copy,
            AshStrangler.Test.Library.Loan,
            AshStrangler.Test.Library.Card
          ] do
        assert VerifyReferences.verify(resource.spark_dsl_config()) == :ok
      end
    end

    test "soft: on a reference the snapshot closes is refused" do
      module =
        resource(library("Members"), """
        #{@key}
        reference :ref, kind: {#{@keys}, :branch}, from: :home_branch_id, soft: "because"
        """)

      assert rejection(VerifyReferences, module) =~ "Delete `soft:`"
    end

    test "a reference with no validated foreign key must say why" do
      module =
        resource(library("Members"), """
        #{@key}
        reference :ref, kind: {#{@keys}, :member}, from: :referrer_id
        """)

      assert rejection(VerifyReferences, module) =~
               "no validated foreign key in the snapshot maps `from` onto `library.members.id`"
    end

    test "an unpinned twin cannot prove closure" do
      module =
        resource("AshStrangler.Test.Legacy.Users", """
        key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
        reference :ref, kind: {#{@keys}, :member}, from: :id
        """)

      assert rejection(VerifyReferences, module) =~ "the twin is not pinned to a snapshot"
    end

    test "a column wider than its part, or not an integer, is refused" do
      wide =
        resource(library("Loans"), """
        key :id, from: :id, strategy: {:uuid_v8, #{@keys}, :loan}
        reference :ref, kind: {#{@keys}, :member}, from: :copy_no, soft: "a probe"
        """)

      assert rejection(VerifyReferences, wide) =~
               "`copy_no` is bigint (64 bits); kind :member packs that part in 32"

      text =
        resource(library("Members"), """
        #{@key}
        reference :ref, kind: {#{@keys}, :member}, from: :email, soft: "a probe"
        """)

      assert rejection(VerifyReferences, text) =~ "every `from` column must be an integer"
    end

    test "the arity must match the kind" do
      module =
        resource(library("Loans"), """
        key :id, from: :id, strategy: {:uuid_v8, #{@keys}, :loan}
        reference :ref, kind: {#{@keys}, :copy}, from: :branch_id
        """)

      assert rejection(VerifyReferences, module) =~ "names 1 column(s); kind :copy packs 2"
    end
  end

  describe "AddTwinPolicy" do
    defp twin(extra_use, extra_body) do
      """
      defmodule #{name()} do
        use Ash.Resource,
          domain: AshStrangler.Test.Library.Legacy,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStrangler.Twin]#{extra_use}

        postgres do
          table "branches"
          schema "library"
          repo AshStrangler.TestRepo
          migrate? false
        end

        twin do
          system_actor AshStrangler.Test.Library.SystemActor
        end

        attributes do
          attribute :id, :integer, primary_key?: true, allow_nil?: false
        end

        actions do
          defaults [:read]
        end
        #{extra_body}
      end
      """
    end

    test "system_actor without the policy authorizer is refused" do
      assert_raise Spark.Error.DslError, ~r/needs `authorizers: \[Ash.Policy.Authorizer\]`/, fn ->
        with_io(:stderr, fn -> Code.compile_string(twin("", "")) end)
      end
    end

    test "a bypass beside system_actor is refused" do
      bypass = """
      policies do
        bypass always() do
          authorize_if always()
        end
      end
      """

      assert_raise Spark.Error.DslError, ~r/cannot declare a `bypass`/, fn ->
        with_io(:stderr, fn ->
          Code.compile_string(twin(",\n    authorizers: [Ash.Policy.Authorizer]", bypass))
        end)
      end
    end
  end
end
