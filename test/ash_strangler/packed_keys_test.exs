# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.PackedKeysTest do
  @moduledoc """
  Packed keys and references on real PostgreSQL, over the lending-library
  fixture loaded from its snapshot SQL and written through twin fixture
  writers:

    * a view's id is the registry's `encode/3` of the legacy key, for 16-, 32-
      and 64-bit parts and a composite key;
    * a reference equals the id of the row it names, so it joins without a
      lookup table;
    * a lookup by id can use the expression index;
    * a reference is written back as the legacy integers it packs, and an id
      of another kind is refused rather than stored as a wrong integer;
    * a soft reference's dangling rows are counted by its `check` assertion;
    * a twin with `system_actor` reads for that actor only.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.{KeyKinds, Obligations}
  alias AshStrangler.Test.Library.{Card, Copy, Keys, Loan, Member}
  alias AshStrangler.Test.Library.Legacy
  alias AshStrangler.Twin.Fixture

  @schema_sql "test/fixtures/snapshot/library/schema.sql"

  setup do
    TestRepo.query!("DROP SCHEMA IF EXISTS library CASCADE", [])
    TestRepo.query!("DROP SCHEMA IF EXISTS lending CASCADE", [])

    @schema_sql
    |> File.read!()
    |> String.split(~r/;\s*\n/)
    |> Enum.map(fn statement ->
      statement
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "--"))
      |> Enum.join("\n")
    end)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.each(&TestRepo.query!(&1, []))

    TestRepo.query!("CREATE SCHEMA lending", [])

    for resource <- [Member, Copy, Loan, Card],
        statement <- AshStrangler.Migration.statements(resource) do
      TestRepo.query!(statement.up, [])
    end

    branch = Fixture.insert!(Legacy.Branches, %{id: -3, name: "North"})

    member =
      Fixture.insert!(Legacy.Members, %{home_branch_id: branch.id, email: "a@example.com"})

    copy =
      Fixture.insert!(Legacy.Copies, %{
        branch_id: branch.id,
        copy_no: 9_000_000_000,
        title: "Ulysses"
      })

    %{branch: branch, member: member, copy: copy}
  end

  defp id(kind, parts), do: KeyKinds.encode(Keys, kind, parts)

  describe "fixture writers" do
    test "insert! returns the row as the database wrote it", %{member: member} do
      assert is_integer(member.id)
      assert member.email == "a@example.com"
      assert member.referrer_id == nil
    end

    test "insert_all! writes rows in bulk under the database's constraints", %{branch: branch} do
      rows = for n <- 1..2_000, do: %{branch_id: branch.id, copy_no: n, title: "Copy #{n}"}
      assert Fixture.insert_all!(Legacy.Copies, rows) == 2_000

      assert_raise Postgrex.Error, ~r/foreign key/, fn ->
        Fixture.insert_all!(Legacy.Copies, [%{branch_id: 999, copy_no: 1, title: "x"}])
      end
    end

    test "a column the twin does not declare is refused" do
      assert_raise ArgumentError, ~r/no attribute :password/, fn ->
        Fixture.insert!(Legacy.Branches, %{id: 1, name: "x", password: "y"})
      end
    end
  end

  describe "packed keys through the view" do
    test "the id is the registry's encoding of the legacy key", %{member: member, branch: branch} do
      [read] = Ash.read!(Member)

      assert read.id == id(:member, [member.id])
      assert read.home_branch_id == id(:branch, [branch.id])
      assert read.referred_by_id == nil
      assert KeyKinds.decode(Keys, read.id) == {:ok, {:member, [member.id]}}
    end

    test "a composite key packs both columns", %{copy: copy, branch: branch} do
      [read] = Ash.read!(Copy)

      assert read.id == id(:copy, [branch.id, copy.copy_no])
      assert read.branch_id == id(:branch, [branch.id])
      assert Ash.get!(Copy, read.id).title == "Ulysses"
    end

    test "an :identity key passes the legacy uuid through", %{member: member} do
      card = Fixture.insert!(Legacy.Cards, %{id: Ash.UUID.generate(), member_id: member.id})
      [read] = Ash.read!(Card)

      assert read.id == card.id
      assert read.member_id == id(:member, [member.id])
    end

    test "a reference equals the id of the row it names", %{member: member, copy: copy} do
      loan =
        Fixture.insert!(Legacy.Loans, %{
          member_id: member.id,
          branch_id: copy.branch_id,
          copy_no: copy.copy_no
        })

      read = Ash.get!(Loan, id(:loan, [loan.id]))

      assert Ash.get!(Member, read.member_id).email == "a@example.com"
      assert Ash.get!(Copy, read.copy_id).title == "Ulysses"
    end

    test "a lookup by id can use the expression index", %{branch: branch} do
      rows = for n <- 1..300, do: %{home_branch_id: branch.id, email: "m#{n}@example.com"}
      Fixture.insert_all!(Legacy.Members, rows)
      TestRepo.query!("ANALYZE library.members", [])
      TestRepo.query!("SET LOCAL enable_seqscan = off", [])

      %{rows: plan} =
        TestRepo.query!("EXPLAIN SELECT * FROM lending.members WHERE id = $1", [
          Ecto.UUID.dump!(id(:member, [42]))
        ])

      plan = plan |> List.flatten() |> Enum.join("\n")
      assert plan =~ "strangler_members_key_idx", "expected the key index, got:\n#{plan}"
    end
  end

  describe "writing a reference" do
    test "stores the legacy integers the id packs", %{member: member, copy: copy, branch: branch} do
      other =
        Fixture.insert!(Legacy.Members, %{home_branch_id: branch.id, email: "b@example.com"})

      loan =
        Loan
        |> Ash.Changeset.for_create(:create, %{
          member_id: id(:member, [member.id]),
          copy_id: id(:copy, [copy.branch_id, copy.copy_no]),
          due_on: ~D[2026-12-01]
        })
        |> Ash.create!()

      {:ok, [legacy_id]} = KeyKinds.decode(Keys, :loan, loan.id)

      assert %{rows: [[member_id, branch_id, copy_no]]} =
               TestRepo.query!(
                 "SELECT member_id, branch_id, copy_no FROM library.loans WHERE id = $1",
                 [legacy_id]
               )

      assert {member_id, branch_id, copy_no} == {member.id, copy.branch_id, copy.copy_no}

      loan
      |> Ash.Changeset.for_update(:update, %{member_id: id(:member, [other.id])})
      |> Ash.update!()

      assert %{rows: [[other_id]]} =
               TestRepo.query!("SELECT member_id FROM library.loans WHERE id = $1", [legacy_id])

      assert other_id == other.id
    end

    test "refuses an id of another kind", %{copy: copy, branch: branch} do
      changeset =
        Ash.Changeset.for_create(Loan, :create, %{
          member_id: id(:branch, [branch.id]),
          copy_id: id(:copy, [copy.branch_id, copy.copy_no])
        })

      assert {:error, error} = Ash.create(changeset)
      assert Exception.message(error) =~ "not a key of this kind"
    end
  end

  describe "soft references" do
    test "become a dangling-row assertion for check", %{member: member, branch: branch} do
      [finding] = Obligations.assertions(Member)

      assert finding.obligation == :reference_closure
      assert finding.attribute == :referred_by_id

      Fixture.insert!(Legacy.Members, %{
        home_branch_id: branch.id,
        email: "c@example.com",
        referrer_id: member.id
      })

      assert %{rows: [[0]]} = TestRepo.query!(finding.assertion, [])

      # The NOT VALID foreign key is what makes the reference soft: rows
      # written while it was missing can dangle.
      TestRepo.query!("ALTER TABLE library.members DROP CONSTRAINT members_referrer_id_fkey", [])

      Fixture.insert!(Legacy.Members, %{
        home_branch_id: branch.id,
        email: "d@example.com",
        referrer_id: 999_999
      })

      assert %{rows: [[1]]} = TestRepo.query!(finding.assertion, [])
    end
  end

  describe "twin authorizer" do
    test "only the system actor reads a twin with system_actor", %{branch: branch} do
      assert [%{id: id}] = Ash.read!(Legacy.Branches, actor: %{system?: true})
      assert id == branch.id

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(Legacy.Branches, actor: %{system?: false})

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Legacy.Branches)
      assert [_] = Ash.read!(Legacy.Branches, authorize?: false)
    end
  end
end
