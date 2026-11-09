# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.CheckCatalogTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckCatalogTest.Orders
    resource AshStrangler.CheckCatalogTest.Order
    resource AshStrangler.CheckCatalogTest.OrdersHand
    resource AshStrangler.CheckCatalogTest.OrderHand
  end
end

defmodule AshStrangler.CheckCatalogTest.ShakyDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckCatalogTest.Shaky
    resource AshStrangler.CheckCatalogTest.ShakyView
  end
end

defmodule AshStrangler.CheckCatalogTest.Orders do
  @moduledoc """
  A twin as `mix ash_strangler.gen.twin` writes one for `legacy.catalog_orders`:
  every column, the value sets as `one_of`.
  """
  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "catalog_orders"
    schema "legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:open, :paid]
    end

    attribute :kind, :atom do
      public? true
      constraints one_of: [:retail, :wholesale]
    end

    attribute :channel, :atom do
      public? true
      constraints one_of: [:web, :store]
    end

    attribute :amount, :decimal, public?: true
    attribute :note, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CheckCatalogTest.Order do
  @moduledoc "Reads `state` and `kind` of `Orders` straight across."

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a81"

  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "catalog_order_view"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false

    attribute :state, :atom do
      public? true
      constraints one_of: [:open, :paid]
    end

    attribute :kind, :atom do
      public? true
      constraints one_of: [:retail, :wholesale]
    end

    attribute :amount, :decimal, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.CheckCatalogTest.Orders do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :state, from: :state, read_only?: true, because: "fixture"
      map :kind, from: :kind, read_only?: true, because: "fixture"
      map :amount, from: :amount, read_only?: true, because: "fixture"
    end
  end
end

defmodule AshStrangler.CheckCatalogTest.OrdersHand do
  @moduledoc """
  A twin written by hand over the same table: it renames two columns with
  `source:`, declares only some of the others, and leaves `amount` and `note` out.
  """
  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "catalog_orders"
    schema "legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :order_id, :integer,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      source: :id

    attribute :status, :atom do
      allow_nil? false
      public? true
      source :state
      constraints one_of: [:open, :paid]
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CheckCatalogTest.OrderHand do
  @moduledoc "Reads the renamed `status` of the hand-written twin."

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a82"

  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "catalog_order_hand_view"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false

    attribute :stage, :atom do
      public? true
      constraints one_of: [:open, :paid]
    end
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.CheckCatalogTest.OrdersHand do
      key :id, from: :order_id, strategy: {:uuid_v5, namespace: @namespace}

      map :stage, from: :status, read_only?: true, because: "fixture"
    end
  end
end

defmodule AshStrangler.CheckCatalogTest.Shaky do
  @moduledoc """
  A twin over `legacy.catalog_shaky` whose declared types have drifted from the
  columns, to give the projection something to disagree with.
  """
  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.ShakyDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "catalog_shaky"
    schema "legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :qty, :string, public?: true
    attribute :addr, :string, public?: true
    attribute :handle, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CheckCatalogTest.ShakyView do
  @moduledoc """
  Every projection here yields a type the attribute does not store, or one the
  type table does not know.
  """

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a83"

  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.ShakyDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "catalog_shaky_view"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :qty, :string, public?: true
    attribute :addr, :string, public?: true
    attribute :handle, :string, public?: true
    attribute :as_text, :string, public?: true
    attribute :as_citext, :string, public?: true
    attribute :cast_later, :integer, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.CheckCatalogTest.Shaky do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :qty, from: :qty, read_only?: true, because: "fixture"
      map :addr, from: :addr, read_only?: true, because: "fixture"
      map :handle, from: :handle, read_only?: true, because: "fixture"

      map :as_text,
        from: expr(fragment("?::text", id)),
        read_only?: true,
        because: "fixture"

      map :as_citext,
        from: expr(fragment("?::citext", note)),
        read_only?: true,
        because: "fixture"

      map :cast_later,
        from: expr(fragment("(?)::int", note)),
        read_only?: true,
        because: "fixture"
    end
  end
