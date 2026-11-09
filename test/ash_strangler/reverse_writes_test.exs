# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ReverseWritesTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.ReverseWritesTest.Legacy.Gadgets
    resource AshStrangler.ReverseWritesTest.Legacy.Things
  end
end

defmodule AshStrangler.ReverseWritesTest.Legacy.Gadgets do
  @moduledoc """
  The twin for `rw_legacy.gadgets`, with the column names that break a naive
  generator: a CamelCase key (`"GadgetId"`) and a CamelCase attribute (`"Name"`).

  The columns are declared in an order that is not alphabetical, because the
  reverse view has to keep the twin's order.
  """
  use Ash.Resource,
    domain: AshStrangler.ReverseWritesTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "gadgets"
    schema "rw_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, source: :GadgetId
    attribute :status, :atom, constraints: [one_of: [:active, :retired]]
    attribute :display_name, :string, source: :Name
    attribute :deleted_at, :naive_datetime
    attribute :legacy_flag, :boolean
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.ReverseWritesTest.Legacy.Things do
  @moduledoc "A twin whose every column is a plain rename, with a uuid key."
  use Ash.Resource,
    domain: AshStrangler.ReverseWritesTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "things"
    schema "rw_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :title, :string
    attribute :note, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.ReverseWritesTest do
  @moduledoc """
  `:read_from_new` carries the old application's WRITES, and produces every column
  it reads.

  Every test here creates the owned table, applies the generated statements and
  then writes as the legacy application would: plain SQL, `INSERT ... RETURNING`,
  `UPDATE`, `DELETE`, against the legacy name. A trigger that merely looks right
  is the failure this package exists to prevent, so nothing asserts on SQL text
  that a database run does not also exercise.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Sql.{ReverseTriggers, ReverseView}
  alias AshStrangler.Verifiers.VerifyReverseMappable

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"
  @gadget_relation "rw_legacy.gadgets"

  setup do
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS rw_legacy", [])

    # The owned table the resource stores in. `ttl` is the owned column for the
    # `title` attribute (`source: :ttl`), so a view that spelled the attribute name
    # would fail to create. `region` is an attribute no mapping touches.
    TestRepo.query!(
      """
      CREATE TABLE strangler.rw_gadgets (
        id uuid PRIMARY KEY,
        legacy_id bigint NOT NULL,
        ttl text,
        state_code integer,
        archived_at timestamptz,
        region text DEFAULT 'eu'
      )
      """,
      []
    )

    TestRepo.query!(
      """
      CREATE TABLE strangler.rw_things (
        id uuid PRIMARY KEY,
        legacy_id uuid,
        title text,
        note text
      )
      """,
      []
    )

    :ok
  end

  # --- the verifier ------------------------------------------------------------

  describe "every legacy column is produced or refused" do
    test "a twin column no mapping writes is refused, naming it and the way out" do
      resource = gadget_resource(retired?: false)

      assert {:error, error} = VerifyReverseMappable.verify(resource.spark_dsl_config())
      message = Exception.message(error)

      assert message =~ ":legacy_flag"
      assert message =~ "retired"
      assert message =~ "map "
      # Not just a column the twin has: only the unproduced one is named.
      refute message =~ ":display_name"
      refute message =~ ":deleted_at"
    end

    test "a retired column, with its reason, is accepted" do
      assert :ok = VerifyReverseMappable.verify(gadget_resource().spark_dsl_config())
    end

    test "a retirement that contradicts the mapping is refused" do
      resource =
        gadget_resource(retired: ~s|retired [:legacy_flag, :deleted_at, :nope], because: " "|)

      assert {:error, error} = VerifyReverseMappable.verify(resource.spark_dsl_config())
      message = Exception.message(error)

      assert message =~ "empty `because:`"
      assert message =~ ":nope"
      assert message =~ ":deleted_at"
    end

    test "building the view without the verifier still refuses to drop a column" do
      resource = gadget_resource(retired?: false)

      assert_raise ArgumentError, ~r/:legacy_flag/, fn -> ReverseView.build(resource) end
    end
  end

  # --- the view's shape -------------------------------------------------------

  describe "the reverse view" do
    test "keeps the twin's column order and names, quoted, through the owned column names" do
      resource = gadget_resource()
      [%{up: up}] = ReverseView.build(resource)

      assert up == """
             CREATE OR REPLACE VIEW rw_legacy.gadgets AS
             SELECT
               legacy_id AS "GadgetId",
               (CASE state_code WHEN 0 THEN 'active' WHEN 1 THEN 'retired' END) AS status,
               ttl AS "Name",
               (archived_at AT TIME ZONE 'UTC') AS deleted_at,
               NULL::boolean AS legacy_flag
             FROM "strangler"."rw_gadgets";
             """

      TestRepo.query!(up, [])

      # What the legacy application's `SELECT *` sees.
      result = TestRepo.query!("SELECT * FROM rw_legacy.gadgets", [])
      assert result.columns == ["GadgetId", "status", "Name", "deleted_at", "legacy_flag"]
    end

    test "a retired column is a typed NULL, so the shape of SELECT * is kept" do
      install!(gadget_resource())
      insert_owned!(7, "Alpha", 0)

      %{columns: columns, rows: [[7, "active", "Alpha", nil, nil]]} =
        TestRepo.query!("SELECT * FROM rw_legacy.gadgets", [])

      assert "legacy_flag" in columns

      assert %{rows: [["boolean"]]} =
               TestRepo.query!(
                 "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'rw_legacy.gadgets'::regclass AND attname = 'legacy_flag'",
                 []
               )
    end

    test "a plain rename is a simple reference; an :identity key without legacy_id exposes the key" do
      [%{up: up}] = ReverseView.build(thing_resource())

      assert up =~ "id AS id"
      assert up =~ "title AS title"
    end
  end

  # --- when the triggers are emitted -------------------------------------------

  describe "when INSTEAD OF triggers are emitted" do
    test "a derived key forces them, one statement per command, function before trigger" do
      resource = gadget_resource()

      assert ReverseTriggers.needed?(resource)

      assert Enum.map(ReverseTriggers.build(resource), & &1.name) == [
               :strangler_rw_gadgets_reverse_insert_function,
               :strangler_rw_gadgets_reverse_insert_trigger,
               :strangler_rw_gadgets_reverse_update_function,
               :strangler_rw_gadgets_reverse_update_trigger,
               :strangler_rw_gadgets_reverse_delete_function,
               :strangler_rw_gadgets_reverse_delete_trigger
             ]
    end

    test "the migration lists them right after the view" do
      names = gadget_resource() |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      assert Enum.take(names, 3) == [
               :strangler_rw_gadgets_reverse_view,
               :strangler_rw_gadgets_reverse_insert_function,
               :strangler_rw_gadgets_reverse_insert_trigger
             ]
    end

    test "a plain view carries every write, so none are emitted and ON CONFLICT survives" do
      resource = thing_resource()

      refute ReverseTriggers.needed?(resource)
      assert ReverseTriggers.build(resource) == []

      refute Enum.any?(
               AshStrangler.Migration.statements(resource),
               &(&1.name |> to_string() =~ "reverse_insert")
             )

      install!(resource)
      id = Ash.UUID.generate()

      for title <- ["first", "second"] do
        TestRepo.query!(
          """
          INSERT INTO rw_legacy.things (id, title, note) VALUES ($1, $2, 'n')
          ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title
          """,
          [Ecto.UUID.dump!(id), title]
        )
      end

      assert %{rows: [["second"]]} = TestRepo.query!("SELECT title FROM strangler.rw_things", [])
    end

    test "an :identity key that also stores a legacy_id is derived, and refuses an insert with no key" do
      resource = thing_resource(legacy_id?: true)

      assert ReverseTriggers.needed?(resource)
      install!(resource)

      id = Ash.UUID.generate()

      TestRepo.query!("INSERT INTO rw_legacy.things (id, title) VALUES ($1, 'x')", [
        Ecto.UUID.dump!(id)
      ])

      assert %{rows: [[stored_id, legacy_id]]} =
               TestRepo.query!("SELECT id, legacy_id FROM strangler.rw_things", [])

      assert Ecto.UUID.load!(stored_id) == id
      assert Ecto.UUID.load!(legacy_id) == id

      assert_raise Postgrex.Error, ~r/nothing allocates it/, fn ->
        TestRepo.query!("INSERT INTO rw_legacy.things (title) VALUES ('no key')", [])
      end
    end
  end

  # --- the old application writes ---------------------------------------------

  describe "a legacy INSERT" do
    setup do
      install!(gadget_resource())
      :ok
    end

    test "stores what a backfill would have stored, and RETURNING reports the stored row" do
      %{columns: columns, rows: [row]} =
        TestRepo.query!(
          """
          INSERT INTO rw_legacy.gadgets ("GadgetId", status, "Name", deleted_at)
          VALUES (7, 'active', 'Alpha', '2024-06-15 12:00:00')
          RETURNING *
          """,
          []
        )

      assert columns == ["GadgetId", "status", "Name", "deleted_at", "legacy_flag"]
      assert row == [7, "active", "Alpha", ~N[2024-06-15 12:00:00.000000], nil]

      assert %{rows: [[id, 7, "Alpha", 0, archived_at, "eu"]]} =
               TestRepo.query!(
                 "SELECT id, legacy_id, ttl, state_code, archived_at, region FROM strangler.rw_gadgets",
                 []
               )

      # The owned key is the one the forward view derives, and the legacy key is stored.
      key = AshStrangler.Info.key(gadget_resource())
      assert Ecto.UUID.load!(id) == AshStrangler.KeyDerivation.derive(key, @gadget_relation, 7)
      assert archived_at == ~U[2024-06-15 12:00:00.000000Z]
    end

    test "a column no lens writes is not assigned, so the owned default applies" do
      TestRepo.query!(
        ~s|INSERT INTO rw_legacy.gadgets ("GadgetId", status) VALUES (8, 'retired')|,
        []
      )

      assert %{rows: [["eu", 1]]} =
               TestRepo.query!("SELECT region, state_code FROM strangler.rw_gadgets", [])
    end

    test "a positional INSERT lands in the twin's column order" do
      TestRepo.query!(
        "INSERT INTO rw_legacy.gadgets VALUES (9, 'active', 'Zed', '2024-01-01 00:00:00', NULL)",
        []
      )

      assert %{rows: [[9, "Zed"]]} =
               TestRepo.query!("SELECT legacy_id, ttl FROM strangler.rw_gadgets", [])
    end

    test "with no key, the sequence on the owned legacy_id allocates one" do
      TestRepo.query!(
        "ALTER TABLE strangler.rw_gadgets ALTER COLUMN legacy_id ADD GENERATED BY DEFAULT AS IDENTITY (START WITH 500)",
        []
      )

      assert %{rows: [[500, "active"]]} =
               TestRepo.query!(
                 ~s|INSERT INTO rw_legacy.gadgets (status, "Name") VALUES ('active', 'Auto') RETURNING "GadgetId", status|,
                 []
               )

      key = AshStrangler.Info.key(gadget_resource())

      assert %{rows: [[id, 500]]} =
               TestRepo.query!("SELECT id, legacy_id FROM strangler.rw_gadgets", [])

      assert Ecto.UUID.load!(id) == AshStrangler.KeyDerivation.derive(key, @gadget_relation, 500)
    end

    test "with no key and nothing to allocate one, it raises and stores nothing" do
      assert_raise Postgrex.Error, ~r/no sequence to allocate one from/, fn ->
        TestRepo.query!(
          ~s|INSERT INTO rw_legacy.gadgets (status, "Name") VALUES ('active', 'Lost')|,
          []
        )
      end

      assert %{rows: [[0]]} = TestRepo.query!("SELECT count(*) FROM strangler.rw_gadgets", [])
    end

    test "a value the decode table has no counterpart for is refused, not stored as NULL" do
      assert_raise Postgrex.Error, ~r/the value weird has no counterpart/, fn ->
        TestRepo.query!(
          ~s|INSERT INTO rw_legacy.gadgets ("GadgetId", status) VALUES (3, 'weird')|,
          []
        )
      end

      assert %{rows: [[0]]} = TestRepo.query!("SELECT count(*) FROM strangler.rw_gadgets", [])
    end

    test "assigning a retired column is refused, quoting the reason" do
      assert_raise Postgrex.Error, ~r/retired: Nothing reads the flag/, fn ->
        TestRepo.query!(
          ~s|INSERT INTO rw_legacy.gadgets ("GadgetId", legacy_flag) VALUES (4, true)|,
          []
        )
      end
    end
  end

  describe "a legacy UPDATE" do
    setup do
      install!(gadget_resource())
      insert_owned!(7, "Alpha", 0)
      TestRepo.query!("UPDATE strangler.rw_gadgets SET region = 'custom'", [])
      :ok
    end

    test "carries the mapped columns, returns the stored row, and leaves unmapped columns alone" do
      assert %{rows: [[7, "retired", "Beta", nil, nil]]} =
               TestRepo.query!(
                 ~s|UPDATE rw_legacy.gadgets SET status = 'retired', "Name" = 'Beta' WHERE "GadgetId" = 7 RETURNING *|,
                 []
               )

      assert %{rows: [["custom", 1, "Beta"]]} =
               TestRepo.query!("SELECT region, state_code, ttl FROM strangler.rw_gadgets", [])
    end

    test "archival reads and writes through deleted_at" do
      # What AshArchival does on destroy: stamp the archive attribute on the owned row.
      TestRepo.query!("UPDATE strangler.rw_gadgets SET archived_at = '2025-01-02 03:04:05Z'", [])

      assert %{rows: [[~N[2025-01-02 03:04:05.000000]]]} =
               TestRepo.query!("SELECT deleted_at FROM rw_legacy.gadgets", [])

      # The legacy application un-deleting the row.
      TestRepo.query!(~s|UPDATE rw_legacy.gadgets SET deleted_at = NULL WHERE "GadgetId" = 7|, [])

      assert %{rows: [[nil]]} =
               TestRepo.query!("SELECT archived_at FROM strangler.rw_gadgets", [])
    end

    test "changing the key is refused" do
      assert_raise Postgrex.Error, ~r/cannot change the key/, fn ->
        TestRepo.query!(~s|UPDATE rw_legacy.gadgets SET "GadgetId" = 8 WHERE "GadgetId" = 7|, [])
      end
    end

    test "assigning a retired column is refused" do
      assert_raise Postgrex.Error, ~r/retired/, fn ->
        TestRepo.query!(
          ~s|UPDATE rw_legacy.gadgets SET legacy_flag = true WHERE "GadgetId" = 7|,
          []
        )
      end
    end

    test "an update that matches no row reports zero" do
      assert %{num_rows: 0} =
               TestRepo.query!(
                 ~s|UPDATE rw_legacy.gadgets SET "Name" = 'x' WHERE "GadgetId" = 99|,
                 []
               )
    end
  end

  describe "a legacy DELETE" do
    setup do
      install!(gadget_resource())
      insert_owned!(7, "Alpha", 0)
      :ok
    end

    test "deletes the owned row and returns it" do
      assert %{rows: [[7, "active", "Alpha", nil, nil]]} =
               TestRepo.query!(
                 ~s|DELETE FROM rw_legacy.gadgets WHERE "GadgetId" = 7 RETURNING *|,
                 []
               )

      assert %{rows: [[0]]} = TestRepo.query!("SELECT count(*) FROM strangler.rw_gadgets", [])
    end

    test "a row that is not there is DELETE 0" do
      assert %{num_rows: 0} =
               TestRepo.query!(~s|DELETE FROM rw_legacy.gadgets WHERE "GadgetId" = 99|, [])
    end
  end

  # --- the statements themselves ----------------------------------------------

  describe "the generated statements" do
    test "downs are order-independent and ups are idempotent" do
      statements =
        ReverseView.build(gadget_resource()) ++ ReverseTriggers.build(gadget_resource())

      for %{up: up} <- statements, do: TestRepo.query!(up, [])

      # In list order -- the opposite of what teardown needs, and what AshPostgres does.
      for %{down: down} <- statements, do: TestRepo.query!(down, [])
      for %{down: down} <- statements, do: TestRepo.query!(down, [])

      assert %{rows: [[nil]]} = TestRepo.query!("SELECT to_regclass('rw_legacy.gadgets')", [])

      for %{up: up} <- statements, do: TestRepo.query!(up, [])
      for %{up: up} <- statements, do: TestRepo.query!(up, [])
    end
  end

  # --- the ledger ---------------------------------------------------------------

  describe "with a ledger source" do
    test "the ledger trigger on the owned table fires exactly once per legacy write" do
      resource = gadget_resource(ledger?: true)
      install!(resource)
      for %{up: up} <- AshStrangler.Sql.Ledger.build(resource), do: TestRepo.query!(up, [])

      count = fn operation ->
        %{rows: [[n]]} =
          TestRepo.query!(
            "SELECT count(*) FROM legacy_change_events WHERE source_table = 'rw_gadgets' AND operation = $1",
            [operation]
          )

        n
      end

      TestRepo.query!(
        ~s|INSERT INTO rw_legacy.gadgets ("GadgetId", status) VALUES (7, 'active')|,
        []
      )

      assert {count.("insert"), count.("update"), count.("delete")} == {1, 0, 0}

      TestRepo.query!(~s|UPDATE rw_legacy.gadgets SET "Name" = 'x' WHERE "GadgetId" = 7|, [])
      assert {count.("insert"), count.("update"), count.("delete")} == {1, 1, 0}

      TestRepo.query!(~s|DELETE FROM rw_legacy.gadgets WHERE "GadgetId" = 7|, [])
      assert {count.("insert"), count.("update"), count.("delete")} == {1, 1, 1}
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp install!(resource) do
    for %{up: up} <- ReverseView.build(resource) ++ ReverseTriggers.build(resource),
        do: TestRepo.query!(up, [])
  end

  # A row as it would sit after the backfill, written to the owned table directly.
  defp insert_owned!(legacy_id, title, state_code) do
    key = AshStrangler.Info.key(gadget_resource())
    id = AshStrangler.KeyDerivation.derive(key, @gadget_relation, legacy_id)

    TestRepo.query!(
      "INSERT INTO strangler.rw_gadgets (id, legacy_id, ttl, state_code) VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(id), legacy_id, title, state_code]
    )
  end

  defp define!(source) do
    {result, _io} = with_io(:stderr, fn -> Code.eval_string(source) end)
    {{:module, module, _, _}, _binding} = result
    module
  end

  # `gadget_resource/1` is memoised per option set within the test process, because
  # the helpers above need its `key` and calling it again would compile another module.
  defp gadget_resource(opts \\ []) do
    key = {:gadget_resource, opts}

    case Process.get(key) do
      nil ->
        module = do_gadget_resource(opts)
        Process.put(key, module)
        module

      module ->
        module
    end
  end

  defp do_gadget_resource(opts) do
    name = "RwGadget#{System.unique_integer([:positive])}"

    retired =
      cond do
        Keyword.has_key?(opts, :retired) ->
          Keyword.fetch!(opts, :retired)

        Keyword.get(opts, :retired?, true) ->
          ~s|retired [:legacy_flag], because: "Nothing reads the flag any more."|

        true ->
          ""
      end

    ledger = if Keyword.get(opts, :ledger?, false), do: "notify? true\nledger? true", else: ""

    define!("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

      postgres do
        table "rw_gadgets"
        schema "strangler"
        repo AshStrangler.TestRepo
      end

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
        attribute :legacy_id, :integer, allow_nil?: false, public?: true
        attribute :title, :string, public?: true, source: :ttl
        attribute :state_code, :integer, public?: true, constraints: [min: 0, max: 1]
        attribute :archived_at, :utc_datetime_usec, public?: true
        attribute :region, :string, public?: true, default: "eu"
      end

      strangler do
        phase :read_from_new

        source AshStrangler.ReverseWritesTest.Legacy.Gadgets do
          #{ledger}
          key :id, from: :id, strategy: {:uuid_v5, namespace: "#{@namespace}"}

          map :title, from: :display_name
          map :archived_at, from: :deleted_at, zone: "UTC"
          decode :state_code, from: :status, values: %{active: 0, retired: 1}

          unmapped [:legacy_id], as: :null, because: "Carried by the backfill, not projected."
          unmapped [:region], as: :null, because: "Owned by the new application; the old one never saw it."

          #{retired}
        end
      end
    end
    """)
  end

  defp thing_resource(opts \\ []) do
    name = "RwThing#{System.unique_integer([:positive])}"

    legacy_id =
      if Keyword.get(opts, :legacy_id?, false),
        do: "attribute :legacy_id, :uuid, public?: true",
        else: ""

    unmapped =
      if Keyword.get(opts, :legacy_id?, false),
        do: ~s|unmapped [:legacy_id], as: :null, because: "Carried, not projected."|,
        else: ""

    define!("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

      postgres do
        table "rw_things"
        schema "strangler"
        repo AshStrangler.TestRepo
      end

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false
        #{legacy_id}
        attribute :title, :string, public?: true
        attribute :note, :string, public?: true
      end

      strangler do
        phase :read_from_new

        source AshStrangler.ReverseWritesTest.Legacy.Things do
          key :id, from: :id, strategy: :identity

          map :title, from: :title
          map :note, from: :note
          #{unmapped}
        end
      end
    end
    """)
  end
end
