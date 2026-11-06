# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.DerivedVerifierTest do
  @moduledoc """
  Negative compile fixtures for `VerifyDerived`. Verifier failures are printed
  by the parallel checker rather than raised, so each case compiles a probe and
  calls the verifier over its `spark_dsl_config/0`.
  """

  # Serial: compiling probes swaps the global :standard_error device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Verifiers.VerifyDerived

  @twin "AshStrangler.Test.ClinicDerived.Legacy.Visits"
  @keys "AshStrangler.Test.ClinicDerived.Keys"

  @columns "column :visit, :integer\ncolumn :person, :string\n"

  @slot """
  slot :lead do
    filter expr(not is_nil(lead_nurse))
    map :visit, from: :id
    map :person, from: :lead_nurse
  end
  """

  @element """
  element :guest do
    from :details
    type :text
    value :person
    map :visit, from: :id
  end
  """

  defp probe(body, header \\ "") do
    name = "AshStrangler.DerivedVerifierTest.Probe#{System.unique_integer([:positive])}"

    {module, io} =
      with_io(:stderr, fn ->
        try do
          """
          defmodule #{name} do
            use AshStrangler.Derived

            derived do
              schema "clinic_derived"
              view "probe"
              #{if String.contains?(header, "twin "), do: "", else: "twin #{@twin}"}
              #{if String.contains?(header, "registry "), do: "", else: "registry #{@keys}"}
              #{if String.contains?(header, "kind "), do: "", else: "kind :staff"}
              #{if String.contains?(header, "from ["), do: "", else: "from [:id]"}
              #{header}
              #{body}
            end
          end
          """
          |> Code.compile_string()
          |> Enum.map(&elem(&1, 0))
          |> List.last()
        rescue
          error in CompileError -> {:compile_error, Exception.message(error)}
        end
      end)

    if match?({:compile_error, _}, module), do: flunk("probe did not compile: #{io}")
    module
  end

  defp rejection(body, header \\ "") do
    case VerifyDerived.verify(probe(body, header).spark_dsl_config()) do
      {:error, error} -> Exception.message(error)
      other -> flunk("accepted: #{inspect(other)}")
    end
  end

  test "the base fixture is accepted" do
    assert :ok = VerifyDerived.verify(probe(@columns <> @slot <> @element).spark_dsl_config())
  end

  test "no source" do
    assert rejection(@columns) =~ "at least one `slot`"
  end

  test "a registry without the logical kind" do
    assert rejection(@columns <> @slot, "kind :nope") =~ "declares no `logical` kind :nope"
    assert rejection(@columns <> @slot, "kind :clinic") =~ "declares no `logical` kind :clinic"
  end

  test "a registry that is not a registry" do
    assert rejection(@columns <> @slot, "registry String") =~ "is not an `AshStrangler.KeyKinds` registry"
  end

  test "a from column the twin does not have" do
    assert rejection(@columns <> @slot, "from [:nope]") =~ "`from` reads :nope"
  end

  test "a source that leaves a column unanswered" do
    body = @columns <> "slot :lead do\n map :visit, from: :id\nend"
    assert rejection(body) =~ "slot :lead: column :person is not answered"
  end

  test "a source that reads a column the twin does not have" do
    body = @columns <> "slot :lead do\n map :visit, from: :id\n map :person, from: :nope\nend"
    assert rejection(body) =~ "reads :nope"
  end

  test "a filter over a column the twin does not have" do
    body = @columns <> "slot :lead do\n filter expr(nope > 1)\n map :visit, from: :id\n map :person, from: :lead_nurse\nend"
    assert rejection(body) =~ "`filter` reads :nope"
  end

  test "an element's value column must be declared and unmapped" do
    mapped = @columns <> String.replace(@element, "map :visit, from: :id", "map :visit, from: :id\nmap :person, from: :lead_nurse")
    assert rejection(mapped) =~ ":person is the element's own column"

    undeclared = @columns <> String.replace(@element, "value :person", "value :nobody")
    assert rejection(undeclared) =~ "`value` :nobody is not a declared column"
  end

  test "an element's ordinal cannot be its value" do
    body = @columns <> String.replace(@element, "value :person", "value :person\nordinal :person")
    assert rejection(body) =~ "`value` and `ordinal` name one column"
  end

  test "an element reads a jsonb column the twin has" do
    body = @columns <> String.replace(@element, "from :details", "from :nope")
    assert rejection(body) =~ "`from` reads :nope"
  end

  test "duplicate columns and sources, and reserved names" do
    assert rejection(@columns <> "column :person, :string\n" <> @slot) =~ "column :person is declared 2 times"
    assert rejection(@columns <> @slot <> @slot) =~ "source :lead is declared 2 times"
    assert rejection("column :__source, :string\n" <> @slot) =~ "`__source` is reserved"
  end

  test "an unanswered tenant_of kind is not this verifier's: E5 reads it" do
    body = @columns <> "column :clinic, :uuid\n" <> String.replace(@slot, "map :visit", "tenant_of :clinic, kind: {#{@keys}, :clinic}, from: :id\nmap :visit")
    assert :ok = VerifyDerived.verify(probe(body).spark_dsl_config())
  end
end