end

defmodule AshStrangler.CheckCatalogTest.EdgeDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CheckCatalogTest.Edge
    resource AshStrangler.CheckCatalogTest.EdgeView
  end
end

defmodule AshStrangler.CheckCatalogTest.EnumStoredAsPgEnum do
  @moduledoc "An Ash enum whose storage type is the Postgres enum's own name."
  use Ash.Type.Enum, values: [:new, :done]

  @impl true
  def storage_type, do: :catalog_edge_state
end

defmodule AshStrangler.CheckCatalogTest.Edge do
  @moduledoc """
  A twin over `legacy.catalog_edge`, whose columns are the ones a live catalog
  read can get wrong: a `CHECK` over `citext` (which `pg_get_constraintdef` prints
  differently under a different `search_path`), an enum in another schema, a
  column whose name no attribute can take, and a storage type the generator's
  table does not have.
  """
  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.EdgeDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "catalog_edge"
    schema "legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :ci_string, allow_nil?: false, public?: true

    attribute :stage, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:new, :done]
    end

    attribute :odd, :atom do
      allow_nil? false
      public? true
      source :"Odd-Name"
      constraints one_of: [:x, :y]
    end

    attribute :seen_at, AshPostgres.Timestamptz, allow_nil?: false, public?: true

    attribute :phase, AshStrangler.CheckCatalogTest.EnumStoredAsPgEnum,
      allow_nil?: false,
      public?: true

    attribute :body, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CheckCatalogTest.EdgeView do
  @moduledoc "One mapping per column the edge twin needs read."

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a84"

  use Ash.Resource,
    domain: AshStrangler.CheckCatalogTest.EdgeDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "catalog_edge_view"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :body, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.CheckCatalogTest.Edge do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}

      map :body, from: :body, read_only?: true, because: "fixture"
    end
  end
end

