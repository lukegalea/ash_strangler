# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.WriteSourceNamesTest.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.WriteSourceNamesTest.Loans
    resource AshStrangler.WriteSourceNamesTest.Docs
    resource AshStrangler.WriteSourceNamesTest.Odd
  end
end

defmodule AshStrangler.WriteSourceNamesTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.WriteSourceNamesTest.Loan
    resource AshStrangler.WriteSourceNamesTest.Doc
    resource AshStrangler.WriteSourceNamesTest.LoanLedger
    resource AshStrangler.WriteSourceNamesTest.DocPlain
  end
end

defmodule AshStrangler.WriteSourceNamesTest.Loans do
  @moduledoc """
  A twin whose columns the generator would have written with `source:`: camel
  case, mixed case, and one that holds a double quote. The key column is among
  them.
  """
  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "loans"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :loan_id, :integer, primary_key?: true, allow_nil?: false, source: :loanId
    attribute :effective_date, :date, source: :effectiveDate
    attribute :shelf_mark, :string, source: :"Shelf \"Mark\""
    attribute :first_name, :string, source: :firstName
    attribute :last_name, :string, source: :lastName

    attribute :loan_status, :atom do
      allow_nil? false
      source :Status
      constraints one_of: [:open, :shut]
    end

    attribute :is_deleted, :boolean, allow_nil?: false, source: :IsDeleted
    attribute :cancelled_at, :naive_datetime, source: :cancelledAt
    attribute :approved_at, :naive_datetime, source: :approvedAt
    attribute :nick_name, :string, source: :NickName
    attribute :row_uuid, :uuid, source: :"Row Uuid"
    attribute :title, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.WriteSourceNamesTest.Docs do
  @moduledoc "A twin whose legacy key is already a uuid, in a column that needs quoting."
  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "docs"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :doc_id, :uuid, primary_key?: true, allow_nil?: false, source: :docId
    attribute :doc_title, :string, source: :docTitle
    attribute :note, :string
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.WriteSourceNamesTest.Odd do
  @moduledoc "A twin whose key column holds a double quote and whose other column holds a space."
  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "odd"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    watch "srcnames_odd_watch"
  end

  attributes do
    attribute :order_id, :integer, primary_key?: true, allow_nil?: false, source: :"Order \"Id\""
    attribute :note_text, :string, source: :"Note Text"
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.WriteSourceNamesTest.Loan do
  @moduledoc """
  The resource over `srcnames.loans`. Writes go through generated `INSTEAD OF`
  triggers, because `full_name` writes two legacy columns.
  """
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "loans_view"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :effective_date, :date, public?: true
    attribute :shelf_mark, :string, public?: true
    attribute :title, :string, public?: true
    attribute :full_name, :string, public?: true
    attribute :memo, :string, public?: true, default: ""

    attribute :closed, :integer do
      public? true
      default 0
      constraints min: 0, max: 1
    end

    attribute :lifecycle, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :active, :cancelled, :archived]
    end
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:effective_date, :shelf_mark, :title, :full_name, :memo, :closed, :lifecycle]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.WriteSourceNamesTest.Loans do
      notify? true
      notify_channel "srcnames_loans_notify"

      key :id, from: :loan_id, strategy: {:uuid_v5, namespace: @namespace}

      map :effective_date, from: :effective_date
      map :shelf_mark, from: :shelf_mark
      map :title, from: :title

      concat :full_name, from: [:first_name, :last_name], separator: " "

      # Storage the legacy table has no room for, keyed by the same derived id.
      extension [:memo]

      decode :closed,
        from: :loan_status,
        values: %{open: 0, shut: 1}

      collapse :lifecycle do
        hit_policy :first

        state :archived,
          when: expr(is_deleted),
          set: [is_deleted: true, cancelled_at: nil, approved_at: nil]

        state :cancelled,
          when: expr(not is_nil(cancelled_at)),
          set: [is_deleted: false, cancelled_at: touch(), approved_at: nil]

        state :active,
          when: expr(not is_nil(approved_at)),
          set: [is_deleted: false, cancelled_at: nil, approved_at: touch()]

        state :pending,
          when: :otherwise,
          set: [is_deleted: false, cancelled_at: nil, approved_at: nil]
      end
    end
  end

  def namespace, do: @namespace
end

