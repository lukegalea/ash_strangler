# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.CascadeTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.CascadeTest.Legacy.Parents
  end
end

defmodule AshStrangler.CascadeTest.Legacy.Parents do
  @moduledoc """
  The twin for the cascade tests' owner: a plain rename of the owned table's
  key and archive column, which is all the reverse view has to produce.
  """
  use Ash.Resource,
    domain: AshStrangler.CascadeTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "cascade_parents"
    schema "rw_cascade_legacy"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :deleted_at, :naive_datetime
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.CascadeTest.OtherRepo do
  @moduledoc "A second repo, never started: a destination in it is refused."
  use AshPostgres.Repo, otp_app: :ash_strangler, warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule AshStrangler.CascadeTest.ManualToys do
  @moduledoc "A manual relationship's loader: Elixir code no trigger can run."
  use Ash.Resource.ManualRelationship

  @impl true
  def load(_records, _opts, _context), do: {:ok, %{}}
end

defmodule AshStrangler.ArchiveRelatedCascadeTest do
  @moduledoc """
  What a legacy `DELETE` cascades at `:read_from_new`, and what it refuses to
  cascade.

  AshArchival's own cascade is Ash actions; a legacy `DELETE` through the
  reverse view runs none of them. The generated `INSTEAD OF DELETE` does the
  equivalent work in one statement — stamp the owned row, then stamp, through
  data-modifying CTEs chained with `RETURNING`, every not-yet-archived row the
  resource's `archive_related` leads to, recursing through each destination's
  own `archive_related` — so the DELETE and its cascade commit or fail
  together. Every SQL test here runs the GENERATED statements against a real
  Postgres, writing as the legacy application would.
  """

  use AshStrangler.DataCase, async: false

  import ExUnit.CaptureIO

  alias AshStrangler.Sql.{ReverseTriggers, ReverseView}
  alias AshStrangler.Verifiers.VerifyArchiveRelated

  setup do
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS rw_cascade", [])
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS rw_cascade_legacy", [])

    for ddl <- [
          "CREATE TABLE rw_cascade.cascade_parents (id uuid PRIMARY KEY, archived_at timestamptz)",
          """
          CREATE TABLE rw_cascade.cascade_children (
            id uuid PRIMARY KEY,
            parent_id uuid,
            toy_id uuid,
            archived_at timestamptz
          )
          """,
          """
          CREATE TABLE rw_cascade.cascade_grandchildren (
            id uuid PRIMARY KEY,
            child_id uuid,
            archived_at timestamptz
          )
          """,
          "CREATE TABLE rw_cascade.cascade_toys (id uuid PRIMARY KEY, archived_at timestamptz)",
          """
          CREATE TABLE rw_cascade.cascade_profiles (
            id uuid PRIMARY KEY,
            owner_id uuid,
            archived_at timestamptz
          )
          """
        ],
        do: TestRepo.query!(ddl, [])

    :ok
  end

  describe "a legacy DELETE that cascades archive_related" do
    test "archives exactly the unarchived descendants of the deleted row, and nothing of a sibling parent" do
      install!(family!().owner)

      p1 = insert_parent!()
      p2 = insert_parent!()

      c1 = insert_child!(p1)
      c2 = insert_child!(p1)
      c3 = insert_child!(p2)

      g1 = insert_grandchild!(c1)
      g2 = insert_grandchild!(c3)

      assert %{num_rows: 1} = delete_parent!(p1)

      # The deleted parent's own subtree, in full.
      assert %DateTime{} = archived_at(:cascade_parents, p1)
      assert %DateTime{} = archived_at(:cascade_children, c1)
      assert %DateTime{} = archived_at(:cascade_children, c2)
      assert %DateTime{} = archived_at(:cascade_grandchildren, g1)

      # The sibling parent's row and subtree, untouched.
      assert is_nil(archived_at(:cascade_parents, p2))
      assert is_nil(archived_at(:cascade_children, c3))
      assert is_nil(archived_at(:cascade_grandchildren, g2))
    end

    test "every row of the cascade carries the one stamp the statement made" do
      install!(family!().owner)

      p1 = insert_parent!()
      c1 = insert_child!(p1)
      g1 = insert_grandchild!(c1)

      delete_parent!(p1)

      stamp = archived_at(:cascade_parents, p1)
      assert %DateTime{} = stamp
      assert archived_at(:cascade_children, c1) == stamp
      assert archived_at(:cascade_grandchildren, g1) == stamp
    end

    test "an already-archived child keeps its original stamp, and its subtree is not cascaded" do
      # Recursion follows only rows archived by THIS statement, as AshArchival's
      # does: its cascade reads the destination through the archive filter, so
      # a child archived earlier is neither re-stamped nor followed.
      install!(family!().owner)

      p1 = insert_parent!()
      stamped = ~U[2025-01-02 03:04:05.000000Z]

      c1 = insert_child!(p1, stamped)
      c2 = insert_child!(p1)

      g1 = insert_grandchild!(c1)
      g2 = insert_grandchild!(c2)

      assert %{num_rows: 1} = delete_parent!(p1)

      assert archived_at(:cascade_children, c1) == stamped
      assert %DateTime{} = archived_at(:cascade_children, c2)
      assert is_nil(archived_at(:cascade_grandchildren, g1))
      assert %DateTime{} = archived_at(:cascade_grandchildren, g2)
    end

    test "a DELETE of an already-archived parent cascades nothing" do
      # The existing DELETE 0 path: nothing was archived by this statement, so
      # nothing follows from it.
      install!(family!().owner)

      stamped = ~U[2025-01-02 03:04:05.000000Z]
      p1 = insert_parent!(stamped)
      c1 = insert_child!(p1)
      g1 = insert_grandchild!(c1)

      assert %{num_rows: 0} = delete_parent!(p1)

      assert archived_at(:cascade_parents, p1) == stamped
      assert is_nil(archived_at(:cascade_children, c1))
      assert is_nil(archived_at(:cascade_grandchildren, g1))
    end

    test "a has_one archive_related cascades" do
      install!(family!(owner_relationship: :has_one, owner_related: [:profile]).owner)

      p1 = insert_parent!()
      profile = insert_profile!(p1)
      other = insert_profile!(insert_parent!())

      assert %{num_rows: 1} = delete_parent!(p1)

      assert %DateTime{} = archived_at(:cascade_profiles, profile)
      assert is_nil(archived_at(:cascade_profiles, other))
    end

    test "a belongs_to archive_related cascades, matched through the source's own foreign key" do
      # AshArchival follows whatever relationship is listed, in either
      # direction: the toy is the one the archived child's `toy_id` names.
      install!(family!(child_related: [:grandchildren, :toy]).owner)

      p1 = insert_parent!()
      toy = insert_toy!()
      other_toy = insert_toy!()
      c1 = insert_child!(p1, nil, toy)
      g1 = insert_grandchild!(c1)
      insert_child!(insert_parent!(), nil, other_toy)

      assert %{num_rows: 1} = delete_parent!(p1)

      assert %DateTime{} = archived_at(:cascade_children, c1)
      assert %DateTime{} = archived_at(:cascade_grandchildren, g1)
      assert %DateTime{} = archived_at(:cascade_toys, toy)
      assert is_nil(archived_at(:cascade_toys, other_toy))
    end

    test "the cascade fails with the DELETE: nothing is archived when a descendant refuses the stamp" do
      # One statement, one transaction: a constraint violation two levels down
      # rolls the owned row's archive back too.
      install!(family!().owner)

      TestRepo.query!(
        """
        ALTER TABLE rw_cascade.cascade_grandchildren
        ADD CONSTRAINT cascade_past_only CHECK (archived_at < '2020-01-01')
        """,
        []
      )

      p1 = insert_parent!()
      c1 = insert_child!(p1)
      insert_grandchild!(c1)

      assert_raise Postgrex.Error, ~r/cascade_past_only/, fn -> delete_parent!(p1) end

      assert is_nil(archived_at(:cascade_parents, p1))
      assert is_nil(archived_at(:cascade_children, c1))
    end

    test "is one statement of data-modifying CTEs chained through RETURNING" do
      family = family!()

      [delete_function] =
        for %{name: name, up: up} <- ReverseTriggers.build(family.owner),
            name == :strangler_cascade_parents_reverse_delete_function,
            do: up

      assert delete_function == """
             CREATE OR REPLACE FUNCTION "rw_cascade"."strangler_cascade_parents_reverse_delete"() RETURNS trigger AS $strangler$
             DECLARE
               strangler_archived_rows bigint;
             BEGIN
               -- The resource archives, so a destroy is an UPDATE of the archive attribute
               -- (see "DELETE" in the moduledoc), and its archive_related cascade runs in
               -- the same statement. Each CTE stamps the rows related to the rows the CTE
               -- it reads from archived, and only those not archived yet, so the cascade
               -- recurses only from rows this statement archived. The DELETE and its
               -- cascade commit or fail together.
               WITH strangler_archived AS (
                 UPDATE "rw_cascade"."cascade_parents" AS strangler_target
                 SET archived_at = now()
                 WHERE strangler_target.id = OLD.id
                   AND strangler_target.archived_at IS NULL
                 RETURNING strangler_target.id
               ),
               -- archive_related :children
               strangler_cascade_1 AS (
                 UPDATE "rw_cascade"."cascade_children" AS strangler_target
                 SET archived_at = now()
                 WHERE strangler_target.parent_id IN (SELECT strangler_archived.id FROM strangler_archived)
                   AND strangler_target.archived_at IS NULL
                 RETURNING strangler_target.id
               ),
               -- archive_related :grandchildren
               strangler_cascade_1_1 AS (
                 UPDATE "rw_cascade"."cascade_grandchildren" AS strangler_target
                 SET archived_at = now()
                 WHERE strangler_target.child_id IN (SELECT strangler_cascade_1.id FROM strangler_cascade_1)
                   AND strangler_target.archived_at IS NULL
               )
               SELECT count(*) INTO strangler_archived_rows FROM strangler_archived;

               -- Nothing was archived by this statement: the row is gone, was archived
               -- already, or the owned table declined the update. `DELETE 0` says so,
               -- and nothing cascaded.
               IF strangler_archived_rows = 0 THEN
                 RETURN NULL;
               END IF;

               -- OLD, not NULL: NULL would report zero rows for a row that was deleted.
               RETURN OLD;
             END $strangler$ LANGUAGE plpgsql;
             """
    end
  end

  # --- refusals ------------------------------------------------------------------

  describe "an archive_related a trigger cannot follow faithfully is refused at compile time" do
    test "a family the trigger can follow is accepted" do
      assert :ok = verify(family!().owner)
      assert :ok = verify(family!(child_related: [:grandchildren, :toy]).owner)
      assert :ok = verify(family!(owner_relationship: :has_one, owner_related: [:profile]).owner)
    end

    test "only at :read_from_new, where a legacy DELETE reaches the owned table" do
      owner =
        owner!(~s|has_many :toys, #{plain_destination!()}, destination_attribute: :id|, [:toys],
          phase: :dual_write
        )

      assert :ok = verify(owner)
    end

    test "a destination that does not use AshArchival" do
      owner =
        owner!(~s|has_many :toys, #{plain_destination!()}, destination_attribute: :id|, [:toys])

      assert_refused(owner, :toys, "does not use AshArchival.Resource")
    end

    test "a destination whose primary destroy does not archive" do
      dest =
        archival_destination!("cascade_toys",
          archive: "archive do\n  exclude_destroy_actions [:destroy]\nend"
        )

      owner = owner!(~s|has_many :toys, #{dest}, destination_attribute: :id|, [:toys])

      assert_refused(owner, :toys, "exclude_destroy_actions")
    end

    test "a many_to_many relationship" do
      toy = archival_destination!("cascade_toys")

      join =
        define!(
          table: "cascade_parent_toys",
          extensions: "[]",
          body: """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
            attribute :parent_id, :uuid, public?: true
            attribute :toy_id, :uuid, public?: true
          end

          actions do
            defaults [:read, :destroy]
          end
          """
        )

      owner =
        owner!(
          """
          many_to_many :toys, #{toy} do
            through #{join}
            source_attribute_on_join_resource :parent_id
            destination_attribute_on_join_resource :toy_id
          end
          """,
          [:toys]
        )

      assert_refused(owner, :toys, "many_to_many")
    end

    test "a manual relationship" do
      owner =
        owner!(
          """
          has_many :toys, #{archival_destination!("cascade_toys")} do
            manual AshStrangler.CascadeTest.ManualToys
          end
          """,
          [:toys]
        )

      assert_refused(owner, :toys, "manual")
    end

    test "a no_attributes? relationship" do
      owner =
        owner!(
          """
          has_many :toys, #{archival_destination!("cascade_toys")} do
            no_attributes? true
          end
          """,
          [:toys]
        )

      assert_refused(owner, :toys, "no_attributes?")
    end

    test "a relationship with a filter" do
      owner =
        owner!(
          """
          has_many :children, #{family!().child} do
            destination_attribute :parent_id
            filter expr(not is_nil(parent_id))
          end
          """,
          [:children]
        )

      assert_refused(owner, :children, "filter")
    end

    test "a has_one that picks one of many" do
      owner =
        owner!(
          """
          has_one :profile, #{family!().profile} do
            destination_attribute :owner_id
            from_many? true
          end
          """,
          [:profile]
        )

      assert_refused(owner, :profile, "from_many?")
    end

    test "a destination in another repo" do
      dest = archival_destination!("cascade_toys", repo: "AshStrangler.CascadeTest.OtherRepo")
      owner = owner!(~s|has_many :toys, #{dest}, destination_attribute: :id|, [:toys])

      assert_refused(owner, :toys, "AshStrangler.CascadeTest.OtherRepo")
    end

    test "a destination in another data layer" do
      dest =
        define!(
          data_layer: "Ash.DataLayer.Ets",
          postgres: :none,
          body: """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
          end

          actions do
            defaults [:read, :destroy]
          end
          """
        )

      owner = owner!(~s|has_many :toys, #{dest}, destination_attribute: :id|, [:toys])

      assert_refused(owner, :toys, "Ash.DataLayer.Ets")
    end

    test "a destination with :context multitenancy" do
      dest =
        archival_destination!("cascade_toys",
          archive: "multitenancy do\n  strategy :context\nend"
        )

      owner = owner!(~s|has_many :toys, #{dest}, destination_attribute: :id|, [:toys])

      assert_refused(owner, :toys, ":context multitenancy")
    end

    test "a temporal destination, where an archive closes a version" do
      dest =
        archival_destination!("cascade_toys", archive: "temporal do\n  strategy :context\nend")

      owner = owner!(~s|has_many :toys, #{dest}, destination_attribute: :id|, [:toys])

      assert_refused(owner, :toys, "temporal")
    end

    test "archive_related_arguments, which SQL cannot pass" do
      owner =
        owner!(
          """
          has_many :children, #{family!().child} do
            destination_attribute :parent_id
          end
          """,
          [:children],
          archive_extra: "archive_related_arguments fn _arguments, _relationship -> %{} end"
        )

      assert_refused(owner, :children, "archive_related_arguments")
    end

    test "a strangled destination at :read_from_legacy, whose table is a read-only view" do
      dest =
        define!(
          table: "cascade_legacy_users",
          extensions: "[AshStrangler.Resource, AshArchival.Resource]",
          body: """
          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
            attribute :login, :string, public?: true
            attribute :archived_at, :utc_datetime_usec, public?: true
          end

          actions do
            defaults [:read, :destroy]
          end

          strangler do
            phase :read_from_legacy

            source AshStrangler.Test.Legacy.Users do
              key :id, from: :id, strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}
              map :login, from: :login
              map :archived_at, from: :deleted_at, zone: "UTC"
            end
          end
          """
        )

      owner = owner!(~s|has_many :users, #{dest}, destination_attribute: :id|, [:users])

      assert_refused(owner, :users, ":read_from_legacy")
    end

    test "a cycle, refused at the relationship that closes it" do
      # A child's subchildren are children: following them from rows the
      # statement archived would update the same table again, which one
      # statement cannot do, and to an unbounded depth.
      child =
        define!(
          table: "cascade_children",
          body: """
          archive do
            archive_related [:subchildren]
          end

          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false
            attribute :parent_id, :uuid, public?: true
            attribute :archived_at, :utc_datetime_usec, public?: true
          end

          actions do
            defaults [:read, :destroy]
          end

          relationships do
            has_many :subchildren, __MODULE__ do
              destination_attribute :parent_id
            end
          end
          """
        )

      owner =
        owner!(
          """
          has_many :children, #{child} do
            destination_attribute :parent_id
          end
          """,
          [:children]
        )

      message = assert_refused(owner, :subchildren, "cycle")
      assert message =~ inspect(child)
      # Nothing is generated for a cascade the verifier refuses.
      assert_raise ArgumentError, ~r/cycle/, fn -> ReverseTriggers.build(owner) end
    end

    test "a nested level is checked by the same rule, naming the resource that declares it" do
      family = family!(child_related: [:grandchildren, :plain_toys])
      message = assert_refused(family.owner, :plain_toys, "does not use AshArchival.Resource")
      assert message =~ inspect(family.child)
      assert message =~ ":children"
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp verify(owner), do: VerifyArchiveRelated.verify(owner.spark_dsl_config())

  defp assert_refused(owner, relationship, reason) do
    assert {:error, error} = verify(owner)
    message = Exception.message(error)

    assert message =~ inspect(owner)
    assert message =~ inspect(relationship)
    assert message =~ reason
    message
  end

  defp family!(opts \\ []) do
    grandchild =
      archival_destination!("cascade_grandchildren",
        attributes: "attribute :child_id, :uuid, public?: true"
      )

    toy = archival_destination!("cascade_toys")

    profile =
      archival_destination!("cascade_profiles",
        attributes: "attribute :owner_id, :uuid, public?: true"
      )

    plain = plain_destination!()

    child =
      define!(
        table: "cascade_children",
        body: """
        archive do
          archive_related #{inspect(Keyword.get(opts, :child_related, [:grandchildren]))}
        end

        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false
          attribute :parent_id, :uuid, public?: true
          attribute :archived_at, :utc_datetime_usec, public?: true
        end

        actions do
          defaults [:read, :destroy]
        end

        relationships do
          has_many :grandchildren, #{grandchild} do
            destination_attribute :child_id
          end

          belongs_to :toy, #{toy}, public?: true

          has_many :plain_toys, #{plain} do
            destination_attribute :id
          end
        end
        """
      )

    relationship =
      case Keyword.get(opts, :owner_relationship, :has_many) do
        :has_many ->
          """
          has_many :children, #{child} do
            destination_attribute :parent_id
          end
          """

        :has_one ->
          """
          has_one :profile, #{profile} do
            destination_attribute :owner_id
          end
          """
      end

    owner = owner!(relationship, Keyword.get(opts, :owner_related, [:children]))

    %{owner: owner, child: child, grandchild: grandchild, toy: toy, profile: profile}
  end

  # The `:read_from_new` owner of the cascade: an `:identity` key, so the view
  # exposes the owned key itself and no derivation is involved in the tests.
  defp owner!(relationships, archive_related, opts \\ []) do
    define!(
      extensions: "[AshStrangler.Resource, AshArchival.Resource]",
      table: "cascade_parents",
      body: """
      archive do
        archive_related #{inspect(archive_related)}
        #{Keyword.get(opts, :archive_extra, "")}
      end

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false
        attribute :archived_at, :utc_datetime_usec, public?: true
      end

      actions do
        defaults [:read, :destroy]
      end

      relationships do
        #{relationships}
      end

      strangler do
        phase #{inspect(Keyword.get(opts, :phase, :read_from_new))}

        source AshStrangler.CascadeTest.Legacy.Parents do
          key :id, from: :id, strategy: :identity
          map :archived_at, from: :deleted_at, zone: "UTC"
        end
      end
      """
    )
  end

  # A destination the cascade stamps: an ordinary archival Ash resource over
  # one of the setup's tables.
  defp archival_destination!(table, opts \\ []) do
    define!(
      table: table,
      repo: Keyword.get(opts, :repo, "AshStrangler.TestRepo"),
      body: """
      #{Keyword.get(opts, :archive, "")}

      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false
        attribute :archived_at, :utc_datetime_usec, public?: true
        #{Keyword.get(opts, :attributes, "")}
      end

      actions do
        defaults [:read, :destroy]
      end
      """
    )
  end

  # A destination without AshArchival: AshArchival's cascade would destroy it.
  defp plain_destination! do
    define!(
      table: "cascade_toys",
      extensions: "[]",
      body: """
      attributes do
        attribute :id, :uuid, primary_key?: true, allow_nil?: false
      end

      actions do
        defaults [:read, :destroy]
      end
      """
    )
  end

  defp define!(opts) do
    name = "AshStrangler.ArchiveRelatedCascadeTest.Gen#{System.unique_integer([:positive])}"

    postgres =
      if opts[:postgres] == :none do
        ""
      else
        """
        postgres do
          table "#{opts[:table]}"
          schema "rw_cascade"
          repo #{Keyword.get(opts, :repo, "AshStrangler.TestRepo")}
        end
        """
      end

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: #{Keyword.get(opts, :data_layer, "AshPostgres.DataLayer")},
        extensions: #{Keyword.get(opts, :extensions, "[AshArchival.Resource]")}

      #{postgres}
      #{opts[:body]}
    end
    """

    {result, _io} = with_io(:stderr, fn -> Code.eval_string(source) end)
    {{:module, module, _, _}, _binding} = result
    module
  end

  defp install!(resource) do
    for %{up: up} <- ReverseView.build(resource) ++ ReverseTriggers.build(resource),
        do: TestRepo.query!(up, [])
  end

  defp insert_parent!(archived_at \\ nil),
    do: insert!("cascade_parents", archived_at: archived_at)

  defp insert_child!(parent_id, archived_at \\ nil, toy_id \\ nil),
    do:
      insert!("cascade_children", parent_id: parent_id, toy_id: toy_id, archived_at: archived_at)

  defp insert_grandchild!(child_id), do: insert!("cascade_grandchildren", child_id: child_id)

  defp insert_toy!, do: insert!("cascade_toys", [])

  defp insert_profile!(owner_id), do: insert!("cascade_profiles", owner_id: owner_id)

  # Raw SQL, as the legacy application and the setup would write.
  defp insert!(table, columns) do
    id = Ecto.UUID.generate()
    columns = [{:id, id} | columns]
    names = Enum.map_join(columns, ", ", fn {name, _value} -> to_string(name) end)
    placeholders = Enum.map_join(1..length(columns), ", ", &"$#{&1}")

    TestRepo.query!(
      "INSERT INTO rw_cascade.#{table} (#{names}) VALUES (#{placeholders})",
      Enum.map(columns, fn {_name, value} -> dump(value) end)
    )

    id
  end

  defp dump(nil), do: nil
  defp dump(%DateTime{} = value), do: value
  defp dump(uuid) when is_binary(uuid), do: Ecto.UUID.dump!(uuid)

  defp delete_parent!(id) do
    TestRepo.query!("DELETE FROM rw_cascade_legacy.cascade_parents WHERE id = $1", [
      Ecto.UUID.dump!(id)
    ])
  end

  defp archived_at(table, id) do
    %{rows: [[value]]} =
      TestRepo.query!("SELECT archived_at FROM rw_cascade.#{table} WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    value
  end
end