defmodule AshStrangler.CheckCatalogTest do
  @moduledoc """
  `mix ash_strangler.check` holds a compiled twin to the catalog it was written
  from, against real tables: a value set that grew, a type that changed, a table
  that went away. Each test builds the legacy table it needs inside the sandbox
  transaction, so nothing here outlives it.
  """

  use AshStrangler.DataCase, async: false

  @domain "AshStrangler.CheckCatalogTest.Domain"
  @shaky_domain "AshStrangler.CheckCatalogTest.ShakyDomain"
  @edge_domain "AshStrangler.CheckCatalogTest.EdgeDomain"

  setup do
    previous = Application.get_env(:ash_strangler, :ash_domains)

    Application.put_env(:ash_strangler, :ash_domains, [
      AshStrangler.CheckCatalogTest.Domain,
      AshStrangler.CheckCatalogTest.ShakyDomain,
      AshStrangler.CheckCatalogTest.EdgeDomain
    ])

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.put_env(:ash_strangler, :ash_domains, previous)
      Mix.shell(shell)
    end)

    :ok
  end

  # `legacy.catalog_orders`, as the twins above describe it. `state` is a Postgres
  # enum by default and a CHECK-constrained text column with `as: :check`; `kind`
  # is always a CHECK. The label lists are what a test varies.
  defp orders!(opts \\ []) do
    labels = Keyword.get(opts, :state, ~w(open paid))
    kinds = Keyword.get(opts, :kind, ~w(retail wholesale))
    channels = Keyword.get(opts, :channel, ~w(web store))
    amount = Keyword.get(opts, :amount, "numeric")
    note = Keyword.get(opts, :note, "text NOT NULL")

    state_column =
      case Keyword.get(opts, :as, :enum) do
        :enum ->
          TestRepo.query!("CREATE TYPE legacy.catalog_state AS ENUM (#{literals(labels)})", [])
          "legacy.catalog_state NOT NULL"

        :check ->
          "text NOT NULL CHECK (state IN (#{literals(labels)}))"
      end

    kind_column = if kinds, do: "text CHECK (kind IN (#{literals(kinds)}))", else: "text"

    TestRepo.query!(
      """
      CREATE TABLE legacy.catalog_orders (
        id bigint PRIMARY KEY,
        state #{state_column},
        kind #{kind_column},
        channel text CHECK (channel IN (#{literals(channels)})),
        amount #{amount},
        note #{note}
      )
      """,
      []
    )
  end

  defp literals(labels), do: Enum.map_join(labels, ", ", &"'#{&1}'")

  describe "a twin that still matches the catalog" do
    test "passes, and says what it compared" do
      orders!()

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/ok.*twin columns/
      assert output =~ "6 column(s) match what gen.twin writes today"
    end

    test "an integer column that grew from int4 to int8 is the same coarse type" do
      orders!()
      TestRepo.query!("ALTER TABLE legacy.catalog_orders ALTER COLUMN id TYPE int", [])

      {result, output} = check()

      assert result == :ok
      refute output =~ ~r/FAIL.*twin column/
    end
  end

  describe "a value set that widened" do
    test "an enum label added fails, naming the mappings that read the column" do
      orders!()
      TestRepo.query!("ALTER TYPE legacy.catalog_state ADD VALUE 'void'", [])

      {result, output} = check()

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin column  state/
      assert output =~ "\"void\""
      assert output =~ "AshStrangler.CheckCatalogTest.Order.state"
      assert output =~ "AshStrangler.CheckCatalogTest.OrderHand.stage"
    end

    test "a CHECK value added fails" do
      orders!(as: :check)

      TestRepo.query!(
        "ALTER TABLE legacy.catalog_orders DROP CONSTRAINT catalog_orders_state_check",
        []
      )

      TestRepo.query!(
        "ALTER TABLE legacy.catalog_orders ADD CHECK (state IN ('open', 'paid', 'void'))",
        []
      )

      {result, output} = check()

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin column  state/
      assert output =~ "\"void\""
    end

    test "a widened set on a column no mapping reads still fails, and says nobody reads it" do
      orders!(channel: ~w(web store phone))

      {result, output} = check()

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin column  channel/
      assert output =~ "\"phone\""
      assert output =~ ~r/no mapping reads it/i
    end

    test "the widened column is found through a hand-written twin's source: name" do
      orders!()
      TestRepo.query!("ALTER TYPE legacy.catalog_state ADD VALUE 'void'", [])

      {_result, output} = check()

      # `status` is the attribute, `state` the column.
      assert output =~ ~r/FAIL.*twin column  status/
      assert output =~ "AshStrangler.CheckCatalogTest.OrderHand.stage"
    end

    test "a value both added and removed is widened first" do
      orders!(as: :check)

      TestRepo.query!(
        "ALTER TABLE legacy.catalog_orders DROP CONSTRAINT catalog_orders_state_check",
        []
      )

      TestRepo.query!(
        "ALTER TABLE legacy.catalog_orders ADD CHECK (state IN ('open', 'void'))",
        []
      )

      {result, output} = check()

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin column  state/
      assert output =~ ~r/warn.*twin column  state/
    end

    test "the order of the labels does not matter" do
      orders!(state: ~w(paid open))

      {result, output} = check()

      assert result == :ok
      refute output =~ ~r/(FAIL|warn).*twin column  state/
    end
  end

  describe "a value set that narrowed" do
    test "a CHECK value dropped warns and does not fail" do
      orders!(as: :check, state: ~w(open))

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/warn.*twin column  state/
      assert output =~ "\"paid\""
    end

    test "an enum with fewer labels warns and does not fail" do
      orders!(state: ~w(open))

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/warn.*twin column  state/
    end
  end

  describe "a one_of the catalog no longer yields" do
    test "warns when the CHECK that gave the column its value set is gone" do
      orders!(kind: nil)

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/warn.*twin column  kind/
      assert output =~ "no longer yields"
    end

    test "warns when the enum became a plain text column" do
      orders!()

      TestRepo.query!(
        "ALTER TABLE legacy.catalog_orders ALTER COLUMN state TYPE text USING state::text",
        []
      )

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/warn.*twin column  state/
      assert output =~ "no longer yields"
    end
  end

  describe "a coarse type that changed" do
    test "fails, naming both types" do
      orders!(amount: "text")

      {result, output} = check()

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin column  amount/
      assert output =~ ":decimal"
      assert output =~ ":string"
    end

    test "a column whose type the generator cannot type warns instead of failing" do
      orders!(amount: "inet")

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/warn.*twin column  amount/
      assert output =~ "no Ash type"
    end
  end

  describe "nullability" do
    test "a twin that allows NULL over a NOT NULL column is only a warning" do
      orders!(note: "text")

      {result, output} = check()

      assert result == :ok
      assert output =~ ~r/warn.*twin column  note/
      assert output =~ "allow_nil?"
    end
  end

  describe "a relation that went away" do
    test "stays a FAIL, and is not turned into a check that did not run" do
      {result, output} = check(["--strict"])

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin freshness/
      assert output =~ "does not exist, or this role cannot see it"
      # The comparison has nothing to compare against and says nothing of its own:
      # the freshness line already failed the task for this.
      refute output =~ ~r/\?\?\?\?.*twin column/
      refute output =~ ~r/ok.*twin columns/
    end

    test "a table dropped after the twin was generated fails by default too" do
      orders!()
      TestRepo.query!("DROP TABLE legacy.catalog_orders", [])

      {result, output} = check()

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin freshness/
    end
  end

  describe "a hand-written twin" do
    test "is held only to what it declares, under the column names it declares" do
      orders!()

      {result, output} = check()

      assert result == :ok
      # `amount` and `note` are not on the hand-written twin: nothing is said of
      # columns it chose not to read beyond the freshness warning.
      refute output =~ ~r/(FAIL|warn).*twin column  (order_id|status)/
    end

    test "a renamed column is not mistaken for a missing one" do
      orders!()

      {_result, output} = check()

      refute output =~ "the twin declares column(s) the relation does not have"
    end
  end

  describe "what a live catalog read can get wrong" do
    test "a CHECK over citext reads as the generator reads it, so an unchanged twin passes" do
      edge!()

      {_result, output} = check([], @edge_domain)

      refute output =~ ~r/twin column  label/
    end

    test "the catalog read leaves the connection's search_path as it found it" do
      edge!()
      %{rows: before} = TestRepo.query!("SHOW search_path", [])

      {_result, _output} = check([], @edge_domain)

      assert %{rows: ^before} = TestRepo.query!("SHOW search_path", [])
    end

    test "a label added to an enum that lives in another schema fails" do
      edge!(stages: ~w(new done archived))

      {result, output} = check([], @edge_domain)

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/FAIL.*twin column  stage/
      assert output =~ ~s("archived")
    end

    test "--strict counts a column whose type has no Ash type" do
      orders!(amount: "inet")

      {result, output} = check(["--strict"])

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/warn.*twin column  amount/
    end
  end

  describe "column types" do
    test "reports a projection that yields a type the attribute does not store" do
      shaky!()

      {_result, output} = check([], @shaky_domain)

      assert output =~ ~r/warn.*column types  qty/
      assert output =~ "int4"
    end

    test "keeps citext distinct from text" do
      shaky!()

      {_result, output} = check([], @shaky_domain)

      assert output =~ ~r/warn.*column types  as_citext/
      assert output =~ "citext"
    end

    test "reports an unknown type rather than collapsing it" do
      shaky!()

      {_result, output} = check([], @shaky_domain)

      assert output =~ ~r/warn.*column types  addr/
      assert output =~ "inet"
      assert output =~ "no Ash type"
    end

    test "reports a Postgres enum rather than collapsing it" do
      orders!()

      {_result, output} = check()

      assert output =~ ~r/warn.*column types  state/
      assert output =~ "Postgres enum"
      assert output =~ "legacy.catalog_state" or output =~ "catalog_state"
    end

    test "a projection that yields the stored type is not reported" do
      shaky!()

      {_result, output} = check([], @shaky_domain)

      refute output =~ ~r/warn.*column types  as_text/
      refute output =~ ~r/(warn|FAIL).*column types  id/
    end

    test "a measured disagreement is a warning, and --strict does not count it" do
      shaky!(addr: "text")

      {_result, output} = check(["--strict"], @shaky_domain)

      assert output =~ ~r/warn.*column types  qty/
      refute output =~ "could not be measured"
    end

    test "--strict counts a Postgres enum, which was not compared" do
      orders!()

      {result, output} = check(["--strict"])

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/warn.*column types  state/
      assert output =~ "could not be measured"
    end

    test "--strict counts a type with no Ash type, which was not compared" do
      shaky!()

      {result, output} = check(["--strict"], @shaky_domain)

      assert {:exit, {:shutdown, 1}} = result
      assert output =~ ~r/warn.*column types  addr/
      assert output =~ "could not be measured"
    end

    test "reads the type without reading the rows" do
      shaky!()
      TestRepo.query!("INSERT INTO legacy.catalog_shaky (id, qty, note) VALUES (1, 3, 'abc')", [])

      # The precondition: evaluated over that row, the projection raises.
      assert {:error, %Postgrex.Error{}} =
               TestRepo.query("SELECT (note)::int FROM legacy.catalog_shaky", [])

      {_result, output} = check([], @shaky_domain)

      # The type of `(note)::int` is still known, because the types query never
      # executes the projection.
      refute output =~ ~r/\?\?\?\?.*column types/
      refute output =~ ~r/(warn|FAIL).*column types  cast_later/
      assert output =~ ~r/warn.*column types  qty/
    end

    test "its pass line says it is not a statement about the rows" do
      shaky!()

      {_result, output} = check([], @shaky_domain)

      assert output =~ "Typmods are not compared"
      assert output =~ "does not show that every row casts"
    end
  end

  defp edge!(opts \\ []) do
    stages = Keyword.get(opts, :stages, ~w(new done))
    odd = Keyword.get(opts, :odd, ~w(x y))
    seen_at = Keyword.get(opts, :seen_at, "timestamptz")

    TestRepo.query!("CREATE TYPE public.catalog_edge_state AS ENUM (#{literals(stages)})", [])

    TestRepo.query!(
      """
      CREATE TABLE legacy.catalog_edge (
        id bigint PRIMARY KEY,
        label citext NOT NULL CHECK (label IN ('a', 'b')),
        stage public.catalog_edge_state NOT NULL,
        "Odd-Name" text NOT NULL CHECK ("Odd-Name" IN (#{literals(odd)})),
        seen_at #{seen_at} NOT NULL,
        phase public.catalog_edge_state NOT NULL,
        body text
      )
      """,
      []
    )
  end

  defp shaky!(opts \\ []) do
    addr = Keyword.get(opts, :addr, "inet")

    TestRepo.query!(
      """
      CREATE TABLE legacy.catalog_shaky (
        id bigint PRIMARY KEY,
        qty integer,
        addr #{addr},
        handle text,
        note text
      )
      """,
      []
    )
  end

  defp check(args \\ [], domain \\ @domain) do
    result =
      try do
        Mix.Task.rerun("ash_strangler.check", ["--domain", domain] ++ args)
        :ok
      catch
        :exit, reason -> {:exit, reason}
      end

    {result, drain()}
  end

  defp drain(collected \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> drain([message | collected])
    after
      0 -> collected |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