defmodule AshStrangler.WriteSourceNamesTest.LoanLedger do
  @moduledoc "The change ledger over `srcnames.loans`, whose key column is camel case."

  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "loan_ledger_view"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :title, :string, public?: true
    attribute :effective_date, :date, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.WriteSourceNamesTest.Loans do
      notify? true
      ledger? true
      notify_channel "srcnames_loans_ledger"

      key :id,
        from: :loan_id,
        strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :title, from: :title
      map :effective_date, from: :effective_date
    end
  end
end

defmodule AshStrangler.WriteSourceNamesTest.DocPlain do
  @moduledoc """
  Plain renames only, so the view stays auto-updatable and PostgreSQL itself maps
  each view column onto its base column. No trigger is generated.
  """

  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "docs_plain_view"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0

    attribute :title, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:title, :note]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.WriteSourceNamesTest.Docs do
      key :id, from: :doc_id, strategy: :identity

      map :title, from: :doc_title
      map :note, from: :note
    end
  end
end

defmodule AshStrangler.WriteSourceNamesTest.Doc do
  @moduledoc """
  The resource over `srcnames.docs`, whose legacy key is the canonical id. The
  INSERT trigger passes the host's id into the legacy key column.
  """

  use Ash.Resource,
    domain: AshStrangler.WriteSourceNamesTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "docs_view"
    schema "srcnames"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid,
      primary_key?: true,
      allow_nil?: false,
      default: &Ash.UUID.generate/0

    attribute :title, :string, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:title, :note]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.WriteSourceNamesTest.Docs do
      writes :triggers
      backfill_interlock? true

      key :id, from: :doc_id, strategy: :identity

      map :title, from: :doc_title
      map :note, from: :note
    end
  end
end

