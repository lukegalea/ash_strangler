# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.EvalTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.EvalTest.Source
    resource AshStrangler.EvalTest.Facade
  end
end

defmodule AshStrangler.EvalTest.Source do
  @moduledoc false
  use Ash.Resource, domain: AshStrangler.EvalTest.Domain

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :first, :string, public?: true
    attribute :last, :string, public?: true
    attribute :nickname, :string, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:open, :done, :cancelled]]

    attribute :flag, :boolean, allow_nil?: false, public?: true
    attribute :minutes, :integer, public?: true
    attribute :moved_on, :naive_datetime, public?: true
    attribute :email, :string, public?: true
  end
end

defmodule AshStrangler.EvalTest.Facade do
  @moduledoc false
  use Ash.Resource, domain: AshStrangler.EvalTest.Domain

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :full_name, :string, public?: true
    attribute :nick, :string, public?: true

    attribute :state, :atom,
      public?: true,
      constraints: [one_of: [:new, :finished, :dropped]]

    attribute :lifecycle, :atom,
      public?: true,
      constraints: [one_of: [:open, :done, :cancelled]]

    attribute :active, :boolean, public?: true
    attribute :scaled, :integer, public?: true
    attribute :moved_at, :utc_datetime_usec, public?: true
    attribute :email, :ci_string, public?: true
    attribute :kind, :string, public?: true
  end
end

