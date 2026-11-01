# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# The estate fixture: a lending library's legacy schema
# (test/fixtures/snapshot/lending), three twins pinned to its catalog, three
# strangled resources, a plug-in and an estate that accounts for every
# relation and column. Twins first: the resources' verifiers resolve them.

defmodule AshStrangler.Test.Lending.Legacy do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshStrangler.Test.Lending.Legacy.Books do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.Test.Lending.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "books"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/lending/catalog.json"
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :isbn, :string, public?: true
    attribute :branch_id, :integer, allow_nil?: false, public?: true
    attribute :shelf_note, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Lending.Legacy.Members do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.Test.Lending.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "members"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/lending/catalog.json"
    secrets [:pin_hash]
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :email, :string, allow_nil?: false, public?: true
    attribute :full_name, :string, public?: true
    attribute :branch_id, :integer, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Lending.Legacy.Loans do
  @moduledoc false
  use Ash.Resource,
    domain: AshStrangler.Test.Lending.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "loans"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/lending/catalog.json"
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :book_id, :integer, allow_nil?: false, public?: true
    attribute :member_id, :integer, allow_nil?: false, public?: true
    attribute :due_on, :date, allow_nil?: false, public?: true
    attribute :returned_on, :date, public?: true
  end

  relationships do
    belongs_to :book, AshStrangler.Test.Lending.Legacy.Books do
      attribute_type :integer
      define_attribute? false
      attribute_writable? false
    end
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Lending.Book do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "books"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :title, :string, public?: true
    attribute :isbn, :string, public?: true
    attribute :branch_id, :integer, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Lending.Legacy.Books do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6f1d2c3b-8a4e-4c5d-9e7f-0a1b2c3d4e5f"}
      map :title, from: :title
      map :isbn, from: :isbn
      map :branch_id, from: :branch_id
    end
  end
end

defmodule AshStrangler.Test.Lending.Member do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "members"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :string, public?: true
    attribute :full_name, :string, public?: true
    attribute :branch_id, :integer, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Lending.Legacy.Members do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6f1d2c3b-8a4e-4c5d-9e7f-0a1b2c3d4e5f"}
      map :email, from: :email
      map :full_name, from: :full_name
      map :branch_id, from: :branch_id
    end
  end
end

defmodule AshStrangler.Test.Lending.Loan do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "loans"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :book_id, :integer, public?: true
    attribute :member_id, :integer, public?: true
    attribute :due_on, :date, public?: true
    attribute :returned_on, :date, public?: true
    attribute :book_title, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Lending.Legacy.Loans do
      key :id, from: :id, strategy: {:uuid_v5, namespace: "6f1d2c3b-8a4e-4c5d-9e7f-0a1b2c3d4e5f"}
      map :book_id, from: :book_id
      map :member_id, from: :member_id
      map :due_on, from: :due_on
      map :returned_on, from: :returned_on

      map :book_title,
        from: expr(book.title),
        read_only?: true,
        because: "The title belongs to the book row."
    end
  end
end

defmodule AshStrangler.Test.Lending.EstateRules do
  @moduledoc """
  The fixture plug-in: a directory the host projects branches into claims
  their key and name, and a house rule says every deferred target is named
  in the `Lending.` namespace.
  """
  @behaviour AshStrangler.Estate.Plugin

  alias AshStrangler.Estate.Claim

  @impl true
  def claims(_estate, _catalog) do
    for column <- ["id", "name"] do
      %Claim{
        relation: "lending.branches",
        column: column,
        kind: :projected,
        by: "BranchDirectory"
      }
    end
  end

  @impl true
  def check(report) do
    for {_name, %{declared: %{kind: :deferred, target: target}}} <- report.relations,
        not String.starts_with?(target, "Lending."),
        do: "deferred target #{inspect(target)} is outside the Lending namespace"
  end
end

defmodule AshStrangler.Test.Lending.Estate do
  @moduledoc "Every relation and column of the lending catalog, accounted for."
  use AshStrangler.Estate

  estate do
    snapshot "test/fixtures/snapshot/lending/catalog.json"

    resources([
      AshStrangler.Test.Lending.Book,
      AshStrangler.Test.Lending.Member,
      AshStrangler.Test.Lending.Loan
    ])

    plugins([AshStrangler.Test.Lending.EstateRules])

    carried("lending.books.shelf_note", because: "free text the new model does not read")
    dead("lending.branches.fax", because: "no fax machine since 2019")

    deferred("lending.fines",
      wave: :billing,
      target: "Lending.Fine",
      because: "billing moves later"
    )

    legacy_only("lending.sessions", because: "the old application's own sessions")
    dead("lending.fax_log", because: "nothing has written it since 2019")
    residue("lending.old_reservations", because: "dropped by a migration; old restores keep it")

    open_reference("lending.loans.loans_member_id_fkey",
      because: "NOT VALID: old loans name deleted members"
    )
  end
end