defmodule AshStrangler.WriteSourceNamesTest do
  @moduledoc """
  Writes name the legacy column the way reads do: through `Twin.column!/2`, and
  quoted by the printer's identifier rule.

  Everything here is executed. The generated statements are installed verbatim
  over real tables, and INSERT, UPDATE and DELETE go through the view, on the
  key column and on ordinary ones. A write path that spelled the attribute name
  where the column name belongs is a column that does not exist, and it fails
  here rather than on a legacy table with a camel-case column.
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.{
    Backfill,
    Ingester,
    Listener,
    Migration,
    Obligations,
    Observation,
    Reconciler
  }

  alias AshStrangler.Observation.Baseline
  alias AshStrangler.Sql.Printer
  alias AshStrangler.Twin.Fixture
  alias AshStrangler.WriteSourceNamesTest.{Doc, DocPlain, Loan, LoanLedger, Loans, Odd}

  @tables [
    """
    CREATE TABLE srcnames.loans (
      "loanId"          bigserial PRIMARY KEY,
      "effectiveDate"   date,
      "Shelf ""Mark\"""  text,
      "firstName"       text,
      "lastName"        text,
      "Status"          text NOT NULL DEFAULT 'open' CHECK ("Status" IN ('open', 'shut')),
      "IsDeleted"       boolean NOT NULL DEFAULT false,
      "cancelledAt"     timestamp,
      "approvedAt"      timestamp,
      "NickName"        text,
      "Row Uuid"        uuid,
      title             text
    )
    """,
    """
    CREATE TABLE srcnames.docs (
      "docId"    uuid PRIMARY KEY,
      "docTitle" text,
      note       text,
      "_strangler_needs_backfill" boolean NOT NULL DEFAULT true
    )
    """,
    """
    CREATE TABLE srcnames.odd (
      "Order ""Id\""" bigint PRIMARY KEY,
      "Note Text"    text,
      "_strangler_needs_backfill" boolean NOT NULL DEFAULT true
    )
    """
  ]

  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
      TestRepo.query!("DROP SCHEMA IF EXISTS srcnames CASCADE", [])
      TestRepo.query!("CREATE SCHEMA srcnames", [])
      Enum.each(@tables, &TestRepo.query!(&1, []))

      for resource <- [Loan, Doc, DocPlain, LoanLedger, Odd],
          statement <- Migration.statements(resource) do
        TestRepo.query!(statement.up, [])
      end
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!("DROP SCHEMA IF EXISTS srcnames CASCADE", [])
      end)
    end)

    :ok
  end

  defp loan_row(id) do
    %Postgrex.Result{rows: [row], columns: columns} =
      TestRepo.query!(
        """
        SELECT "loanId" AS key, "effectiveDate" AS effective, "Shelf ""Mark\""" AS shelf,
               "firstName" AS first, "lastName" AS last, "Status" AS status,
               "IsDeleted" AS deleted, "cancelledAt" AS cancelled, "approvedAt" AS approved, title
        FROM srcnames.loans WHERE "loanId" = $1
        """,
        [id]
      )

    columns |> Enum.map(&String.to_atom/1) |> Enum.zip(row) |> Map.new()
  end

  defp legacy_id(%{id: id}) do
    %Postgrex.Result{rows: [[legacy_id]]} =
      TestRepo.query!("SELECT __legacy_id FROM srcnames.loans_view WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    legacy_id
  end

  test "the mapping forces triggers, and the key and the columns need quoting" do
    assert AshStrangler.Info.writes(Loan) == :triggers
    assert AshStrangler.Info.writes(Doc) == :triggers
  end

  describe "INSTEAD OF INSERT" do
    test "writes the camel-case, quoted and ordinary columns" do
      loan =
        Ash.create!(Loan, %{
          effective_date: ~D[2026-03-04],
          shelf_mark: "QA 76",
          title: "SICP",
          full_name: "Ada Lovelace",
          closed: 1
        })

      row = loan_row(legacy_id(loan))

      assert row.effective == ~D[2026-03-04]
      assert row.shelf == "QA 76"
      assert row.title == "SICP"
      assert row.first == "Ada"
      assert row.last == "Lovelace"
      assert row.status == "shut"
      assert row.deleted == false
    end

    test "the key column is camel case and still allocated by the legacy side" do
      loan = Ash.create!(Loan, %{title: "keyed"})

      assert is_integer(legacy_id(loan))

      assert loan.id ==
               AshStrangler.KeyDerivation.uuid_v5(
                 Loan.namespace(),
                 AshStrangler.KeyDerivation.name("srcnames.loans", legacy_id(loan))
               )
    end

    test "touch() stamps a camel-case column on insert" do
      loan = Ash.create!(Loan, %{title: "cancelled", lifecycle: :cancelled})

      assert loan_row(legacy_id(loan)).cancelled != nil
    end

    test "an identity key passes the host's id into the quoted key column" do
      doc = Ash.create!(Doc, %{title: "Spec", note: "n"})

      %Postgrex.Result{rows: [[stored, title, note]]} =
        TestRepo.query!(~s(SELECT "docId", "docTitle", note FROM srcnames.docs), [])

      assert Ecto.UUID.load!(stored) == doc.id
      assert {title, note} == {"Spec", "n"}
    end
  end

  describe "INSTEAD OF UPDATE" do
    test "updates by the quoted key and assigns the quoted columns" do
      loan = Ash.create!(Loan, %{title: "before", full_name: "Ada Lovelace"})

      updated =
        loan
        |> Ash.Changeset.for_update(:update, %{
          effective_date: ~D[2027-01-02],
          shelf_mark: "Z 1",
          title: "after",
          full_name: "Grace Hopper",
          closed: 1
        })
        |> Ash.update!()

      assert updated.id == loan.id
      row = loan_row(legacy_id(loan))

      assert row.effective == ~D[2027-01-02]
      assert row.shelf == "Z 1"
      assert row.title == "after"
      assert {row.first, row.last} == {"Grace", "Hopper"}
      assert row.status == "shut"
    end

    test "touch() preserves the stored camel-case column unless the state moved" do
      loan = Ash.create!(Loan, %{title: "t", lifecycle: :cancelled})
      id = legacy_id(loan)
      stamped = loan_row(id).cancelled
      assert stamped != nil

      # An unrelated update re-writes the lifecycle it reads, so the stamp holds.
      loan
      |> Ash.Changeset.for_update(:update, %{title: "t2"})
      |> Ash.update!()

      assert loan_row(id).cancelled == stamped

      loan
      |> Ash.Changeset.for_update(:update, %{lifecycle: :archived})
      |> Ash.update!()

      row = loan_row(id)
      assert row.deleted == true
      assert row.cancelled == nil
    end

    test "an identity-keyed row updates by its quoted key" do
      doc = Ash.create!(Doc, %{title: "v1"})

      doc |> Ash.Changeset.for_update(:update, %{title: "v2", note: "x"}) |> Ash.update!()

      assert %Postgrex.Result{rows: [["v2", "x"]]} =
               TestRepo.query!(~s(SELECT "docTitle", note FROM srcnames.docs), [])
    end
  end

  describe "INSTEAD OF DELETE" do
    test "deletes by the quoted key" do
      loan = Ash.create!(Loan, %{title: "gone"})
      id = legacy_id(loan)

      assert :ok == Ash.destroy!(loan)

      assert %Postgrex.Result{rows: []} =
               TestRepo.query!(~s(SELECT 1 FROM srcnames.loans WHERE "loanId" = $1), [id])
    end

    test "deletes an identity-keyed row" do
      doc = Ash.create!(Doc, %{title: "gone"})
      assert :ok == Ash.destroy!(doc)
      assert %Postgrex.Result{rows: []} = TestRepo.query!("SELECT 1 FROM srcnames.docs", [])
    end
  end

  describe "straight SQL through the view" do
    test "INSERT, UPDATE and DELETE reach the legacy table" do
      %Postgrex.Result{rows: [[id]]} =
        TestRepo.query!(
          """
          INSERT INTO srcnames.loans_view (effective_date, shelf_mark, title, full_name, closed, lifecycle)
          VALUES ('2026-05-06', 'S 1', 'raw', 'Alan Turing', 0, 'pending')
          RETURNING __legacy_id
          """,
          []
        )

      assert loan_row(id).title == "raw"

      TestRepo.query!(
        "UPDATE srcnames.loans_view SET title = 'raw2', full_name = 'A B' WHERE __legacy_id = $1",
        [id]
      )

      row = loan_row(id)
      assert {row.title, row.first, row.last} == {"raw2", "A", "B"}

      TestRepo.query!("DELETE FROM srcnames.loans_view WHERE __legacy_id = $1", [id])

      assert %Postgrex.Result{rows: []} =
               TestRepo.query!(~s(SELECT 1 FROM srcnames.loans WHERE "loanId" = $1), [id])
    end
  end

  describe "the auto-updatable path" do
    test "needs no trigger, and the view maps onto the quoted base columns" do
      assert AshStrangler.Info.writes(DocPlain) == :auto

      names = DocPlain |> Migration.statements() |> Enum.map(&to_string(&1.name))
      refute Enum.any?(names, &(&1 =~ ~r/_(insert|update|delete)_/)), inspect(names)

      doc = Ash.create!(DocPlain, %{title: "plain", note: "n"})

      assert %Postgrex.Result{rows: [["plain", "n"]]} =
               TestRepo.query!(
                 ~s|SELECT "docTitle", note FROM srcnames.docs WHERE "docId" = $1|,
                 [
                   Ecto.UUID.dump!(doc.id)
                 ]
               )

      doc |> Ash.Changeset.for_update(:update, %{title: "plain2"}) |> Ash.update!()

      assert %Postgrex.Result{rows: [["plain2"]]} =
               TestRepo.query!(~s|SELECT "docTitle" FROM srcnames.docs|, [])

      Ash.destroy!(doc)
      assert %Postgrex.Result{rows: []} = TestRepo.query!("SELECT 1 FROM srcnames.docs", [])
    end
  end

  describe "the extension table" do
    test "is keyed from the stored row's camel-case key, and follows the row" do
      loan = Ash.create!(Loan, %{title: "ext", memo: "first"})
      relation = AshStrangler.Sql.Extension.relation(Loan)

      assert %Postgrex.Result{rows: [[id, "first"]]} =
               TestRepo.query!("SELECT id, memo FROM #{relation}", [])

      assert Ecto.UUID.load!(id) == loan.id

      loan |> Ash.Changeset.for_update(:update, %{memo: "second"}) |> Ash.update!()

      assert %Postgrex.Result{rows: [[_, "second"]]} =
               TestRepo.query!("SELECT id, memo FROM #{relation}", [])

      Ash.destroy!(loan)
      assert %Postgrex.Result{rows: []} = TestRepo.query!("SELECT id FROM #{relation}", [])
    end
  end

  describe "the printer" do
    test "a hold names the stored column the way the table spells it" do
      hold = %Ash.Query.Call{
        name: :strangler_hold,
        args: ["effectiveDate", nil],
        operator?: false,
        relationship_path: []
      }

      assert Printer.to_sql(hold,
               ref: Printer.new_frame(),
               touch: {:preserve, fn _ -> "OLD.x" end}
             ) ==
               ~s("effectiveDate")

      assert Printer.to_sql(hold, ref: Printer.new_frame(), touch: :now) == "NULL"
    end

    test "column/2 resolves through the twin and quotes only what needs it" do
      assert Printer.column(Loans, :loan_id) == ~s("loanId")
      assert Printer.column(Loans, :title) == "title"
      assert Printer.column(Loans, :shelf_mark) == ~s("Shelf ""Mark""")
    end
  end

  describe "the interlock" do
    test "an identity-keyed write clears the backfill flag, which the batch statement reads" do
      Ash.create!(Doc, %{title: "interlocked"})

      assert %Postgrex.Result{rows: [[false]]} =
               TestRepo.query!(~s(SELECT "_strangler_needs_backfill" FROM srcnames.docs), [])
    end
  end

  describe "the backfill" do
    test "a plan names the key column as the table spells it, and runs over it" do
      id =
        TestRepo.query!(
          ~s|INSERT INTO srcnames.loans (title) VALUES ('b') RETURNING "loanId"|,
          []
        )

      [[loan_id]] = id.rows

      Backfill.add_flag_column!(TestRepo, "srcnames.loans")

      plan = Backfill.plan(Loan, store_key: "Row Uuid")
      assert plan[:key] == "loanId"
      assert plan[:relation] == "srcnames.loans"

      assert {:ok, %{rows: 1, complete?: true}} = Backfill.run(TestRepo, plan)

      assert %Postgrex.Result{rows: [[stored]]} =
               TestRepo.query!(~s(SELECT "Row Uuid" FROM srcnames.loans WHERE "loanId" = $1), [
                 loan_id
               ])

      assert Ecto.UUID.load!(stored) ==
               AshStrangler.KeyDerivation.uuid_v5(
                 Loan.namespace(),
                 AshStrangler.KeyDerivation.name("srcnames.loans", loan_id)
               )
    end

    test "a column that is not a plain identifier is quoted, not refused" do
      TestRepo.query!(
        ~s|INSERT INTO srcnames.odd ("Order ""Id""", "Note Text") VALUES (1, 'a'), (2, 'b')|,
        []
      )

      assert {:ok, %{rows: 2, complete?: true}} =
               Backfill.run(TestRepo,
                 relation: "srcnames.odd",
                 key: ~s(Order "Id"),
                 set: [{"Note Text", "upper(\"Note Text\")"}]
               )

      assert %Postgrex.Result{rows: [["A"], ["B"]]} =
               TestRepo.query!(
                 ~s(SELECT "Note Text" FROM srcnames.odd ORDER BY "Order ""Id"""),
                 []
               )
    end
  end

  describe "the reconciler" do
    test "lines the view up with the legacy table on the quoted key" do
      Ash.create!(Loan, %{title: "r1", full_name: "Ada Lovelace", effective_date: ~D[2026-01-01]})
      Ash.create!(Loan, %{title: "r2", full_name: "Grace Hopper"})

      assert %{agrees?: true, counts: %{legacy: 2, view: 2}} = Reconciler.diff(Loan)
      assert Reconciler.plan(Loan)[:legacy][:key] == ~s("loanId")
    end
  end

  describe "the fixture writer" do
    test "inserts into columns that need quoting" do
      row =
        Fixture.insert!(Loans, %{
          effective_date: ~D[2026-02-03],
          shelf_mark: "QA",
          nick_name: "nn",
          loan_status: :open,
          is_deleted: false
        })

      assert row.shelf_mark == "QA"
      assert row.effective_date == ~D[2026-02-03]
    end
  end

  describe "the assertions measured against data" do
    test "run against the real table, whatever the columns are called" do
      assertions = Obligations.assertions(Loan)
      assert assertions != []

      for %{assertion: sql} <- assertions do
        assert %Postgrex.Result{} = TestRepo.query!(sql, [])
      end
    end
  end

  describe "the ingester" do
    test "locates the payload by the column's real name" do
      {:ok, ctx} = Ingester.context(LoanLedger, MyApp.Ledger)

      assert ctx.key_column == "loanId"
      assert Ingester.render_ingestion(ctx) =~ ~s(%{"loanId" => legacy_key})

      assert {:ok, _quoted} = Code.string_to_quoted(Ingester.render_ingestion(ctx))
    end
  end

  describe "the baseline" do
    test "pages through the legacy table on the quoted key" do
      for n <- 1..3,
          do: TestRepo.query!("INSERT INTO srcnames.loans (title) VALUES ($1)", ["base-#{n}"])

      assert {:ok, %{count: 3}} =
               Baseline.run(LoanLedger, repo: TestRepo, isolation: :caller)

      assert %Postgrex.Result{rows: [[3]]} =
               TestRepo.query!(
                 "SELECT count(*) FROM strangler_observations WHERE resource = $1 AND category = 'baseline'",
                 [to_string(LoanLedger)]
               )
    end
  end

  describe "the observation projector" do
    test "reads the key out of an image keyed by the column's real name" do
      row = %{"loanId" => 41, "effectiveDate" => "2026-01-02", "title" => "t"}

      assert %{record_id: record_id} = Observation.evaluate_row(LoanLedger, row, TestRepo)

      assert record_id ==
               AshStrangler.KeyDerivation.uuid_v5(
                 "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71",
                 AshStrangler.KeyDerivation.name("srcnames.loans", 41)
               )
    end
  end

  describe "committed legacy writes" do
    # NOTIFY fires on commit, so these use their own connection, outside the sandbox.
    setup do
      config = Listener.connection_opts(TestRepo)
      {:ok, conn} = Postgrex.start_link(config)
      {:ok, notifications} = Postgrex.Notifications.start_link(config)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
          TestRepo.query!("DELETE FROM srcnames.loans WHERE title LIKE 'committed-%'", [])
          TestRepo.query!("DELETE FROM srcnames.odd", [])
          TestRepo.query!("DELETE FROM legacy_change_events WHERE source_schema = 'srcnames'", [])
        end)
      end)

      %{conn: conn, notifications: notifications}
    end

    @tag :integration
    test "the notify trigger reads the camel-case key", %{conn: conn, notifications: n} do
      {:ok, _ref} = Postgrex.Notifications.listen(n, "srcnames_loans_notify")

      %Postgrex.Result{rows: [[legacy_id]]} =
        Postgrex.query!(
          conn,
          ~s|INSERT INTO srcnames.loans (title) VALUES ('committed-notify') RETURNING "loanId"|,
          []
        )

      assert_receive {:notification, _pid, _ref, _channel, payload}, 5_000
      assert {:ok, %{legacy_id: ^legacy_id, op: :insert}} = Listener.decode(payload)
    end

    @tag :integration
    test "the ledger records the key under the column's name", %{conn: conn, notifications: n} do
      {:ok, _ref} = Postgrex.Notifications.listen(n, "srcnames_loans_ledger")

      %Postgrex.Result{rows: [[legacy_id]]} =
        Postgrex.query!(
          conn,
          ~s|INSERT INTO srcnames.loans (title) VALUES ('committed-ledger') RETURNING "loanId"|,
          []
        )

      assert_receive {:notification, _pid, _ref, _channel, payload}, 5_000
      assert {:ok, %{wake: event_id}} = Listener.decode(payload)

      assert %Postgrex.Result{rows: [[primary_key, new_row]]} =
               Postgrex.query!(
                 conn,
                 "SELECT primary_key, new_row FROM legacy_change_events WHERE id = $1",
                 [event_id]
               )

      assert primary_key == %{"loanId" => legacy_id}
      assert new_row["title"] == "committed-ledger"
    end

    @tag :integration
    test "the watch trigger carries a key column that holds a quote", %{
      conn: conn,
      notifications: n
    } do
      {:ok, _ref} = Postgrex.Notifications.listen(n, "srcnames_odd_watch")

      Postgrex.query!(
        conn,
        ~s|INSERT INTO srcnames.odd ("Order ""Id""", "Note Text") VALUES (7, 'x')|,
        []
      )

      assert_receive {:notification, _pid, _ref, _channel, payload}, 5_000
      assert %{"key" => %{~s(Order "Id") => 7}, "op" => "insert"} = JSON.decode!(payload)
    end
  end
end
