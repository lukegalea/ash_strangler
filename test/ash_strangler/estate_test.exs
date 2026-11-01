# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.EstateTest do
  @moduledoc """
  The estate: computed and declared dispositions over a catalog, every check
  with a failing probe, the manifest, the `:ash_strangler_estate` compiler and
  `mix ash_strangler.estate`.

  Verifier failures are printed by the parallel checker rather than raised
  (see `AshStrangler.VerifiersTest`), so the negative compile fixtures compile
  a probe and call `VerifyEstate` over its `spark_dsl_config/0`.
  """

  # Serial: compiling probes swaps the global :standard_error device, and the
  # compiler tests set application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Estate
  alias AshStrangler.Snapshot.Catalog
  alias AshStrangler.Test.Lending
  alias AshStrangler.Verifiers.VerifyEstate

  @catalog "test/fixtures/snapshot/lending/catalog.json"

  @resources "[AshStrangler.Test.Lending.Book, AshStrangler.Test.Lending.Member, AshStrangler.Test.Lending.Loan]"
  @plugins "[AshStrangler.Test.Lending.EstateRules]"

  @clean [
    ~S|carried "lending.books.shelf_note", because: "free text"|,
    ~S|dead "lending.branches.fax", because: "no fax machine"|,
    ~S|deferred "lending.fines", wave: :billing, target: "Lending.Fine", because: "later"|,
    ~S|legacy_only "lending.sessions", because: "old sessions"|,
    ~S|dead "lending.fax_log", because: "unused"|,
    ~S|residue "lending.old_reservations", because: "old restores"|,
    ~S|open_reference "lending.loans.loans_member_id_fkey", because: "NOT VALID"|
  ]

  defp probe(declarations, opts \\ []) do
    module = Module.concat([__MODULE__, "Probe#{System.unique_integer([:positive])}"])

    source = """
    defmodule #{inspect(module)} do
      use AshStrangler.Estate

      estate do
        snapshot #{inspect(Keyword.get(opts, :snapshot, @catalog))}
        resources #{Keyword.get(opts, :resources, @resources)}
        plugins #{Keyword.get(opts, :plugins, @plugins)}
        #{Enum.join(declarations, "\n    ")}
      end
    end
    """

    # Spark records declaration lines only with debug info, which `mix test`
    # turns off, so a probe that needs them is compiled from a file with it on.
    compile =
      case opts[:file] do
        nil ->
          fn -> Code.compile_string(source) end

        file ->
          fn ->
            File.write!(file, source)
            debug_info = Code.get_compiler_option(:debug_info)
            Code.put_compiler_option(:debug_info, true)

            try do
              Code.compile_file(file)
            after
              Code.put_compiler_option(:debug_info, debug_info)
            end
          end
      end

    {result, _output} =
      with_io(:stderr, fn -> compile.() |> Enum.map(&elem(&1, 0)) |> List.last() end)

    result
  end

  defp problems(estate), do: Estate.evaluate(estate).problems
  defp subjects(problems, check), do: for(%{check: ^check, subject: s} <- problems, do: s)

  defp rejection(module) do
    case VerifyEstate.verify(module.spark_dsl_config()) do
      {:error, error} -> Exception.message(error)
      other -> flunk("VerifyEstate accepted #{inspect(module)}: #{inspect(other)}")
    end
  end

  describe "the clean fixture" do
    test "accounts for every relation and column, with nothing to report" do
      assert VerifyEstate.verify(Lending.Estate.spark_dsl_config()) == :ok
      report = Estate.evaluate(Lending.Estate)
      assert report.problems == []

      books = report.relations["lending.books"].columns
      assert Enum.map(books["title"].claims, & &1.by) == [Lending.Book, Lending.Loan]
      assert books["title"].writers == [Lending.Book]
      assert books["shelf_note"].declared.kind == :carried

      # The key, a mapped column and a join's own column are all `mapped`.
      loans = report.relations["lending.loans"].columns
      assert Enum.map(loans["book_id"].claims, & &1.kind) == [:mapped]

      assert [%{kind: :secret, by: Lending.Legacy.Members}] =
               report.relations["lending.members"].columns["pin_hash"].claims

      assert [%{kind: :projected}] = report.relations["lending.branches"].columns["id"].claims
      assert report.relations["lending.fines"].declared.wave == :billing
    end

    test "the catalog is an external resource of the estate" do
      assert @catalog in List.flatten(
               Keyword.get_values(Lending.Estate.__info__(:attributes), :external_resource)
             )
    end

    test "drift_allow/1 turns residue into drift allow patterns" do
      assert Estate.drift_allow(Lending.Estate) == ["relation lending.old_reservations"]
    end
  end

  describe "manifest/1" do
    test "exports every relation and column, canonically" do
      manifest = Lending.Estate |> Estate.evaluate() |> Estate.manifest()

      assert manifest["format"] == "ash_strangler.estate/1"
      assert manifest["estate"] == "AshStrangler.Test.Lending.Estate"

      assert manifest["catalog"]["sha256"] ==
               :sha256 |> :crypto.hash(File.read!(@catalog)) |> Base.encode16(case: :lower)

      assert manifest["relations"]["lending.fines"] == %{
               "kind" => "table",
               "disposition" => "deferred",
               "wave" => "billing",
               "target" => "Lending.Fine",
               "because" => "billing moves later"
             }

      books = manifest["relations"]["lending.books"]
      assert books["disposition"] == "columns"
      assert books["columns"]["shelf_note"]["disposition"] == "carried"

      assert books["columns"]["title"] == %{
               "disposition" => "mapped",
               "claims" => %{
                 "mapped" => ["AshStrangler.Test.Lending.Book", "AshStrangler.Test.Lending.Loan"]
               },
               "written_by" => ["AshStrangler.Test.Lending.Book"]
             }

      assert manifest["drift_allow"] == ["relation lending.old_reservations"]

      assert manifest["counts"]["relations"] == %{
               "columns" => 4,
               "dead" => 1,
               "deferred" => 1,
               "legacy_only" => 1
             }

      assert manifest["counts"]["columns"]["secret"] == 1
      assert manifest["problems"] == []

      encoded = Catalog.encode(manifest)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded["relations"]["lending.books"]["columns"]["title"]["claims"]["mapped"]
             |> length() == 2
    end
  end

  describe "VerifyEstate (negative compile fixtures)" do
    test "a disposition for a nonexistent relation or column" do
      message = rejection(probe(@clean ++ [~S|dead "lending.books.nope", because: "x"|]))
      assert message =~ ~s|the catalog has no relation or column "lending.books.nope"|

      message = rejection(probe(@clean ++ [~S|legacy_only "lending.nowhere", because: "x"|]))
      assert message =~ ~s|"lending.nowhere"|
    end

    test "carried on a relation" do
      message = rejection(probe(@clean ++ [~S|carried "lending.fax_log", because: "x"|]))
      assert message =~ "`carried` applies to a column"
    end

    test "one column declared twice" do
      message = rejection(probe(@clean ++ [~S|dead "lending.books.shelf_note", because: "x"|]))
      assert message =~ ~s|"lending.books.shelf_note" is declared 2 times (carried, dead)|
    end

    test "a column declared inside a relation declared as a whole" do
      message =
        rejection(probe(@clean ++ [~S|carried "lending.fines.amount_cents", because: "x"|]))

      assert message =~ ~s|"lending.fines" is declared deferred as a whole|
    end

    test "a residue relation the catalog has, and a residue declared twice" do
      message = rejection(probe(@clean ++ [~S|residue "lending.fines", because: "x"|]))
      assert message =~ ~s|residue "lending.fines" is in the catalog|

      message = rejection(probe(@clean ++ [~S|residue "lending.old_reservations", because: "x"|]))
      assert message =~ ~s|residue "lending.old_reservations" is declared 2 times|
    end

    test "an open_reference to a foreign key the catalog does not have" do
      message =
        rejection(
          probe(@clean ++ [~S|open_reference "lending.loans.no_such_fkey", because: "x"|])
        )

      assert message =~ ~s|the catalog has no foreign key "lending.loans.no_such_fkey"|
    end

    test "an unreadable catalog" do
      message = rejection(probe(@clean, snapshot: "test/fixtures/snapshot/nowhere/catalog.json"))
      assert message =~ "the estate's snapshot catalog cannot be read"
    end
  end

  describe "coverage" do
    test "deleting a declared disposition names the column" do
      estate = probe(List.delete_at(@clean, 0))
      assert subjects(problems(estate), :coverage) == ["lending.books.shelf_note"]
    end

    @tag :tmp_dir
    test "a column or relation added to the catalog without a disposition", %{tmp_dir: dir} do
      {:ok, catalog} = AshStrangler.Snapshot.read_catalog(@catalog)
      column = hd(catalog["relations"]["lending.books"]["columns"])

      catalog =
        catalog
        |> update_in(
          ["relations", "lending.books", "columns"],
          &(&1 ++ [%{column | "name" => "subtitle"}])
        )
        |> put_in(["relations", "lending.holds"], catalog["relations"]["lending.fax_log"])

      path = Path.join(dir, "catalog.json")
      File.write!(path, Catalog.encode(catalog))

      problems = problems(probe(@clean, snapshot: path))
      assert subjects(problems, :coverage) == ["lending.books.subtitle", "lending.holds"]

      assert Enum.find(problems, &(&1.subject == "lending.holds")).message =~
               "has no disposition (2 columns)"
    end

    test "a declaration on a mapped column conflicts with the mapping" do
      [problem] = problems(probe(@clean ++ [~S|dead "lending.books.isbn", because: "x"|]))
      assert problem.check == :coverage

      assert problem.message =~
               "is declared dead, but it is also mapped by AshStrangler.Test.Lending.Book"
    end

    test "a relation the strangle reads cannot be declared as a whole" do
      problems = problems(probe(@clean ++ [~S|dead "lending.members", because: "x"|]))

      assert subjects(problems, :consistency) ==
               ~w(lending.members.branch_id lending.members.email lending.members.full_name
                  lending.members.id lending.members.pin_hash)
    end
  end

  describe "references" do
    test "a mapped foreign key into an unclaimed relation is not closed" do
      problems = problems(probe(@clean, plugins: "[]"))

      assert subjects(problems, :references) ==
               ~w(lending.books.books_branch_id_fkey lending.members.members_branch_id_fkey)

      assert Enum.find(problems, &(&1.check == :references)).message =~ "nothing maps or claims"
      assert "lending.branches.id" in subjects(problems, :coverage)
    end

    test "a NOT VALID key needs an open_reference" do
      [problem] = problems(probe(List.delete_at(@clean, 6)))
      assert problem.subject == "lending.loans.loans_member_id_fkey"
      assert problem.message =~ "NOT VALID"
    end

    test "an open_reference that is not needed is stale" do
      extra = ~S|open_reference "lending.loans.loans_book_id_fkey", because: "x"|
      [problem] = problems(probe(@clean ++ [extra]))
      assert problem.check == :references
      assert problem.message =~ "is not needed"

      extra = ~S|open_reference "lending.fines.fines_loan_id_fkey", because: "x"|
      [problem] = problems(probe(@clean ++ [extra]))
      assert problem.message =~ "is not mapped"
    end
  end

  describe "resources and writers" do
    test "two resources writing one legacy column" do
      {_, _} =
        with_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshStrangler.EstateTest.BookTitles do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "book_titles"
              schema "strangler"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :integer, primary_key?: true, allow_nil?: false, writable?: false
              attribute :title, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :read_from_legacy

              source AshStrangler.Test.Lending.Legacy.Books do
                key :id, from: :id, strategy: :identity
                map :title, from: :title
              end
            end
          end
          """)
        end)

      resources = String.replace(@resources, "]", ", AshStrangler.EstateTest.BookTitles]")
      [problem] = problems(probe(@clean, resources: resources))
      assert problem.check == :writers
      assert problem.subject == "lending.books.title"
    end

    test "a module that is neither a strangled resource nor a twin; a twin contributes secrets" do
      resources = String.replace(@resources, "]", ", String]")
      [problem] = problems(probe(@clean, resources: resources))
      assert problem.check == :resources
      assert problem.message =~ "String is neither a strangled resource nor a twin"

      # Listed directly, a twin claims its secrets and nothing else, once.
      resources =
        "[AshStrangler.Test.Lending.Legacy.Members, AshStrangler.Test.Lending.Legacy.Members]"

      report = Estate.evaluate(probe(@clean, resources: resources, plugins: "[]"))

      assert [%{kind: :secret}] = report.relations["lending.members"].columns["pin_hash"].claims
      assert report.relations["lending.members"].columns["email"].claims == []
    end
  end

  describe "plug-ins" do
    test "claims of a reserved kind or a missing column are refused" do
      {_, _} =
        with_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshStrangler.EstateTest.BadClaims do
            @behaviour AshStrangler.Estate.Plugin
            alias AshStrangler.Estate.Claim

            def claims(_estate, _catalog) do
              [
                %Claim{relation: "lending.branches", column: "id", kind: :mapped, by: "X"},
                %Claim{relation: "lending.branches", column: "nope", kind: :projected, by: "X"},
                {:not, :a, :claim}
              ]
            end
          end
          """)
        end)

      plugins = "[AshStrangler.Test.Lending.EstateRules, AshStrangler.EstateTest.BadClaims]"
      problems = problems(probe(@clean, plugins: plugins))
      claims = for %{check: :claims, message: m} <- problems, do: m

      assert Enum.any?(claims, &(&1 =~ "as :mapped, a kind the estate reserves"))
      assert Enum.any?(claims, &(&1 =~ "lending.branches.nope, which the catalog does not have"))
      assert Enum.any?(claims, &(&1 =~ "not an %AshStrangler.Estate.Claim{}"))
    end

    test "a plug-in check's problems are the estate's problems" do
      declarations =
        List.replace_at(
          @clean,
          2,
          ~S|deferred "lending.fines", wave: :billing, target: "Fine", because: "later"|
        )

      [problem] = problems(probe(declarations))
      assert problem.check == :plugin
      assert problem.subject == "AshStrangler.Test.Lending.EstateRules"
      assert problem.message =~ ~s|deferred target "Fine"|
    end
  end

  describe "the :ash_strangler_estate compiler" do
    setup do
      previous = Application.get_env(:ash_strangler, :ash_strangler_estates)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_strangler, :ash_strangler_estates, previous),
          else: Application.delete_env(:ash_strangler, :ash_strangler_estates)
      end)
    end

    test "is a no-op with no estate configured, and passes a clean one" do
      Application.delete_env(:ash_strangler, :ash_strangler_estates)
      assert Mix.Tasks.Compile.AshStranglerEstate.run([]) == {:noop, []}

      Application.put_env(:ash_strangler, :ash_strangler_estates, [Lending.Estate])
      assert Mix.Tasks.Compile.AshStranglerEstate.run([]) == {:ok, []}
    end

    @tag :tmp_dir
    test "fails compilation, pointing at the declaration", %{tmp_dir: dir} do
      file = Path.join(dir, "estate.ex")
      estate = probe(@clean ++ [~S|dead "lending.books.isbn", because: "x"|], file: file)
      Application.put_env(:ash_strangler, :ash_strangler_estates, [estate, AshStrangler.Nowhere])

      {result, output} =
        with_io(:stderr, fn -> Mix.Tasks.Compile.AshStranglerEstate.run([]) end)

      assert {:error, [conflict, missing]} = result
      assert conflict.severity == :error
      assert conflict.compiler_name == "ash_strangler_estate"
      assert conflict.message =~ "coverage: lending.books.isbn is declared dead"
      # The probe's declaration is the last line of its estate block.
      assert conflict.file == Path.relative_to_cwd(file)
      assert conflict.position == 15
      assert missing.message =~ "AshStrangler.Nowhere is configured as an estate"
      assert output =~ "lending.books.isbn"
    end
  end

  describe "mix ash_strangler.estate" do
    @tag :tmp_dir
    test "writes the manifest and reports a clean estate", %{tmp_dir: dir} do
      path = Path.join(dir, "estate-manifest.json")

      output =
        capture_io(fn ->
          Mix.Task.rerun("ash_strangler.estate", [inspect(Lending.Estate), "--manifest", path])
        end)

      assert output =~ "every relation and column accounted for"
      assert {:ok, %{"format" => "ash_strangler.estate/1"}} = Jason.decode(File.read!(path))
    end

    test "exits 1 on problems" do
      estate = probe(List.delete_at(@clean, 0))

      {result, output} =
        with_io(:stderr, fn ->
          catch_exit(Mix.Task.rerun("ash_strangler.estate", [inspect(estate)]))
        end)

      assert result == {:shutdown, 1}
      assert output =~ "lending.books.shelf_note has no disposition"
    end
  end
end
