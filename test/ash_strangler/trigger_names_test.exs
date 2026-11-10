# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TriggerNamesTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.TriggerNamesTest.Items
  end
end

defmodule AshStrangler.TriggerNamesTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.TriggerNamesTest.Long
    resource AshStrangler.TriggerNamesTest.Short
  end
end

defmodule AshStrangler.TriggerNamesTest.Items do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.TriggerNamesTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "items"
    schema "trgnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :first_name, :string
    attribute :last_name, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.TriggerNamesTest.Long do
  @moduledoc """
  A view whose table name is 56 bytes. `strangler_<table>_insert` is then 73 bytes,
  and PostgreSQL cuts it to 63 -- which removes the operation, so the insert, update
  and delete functions are one function.
  """
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.TriggerNamesTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "gggggggggggggggggggggggggggggggggggggggggggggggggggggggg"
    schema "trgnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :full_name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:full_name]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.TriggerNamesTest.Items do
      writes :triggers
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      concat :full_name, from: [:first_name, :last_name], separator: " "
    end
  end
end

defmodule AshStrangler.TriggerNamesTest.Short do
  @moduledoc "A view whose trigger names fit, and so are unchanged."
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.TriggerNamesTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "short_items"
    schema "trgnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :full_name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:full_name]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.TriggerNamesTest.Items do
      writes :triggers
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      concat :full_name, from: [:first_name, :last_name], separator: " "
    end
  end
end

defmodule AshStrangler.TriggerNamesTest do
  @moduledoc """
  The generated function and trigger names stay distinct for a long view name.

  PostgreSQL truncates an identifier to 63 bytes without complaint, and the
  operation is the end of the name, so for a long table the insert, update and
  delete objects would be one object, each `CREATE OR REPLACE` replacing the last.
  A name that overflows takes a table prefix and a hash of the table; a name that
  fits is unchanged. `AshStrangler.Sql.ReverseTriggers` applies the same rule.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Migration
  alias AshStrangler.TriggerNamesTest.{Long, Short}

  @long_table "gggggggggggggggggggggggggggggggggggggggggggggggggggggggg"

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
      TestRepo.query!("DROP SCHEMA IF EXISTS trgnames CASCADE", [])
      TestRepo.query!("CREATE SCHEMA trgnames", [])

      TestRepo.query!(
        "CREATE TABLE trgnames.items (id bigserial PRIMARY KEY, first_name text, last_name text)",
        []
      )

      for resource <- [Long, Short], statement <- Migration.statements(resource) do
        TestRepo.query!(statement.up, [])
      end
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!("DROP SCHEMA IF EXISTS trgnames CASCADE", [])
      end)
    end)

    :ok
  end

  defp functions(like) do
    TestRepo.query!(
      """
      SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'trgnames' AND p.proname LIKE $1 ORDER BY 1
      """,
      [like]
    ).rows
    |> List.flatten()
  end

  defp triggers(table) do
    TestRepo.query!(
      """
      SELECT tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'trgnames' AND c.relname = $1 AND NOT t.tgisinternal ORDER BY 1
      """,
      [table]
    ).rows
    |> List.flatten()
  end

  test "the name is a table prefix and a hash, within the limit, when it overflows" do
    assert byte_size(@long_table) == 56

    names = functions("strangler_gggg%")

    assert length(names) == 3
    assert Enum.all?(names, &(byte_size(&1) <= 63))

    assert Enum.map(names, &String.replace(&1, ~r/^.*_(insert|update|delete)$/, "\\1"))
           |> Enum.sort() ==
             ["delete", "insert", "update"]

    assert length(triggers(@long_table)) == 3
  end

  test "a name that fits is unchanged" do
    assert functions("strangler_short_items_%") ==
             [
               "strangler_short_items_delete",
               "strangler_short_items_insert",
               "strangler_short_items_update"
             ]

    assert triggers("short_items") ==
             [
               "strangler_short_items_delete",
               "strangler_short_items_insert",
               "strangler_short_items_update"
             ]
  end

  test "insert, update and delete each reach their own function" do
    # `full_name` is computed from two legacy columns, so the view is not
    # auto-updatable: with a missing trigger the write is refused.
    row = Ash.create!(Long, %{full_name: "Ada Lovelace"})

    assert %{rows: [["Ada", "Lovelace"]]} =
             TestRepo.query!("SELECT first_name, last_name FROM trgnames.items", [])

    row |> Ash.Changeset.for_update(:update, %{full_name: "Grace Hopper"}) |> Ash.update!()

    assert %{rows: [["Grace", "Hopper"]]} =
             TestRepo.query!("SELECT first_name, last_name FROM trgnames.items", [])

    Ash.destroy!(row)
    assert %{rows: [[0]]} = TestRepo.query!("SELECT count(*) FROM trgnames.items", [])
  end

  test "two long tables that share their first 25 bytes keep their own names" do
    id = System.unique_integer([:positive])
    prefix = String.duplicate("g", 55)

    modules =
      for suffix <- ["a", "b"] do
        name = "AshStrangler.TriggerNamesTest.Twin#{id}#{suffix}"

        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.eval_string("""
          defmodule #{name} do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              data_layer: AshPostgres.DataLayer,
              extensions: [AshStrangler.Resource]

            postgres do
              table "#{prefix}#{suffix}"
              schema "trgnames"
              repo AshStrangler.TestRepo
              migrate? false
            end

            attributes do
              attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
              attribute :full_name, :string, public?: true
            end

            actions do
              defaults [:read]
            end

            strangler do
              phase :dual_write

              source AshStrangler.TriggerNamesTest.Items do
                writes :triggers
                key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
                concat :full_name, from: [:first_name, :last_name], separator: " "
              end
            end
          end
          """)
        end)

        Module.concat([name])
      end

    names =
      for module <- modules,
          statement <- Migration.statements(module),
          [function] <-
            Regex.scan(~r/CREATE OR REPLACE FUNCTION (\S+)\(\)/, statement.up,
              capture: :all_but_first
            ) do
        function
      end

    assert length(names) == 6
    assert length(Enum.uniq(names)) == 6
  end

  test "the down statements drop the objects they created" do
    for statement <- Enum.reverse(Migration.statements(Long)),
        do: TestRepo.query!(statement.down, [])

    assert functions("strangler_gggg%") == []

    for statement <- Migration.statements(Long), do: TestRepo.query!(statement.up, [])
    assert length(functions("strangler_gggg%")) == 3
  end
end