defmodule AshStrangler.EvalTest do
  @moduledoc """
  The BEAM evaluator against PostgreSQL, for every combinator of the tier 1 and
  tier 2 grammar, plus the cases a façade depends on: a forbidden source value
  is never computed with, a read-only lens refuses a put, and an expression
  outside the evaluable set is refused by name.
  """

  use AshStrangler.DataCase, async: false
  use ExUnitProperties

  import Ash.Expr

  alias AshStrangler.{Collapse, Eval, Lens}
  alias AshStrangler.Test.EvalDifferential, as: Differential
  alias AshStrangler.EvalTest.{Facade, Source}

  @decode %{open: :new, done: :finished, cancelled: :dropped}

  defp entries do
    [
      %AshStrangler.Map{attribute: :title, from: :name},
      %AshStrangler.Concat{attribute: :full_name, from: [:first, :last], separator: " "},
      %AshStrangler.Coalesce{attribute: :nick, from: :nickname, default: "none"},
      %AshStrangler.Decode{attribute: :state, from: :status, values: @decode},
      %Collapse{
        attribute: :lifecycle,
        states: [
          %Collapse.State{
            value: :cancelled,
            when: expr(status == :cancelled),
            set: [status: :cancelled, flag: false]
          },
          %Collapse.State{value: :done, when: expr(flag), set: [status: :done, flag: true]},
          %Collapse.State{value: :open, when: :otherwise, set: [status: :open, flag: false]}
        ]
      },
      %AshStrangler.Negate{attribute: :active, from: :flag},
      %AshStrangler.Affine{attribute: :scaled, from: :minutes, multiply: 3, add: 7},
      %AshStrangler.Map{attribute: :moved_at, from: :moved_on, zone: "UTC"},
      %AshStrangler.Map{attribute: :email, from: :email},
      %AshStrangler.Constant{attribute: :kind, expression: expr("fixed")}
    ]
  end

  defp lenses, do: Lens.over(Source, Facade, entries())

  describe "Lens.over/3" do
    test "builds a lens for every entry over an Ash resource that is not a twin" do
      lenses = lenses()

      assert lenses |> Map.keys() |> Enum.sort() ==
               Enum.sort(
                 ~w(title full_name nick state lifecycle active scaled moved_at email kind)a
               )

      assert lenses[:title].combinator == :rename
      assert lenses[:state].combinator == :decode
      assert lenses[:state].invertible == :yes
      assert lenses[:lifecycle].combinator == :collapse
    end

    test "derives a cast from the two Ash types, not from Postgres" do
      assert %{combinator: :cast, forward: %{name: :type, args: [_, Ash.Type.CiString]}} =
               lenses()[:email]
    end

    test "refuses an entry that reads a field the source does not have" do
      assert_raise ArgumentError, ~r/:nope.*not a field/, fn ->
        Lens.over(Source, Facade, [%AshStrangler.Map{attribute: :title, from: :nope}])
      end
    end
  end

  describe "get: BEAM equals SQL" do
    property "every evaluable lens" do
      lenses = lenses() |> Enum.filter(fn {_, lens} -> Eval.evaluable?(lens) end)
      assert length(lenses) == 10

      check all(row <- Differential.row(Source), max_runs: 60) do
        for {attribute, lens} <- lenses, lens.forward != nil do
          expected = Differential.sql(lens.forward, row, Source)

          assert Differential.same?(Eval.forward(lens, row), expected),
                 "#{attribute}: #{inspect(Eval.forward(lens, row))} != #{inspect(expected)} for #{inspect(row)}"
        end
      end
    end
  end

  describe "put: BEAM equals SQL" do
    property "every invertible lens" do
      lenses =
        lenses() |> Enum.filter(fn {_, lens} -> lens.writes != [] and Eval.evaluable?(lens) end)

      assert length(lenses) == 9

      check all(attributes <- Differential.row(Facade), max_runs: 60) do
        for {attribute, lens} <- lenses do
          {:ok, written} = Eval.put(lens, attributes)

          for {{column, expression}, {column, value}} <- Enum.zip(lens.writes, written) do
            expected = Differential.sql(expression, attributes, Facade)

            assert Differential.same?(value, expected),
                   "#{attribute}.#{column}: #{inspect(value)} != #{inspect(expected)} for #{inspect(attributes)}"
          end
        end
      end
    end
  end

  describe "against twin-backed lenses" do
    property "the fixtures' own lenses agree with SQL" do
      for resource <- [AshStrangler.Test.LegacyUser, AshStrangler.Test.DualWriteUser] do
        twin = AshStrangler.Info.twin(resource)

        lenses =
          resource
          |> Lens.by_attribute()
          |> Enum.filter(fn {_, lens} -> lens.forward != nil and Eval.evaluable?(lens) end)

        assert lenses != []

        check all(row <- Differential.row(twin), max_runs: 30) do
          for {attribute, lens} <- lenses, not match?(%{combinator: :key}, lens) do
            expected = Differential.sql(lens.forward, row, twin)

            assert Differential.same?(Eval.forward(lens, row), expected),
                   "#{inspect(resource)}.#{attribute}: #{inspect(Eval.forward(lens, row))} != #{inspect(expected)}"
          end
        end
      end
    end
  end

  describe "the evaluator's boundary" do
    test "a source value the viewer may not read is never computed with" do
      forbidden = %Ash.ForbiddenField{field: :name, type: :attribute, original_value: "secret"}
      lens = lenses()[:title]

      assert %Ash.ForbiddenField{field: :title, original_value: nil} =
               Eval.forward(lens, %{name: forbidden})

      # A lens over several columns is forbidden when any one of them is.
      assert %Ash.ForbiddenField{field: :full_name} =
               Eval.forward(lenses()[:full_name], %{first: "Ada", last: forbidden})
    end

    test "a lens with no reverse refuses a put and says why" do
      lens =
        Lens.over(Source, Facade, [
          %AshStrangler.Map{
            attribute: :title,
            from: expr(first <> " " <> last),
            read_only?: true,
            because: "not decomposable"
          }
        ])[:title]

      assert Eval.put(lens, %{title: "Ada Lovelace"}) ==
               {:error, {:read_only, "not decomposable"}}

      assert Eval.forward(lens, %{first: "Ada", last: "Lovelace"}) == "Ada Lovelace"
    end

    test "a fragment is outside the evaluable set, and says so by name" do
      lens =
        Lens.over(Source, Facade, [
          %AshStrangler.Map{
            attribute: :title,
            from: expr(fragment("upper(?)", name)),
            read_only?: true,
            because: "opaque"
          }
        ])[:title]

      refute Eval.evaluable?(lens)

      assert_raise Eval.Unsupported, ~r/fragment\("upper\(\?\)"\)/, fn ->
        Eval.forward(lens, %{name: "x"})
      end
    end

    test "three-valued logic: a NULL guard takes the ELSE, and NULL == NULL is not true" do
      lens = lenses()[:lifecycle]
      assert Eval.forward(lens, %{status: :open, flag: false}) == :open
      assert Eval.forward(lens, %{status: :cancelled, flag: true}) == :cancelled
      assert Eval.forward(lens, %{status: :open, flag: nil}) == :open

      assert Eval.forward(lenses()[:title], %{name: nil}) == nil
    end

    test "a collapse's write holds the stored column on an update and falls back on an insert" do
      hold =
        Lens.over(Source, Facade, [
          %Collapse{
            attribute: :lifecycle,
            states: [
              %Collapse.State{
                value: :open,
                when: :otherwise,
                set: [status: :open, flag: false]
              }
            ]
          }
        ])[:lifecycle]

      assert {:ok, written} = Eval.put(hold, %{lifecycle: :open})
      assert Enum.sort(written) == [flag: false, status: :open]
    end
  end

  describe "filter and sort through the forward lens" do
    defp facade_filter(expression), do: Ash.Filter.parse!(Facade, expression)

    defp source_rows do
      for {{status, first, last, minutes}, n} <- Enum.with_index([
            {:open, "Ada", "Lovelace", 0},
            {:done, "Alan", "Turing", 1},
            {:cancelled, "Grace", nil, 5},
            {:done, nil, "Hopper", nil}
          ]) do
        struct!(Source, id: "00000000-0000-0000-0000-00000000000#{n}", status: status, first: first, last: last, minutes: minutes, flag: status == :done)
      end
    end

    defp matching(filter) do
      {:ok, rows} = Ash.Filter.Runtime.filter_matches(AshStrangler.EvalTest.Domain, source_rows(), filter)
      rows
    end

    defp translated!(lenses, expression) do
      {:ok, filter} = AshStrangler.Translate.filter(lenses, facade_filter(expression), Source)
      matching(filter)
    end

    test "an invertible comparison is rewritten onto the source column" do
      {:ok, filter} = AshStrangler.Translate.filter(lenses(), facade_filter(expr(state == :finished)), Source)
      assert %Ash.Query.Operator.Eq{left: %Ash.Query.Ref{attribute: %{name: :status}}, right: :done} = filter
    end

    test "a filter selects the rows the façade would show, for every kind of lens" do
      lenses = lenses()

      for {expression, front} <- [
            {expr(state == :finished), & &1.state == :finished},
            {expr(state in [:new, :dropped]), &(&1.state in [:new, :dropped])},
            {expr(full_name == "Ada Lovelace"), & &1.full_name == "Ada Lovelace"},
            {expr(scaled > 7), &(is_integer(&1.scaled) and &1.scaled > 7)},
            {expr(active and scaled > 7), &(&1.active == true and is_integer(&1.scaled) and &1.scaled > 7)},
            {expr(not (state == :finished)), &(&1.state != :finished)}
          ] do
        expected =
          source_rows()
          |> Enum.filter(fn row ->
            front.(Map.new(lenses, fn {name, lens} -> {name, Eval.forward(lens, row, [])} end))
          end)
          |> Enum.map(& &1.id)

        assert translated!(lenses, expression) |> Enum.map(& &1.id) == expected,
               "#{inspect(expression)} selects other rows through the lens than the façade shows"
      end
    end

    test "a reference the lens has no forward for is refused, never dropped" do
      assert {:error, {:untranslatable, {"it has no forward lens", :title}}} =
               AshStrangler.Translate.filter(Map.delete(lenses(), :title), facade_filter(expr(title == "x")), Source)
    end

    test "a sort by a rename names the source column, any other lens sorts by its expression" do
      assert {:ok, [{:name, :asc}, {expression, :desc}]} =
               AshStrangler.Translate.sort(lenses(), title: :asc, state: :desc)

      refute is_atom(expression)
    end
  end
end
