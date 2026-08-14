# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ReverseViewTest do
  @moduledoc """
  Step 7: the view flips direction, and its name flips with it.

  In `:read_from_new` the *legacy* name becomes a view over the Ash-owned
  table, so the old application's `SELECT * FROM users` keeps working without a
  line of its SQL changing. That is what makes cutover a migration rather than
  a coordinated deploy of two systems.

  These tests run the generated SQL against a real table, because a reverse
  view that merely looks right is exactly the failure this package exists to
  prevent — it would return NULL for columns the old application still reads,
  starting at the least recoverable moment of the whole migration.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    # A real Ash-owned table standing in for the post-cutover shape, plus the
    # generated view over it wearing the legacy name.
    TestRepo.query!("DROP VIEW IF EXISTS reverse_legacy.widgets", [])
    TestRepo.query!("DROP SCHEMA IF EXISTS reverse_legacy CASCADE", [])
    TestRepo.query!("DROP TABLE IF EXISTS strangler.widgets", [])
    TestRepo.query!("CREATE SCHEMA reverse_legacy", [])

    TestRepo.query!(
      """
      CREATE TABLE strangler.widgets (
        id uuid PRIMARY KEY,
        legacy_id bigint NOT NULL,
        label text,
        state_code integer,
        archived_at timestamptz
      )
      """,
      []
    )

    :ok
  end

  describe "the reverse view" do
    test "projects the legacy column names, running each mapping backwards" do
      resource = reverse_resource()

      [%{up: up, down: down}] = AshStrangler.Sql.ReverseView.build(resource)

      # Columns follow DSL declaration order, with the legacy key first.
      assert up == """
             CREATE OR REPLACE VIEW reverse_legacy.widgets AS
             SELECT
               legacy_id AS id,
               label AS name,
               archived_at AT TIME ZONE 'UTC' AS deleted_at,
               CASE state_code WHEN 0 THEN 'active' ELSE 'retired' END AS status
             FROM "strangler"."widgets";
             """

      assert down == "DROP VIEW IF EXISTS reverse_legacy.widgets;"
    end

    test "the generated SQL runs, and the old application's query still works" do
      resource = reverse_resource()
      [%{up: up}] = AshStrangler.Sql.ReverseView.build(resource)

      TestRepo.query!(up, [])

      TestRepo.query!(
        """
        INSERT INTO strangler.widgets (id, legacy_id, label, state_code, archived_at)
        VALUES ($1, 42, 'a widget', 0, '2024-06-15 12:00:00Z')
        """,
        [Ecto.UUID.dump!(Ash.UUID.generate())]
      )

      # Verbatim what the legacy application would run. It does not know the
      # table became a view.
      %Postgrex.Result{rows: [[id, name, status, deleted_at]]} =
        TestRepo.query!(
          "SELECT id, name, status, deleted_at FROM reverse_legacy.widgets WHERE id = 42",
          []
        )

      assert id == 42
      assert name == "a widget"
      assert status == "active"
      # The naive form the legacy column always held, in the stated zone --
      # the exact inverse of the forward projection.
      assert deleted_at == ~N[2024-06-15 12:00:00.000000]
    end

    test "refuses to build without a legacy_id to expose" do
      # The uuid derivation only runs one way, so the legacy key cannot be
      # recovered from the modern id. If the backfill did not carry it across,
      # the old application's `WHERE id = 42` matches nothing -- a failure that
      # would surface only after cutover.
      resource = reverse_resource(legacy_id?: false)

      assert_raise ArgumentError, ~r/legacy_id/, fn ->
        AshStrangler.Sql.ReverseView.build(resource)
      end
    end
  end

  describe "notify triggers in :read_from_new" do
    test "are not emitted, because the relation is a view by then" do
      # Regression. `Sql.Notify` attaches an `AFTER ... FOR EACH ROW` trigger to
      # `source.relation`, and in this phase that name is the reverse VIEW.
      # Postgres rejects row-level AFTER triggers on a view outright, so
      # emitting one produced a migration that could not run -- and nothing
      # would have caught it until `mix ecto.migrate`, because the generator
      # itself is happy to build the string.
      resource = reverse_resource(notify?: true)

      names = resource |> AshStrangler.Migration.statements() |> Enum.map(& &1.name)

      assert names == [:strangler_widgets_reverse_view]

      refute Enum.any?(names, &(&1 |> to_string() |> String.contains?("notify")))
    end

    test "the SQL that would have been emitted is indeed rejected by Postgres" do
      # Proves the guard is protecting against something real rather than a
      # theory: build the notify DDL by hand against the reverse view and watch
      # Postgres refuse it.
      resource = reverse_resource()
      [%{up: view_up}] = AshStrangler.Sql.ReverseView.build(resource)
      TestRepo.query!(view_up, [])

      assert_raise Postgrex.Error, ~r/view|trigger/i, fn ->
        TestRepo.query!(
          """
          CREATE OR REPLACE FUNCTION pg_temp.probe() RETURNS trigger AS $$
          BEGIN RETURN NULL; END $$ LANGUAGE plpgsql
          """,
          []
        )

        TestRepo.query!(
          """
          CREATE TRIGGER probe AFTER INSERT ON reverse_legacy.widgets
            FOR EACH ROW EXECUTE FUNCTION pg_temp.probe()
          """,
          []
        )
      end
    end
  end

  describe "VerifyReverseMappable" do
    test "refuses :read_from_new when a mapping declared it cannot be reversed" do
      resource = reverse_resource(irreversible?: true)

      assert {:error, error} =
               AshStrangler.Verifiers.VerifyReverseMappable.verify(resource.spark_dsl_config())

      message = Exception.message(error)

      assert message =~ ":summary"
      # The `because:` text is what tells the reader why it cannot be reversed,
      # so it has to travel into this error rather than being paraphrased.
      assert message =~ "Collapsed from three columns"
    end

    test "allows :read_from_new when every mapping is reversible" do
      assert :ok =
               AshStrangler.Verifiers.VerifyReverseMappable.verify(
                 reverse_resource().spark_dsl_config()
               )
    end
  end

  defp reverse_resource(opts \\ []) do
    name = "ReverseWidget#{System.unique_integer([:positive])}"

    legacy_id =
      if Keyword.get(opts, :legacy_id?, true),
        do: "attribute :legacy_id, :integer, allow_nil?: false, public?: true",
        else: ""

    irreversible =
      if Keyword.get(opts, :irreversible?, false) do
        """
        attribute :summary, :string, public?: true
        """
      else
        ""
      end

    irreversible_mapping =
      if Keyword.get(opts, :irreversible?, false) do
        """
        map :summary do
          from "label || ' ' || status"
          writable? false
          because "Collapsed from three columns and not decomposable."
        end
        """
      else
        ""
      end

    notify = if Keyword.get(opts, :notify?, false), do: "notify? true", else: ""

    unmapped_legacy_id =
      if Keyword.get(opts, :legacy_id?, true),
        do:
          ~s|unmapped [:legacy_id], as: :null, because: "Carried by the backfill, not projected."|,
        else: ""

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
            table "widgets"
            schema "strangler"
            repo AshStrangler.TestRepo
          end

          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
            #{legacy_id}
            attribute :label, :string, public?: true
            attribute :state_code, :integer, public?: true
            attribute :archived_at, :utc_datetime_usec, public?: true
            #{irreversible}
          end

          strangler do
            phase :read_from_new

            source "reverse_legacy.widgets" do
              #{notify}
              key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

              map :label, "name"
              map :archived_at, "deleted_at", cast: :timestamptz, from_zone: "UTC"

              map :state_code do
                from "CASE status WHEN 'active' THEN 0 ELSE 1 END"
                to "CASE $NEW.state_code WHEN 0 THEN 'active' ELSE 'retired' END"
                into "status"
              end

              #{irreversible_mapping}
              #{unmapped_legacy_id}
            end
          end
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module
  end
end
