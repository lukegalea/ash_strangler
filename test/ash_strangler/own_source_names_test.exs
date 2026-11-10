# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.OwnSourceNamesTest do
  @moduledoc """
  A `source:` on a strangled resource's own attribute is refused at compile time.

  The view names every column after its attribute and Ash reads the view by
  `source:`, so the first query would fail at runtime. The premise is measured in
  `own_source_names_runtime_test.exs`: a resource whose attribute carries a `source:`,
  over a generated view, fails its first read with `column ... does not exist`. The
  cases below pin every kind of column
  the view emits, and the phases where `source:` stays legitimate.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Verifiers.VerifyOwnSourceNames

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  defp define(attributes, mapping, phase \\ ":read_from_legacy") do
    {module, _io} = compile(attributes, mapping, phase)
    module.spark_dsl_config()
  end

  defp compile(attributes, mapping, phase) do
    name = "AshStrangler.OwnSourceNamesTest.Probe#{System.unique_integer([:positive])}"

    {result, io} =
      with_io(:stderr, fn ->
        Code.eval_string(
          """
          defmodule #{name} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "own_source_probe_v"
              schema "verified"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              #{attributes}
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase #{phase}

              source AshStrangler.Test.Legacy.Users do
                #{mapping}
              end
            end
          end
          """,
          [],
          file: "probe_own_source.ex"
        )
      end)

    {{:module, module, _, _}, _binding} = result
    {module, io}
  end

  defp key_line, do: ~s|key :id, from: :id, strategy: {:uuid_v5, namespace: "#{@namespace}"}|

  defp refused(attributes, mapping, phase \\ ":read_from_legacy") do
    assert {:error, error} = VerifyOwnSourceNames.verify(define(attributes, mapping, phase))
    Exception.message(error)
  end

  describe "refused, for every kind of column the view emits" do
    test "the key" do
      message =
        refused(
          "attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, source: :ident",
          key_line()
        )

      assert message =~ ":id"
      assert message =~ "source: :ident"
    end

    test "a mapped attribute" do
      message =
        refused(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login_name
          """,
          "#{key_line()}\nmap :login, from: :login"
        )

      assert message =~ ":login"
      assert message =~ "source: :login_name"
    end

    test "an unmapped attribute" do
      message =
        refused(
          """
          uuid_primary_key :id
          attribute :note, :string, public?: true, source: :note_col
          """,
          "#{key_line()}\nunmapped [:note], as: :null, because: \"fixture\""
        )

      assert message =~ ":note"
    end

    test "an extension attribute" do
      message =
        refused(
          """
          uuid_primary_key :id
          attribute :memo, :string, public?: true, source: :memo_col
          """,
          "#{key_line()}\nextension [:memo]"
        )

      assert message =~ ":memo"
    end

    test "the tenant attribute" do
      message =
        refused(
          """
          uuid_primary_key :id
          attribute :organization_id, :string, public?: true, source: :org
          """,
          "#{key_line()}\nmap :organization_id, from: :salt\ntenant :organization_id, derive: expr(salt)"
        )

      assert message =~ ":organization_id"
    end

    test "every offender is named, with what to do instead" do
      message =
        refused(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login_name
          attribute :email, :string, public?: true, source: :mail
          """,
          "#{key_line()}\nmap :login, from: :login\nmap :email, from: :email"
        )

      assert message =~ ":login"
      assert message =~ "source: :login_name"
      assert message =~ ":email"
      assert message =~ "source: :mail"
      assert message =~ "rename the attribute"
      assert message =~ "twin attribute, which does support"
    end

    test "dual_write refuses it as well" do
      message =
        refused(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login_name
          """,
          "#{key_line()}\nmap :login, from: :login",
          ":dual_write"
        )

      assert message =~ ":dual_write"
    end
  end

  describe "wired into the extension" do
    # The cases above call the verifier directly. This one compiles a resource and
    # reads what the compiler said, so it fails if the verifier is not registered
    # on `AshStrangler.Resource`.
    test "compiling a resource that carries a source: reports it" do
      {_module, io} =
        compile(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login_name
          """,
          "#{key_line()}\nmap :login, from: :login",
          ":read_from_legacy"
        )

      assert io =~ "cannot honour"
      assert io =~ "login_name"
    end

    test "compiling one whose source: is its own name says nothing" do
      {_module, io} =
        compile(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login
          """,
          "#{key_line()}\nmap :login, from: :login",
          ":read_from_legacy"
        )

      refute io =~ "cannot honour"
    end
  end

  describe "accepted" do
    test "an attribute whose source is its own name is not a rename" do
      probe =
        define(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login
          """,
          "#{key_line()}\nmap :login, from: :login"
        )

      assert :ok = VerifyOwnSourceNames.verify(probe)
    end

    test "from :read_from_new the resource owns its table, and source: names its columns" do
      probe =
        define(
          """
          uuid_primary_key :id
          attribute :login, :string, public?: true, source: :login_name
          """,
          "#{key_line()}\nmap :login, from: :login",
          ":read_from_new"
        )

      assert :ok = VerifyOwnSourceNames.verify(probe)
    end

    test "a resource without a strangler block is left alone" do
      assert :ok = VerifyOwnSourceNames.verify(AshStrangler.Test.Legacy.Users.spark_dsl_config())
    end
  end
end
