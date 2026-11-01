# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Library.Keys do
  @moduledoc """
  The packed key kinds of the lending-library fixture
  (`test/fixtures/snapshot/library`): one kind per keyed relation, covering
  16-, 32- and 64-bit parts and a composite key.
  """

  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x4C42
    snapshot "test/fixtures/snapshot/library/catalog.json"
    reserved [0x0FF]

    kind :branch, 0x001, parts: [{"library.branches.id", 16}]
    kind :member, 0x002, parts: [{"library.members.id", 32}]
    kind :copy, 0x003, parts: [{"library.copies.branch_id", 16}, {"library.copies.copy_no", 64}]
    kind :loan, 0x004, parts: [{"library.loans.id", 64}]
  end
end

defmodule AshStrangler.Test.Library.SystemActor do
  @moduledoc "The fixture's system actor check: the actor `%{system?: true}`."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the system actor"

  @impl true
  def match?(%{system?: true}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end

defmodule AshStrangler.Test.Library.Legacy do
  @moduledoc "Twins of the lending-library fixture, pinned to its snapshot."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Test.Library.Legacy.Branches
    resource AshStrangler.Test.Library.Legacy.Members
    resource AshStrangler.Test.Library.Legacy.Copies
    resource AshStrangler.Test.Library.Legacy.Loans
    resource AshStrangler.Test.Library.Legacy.Cards
  end
end

defmodule AshStrangler.Test.Library.Legacy.Branches do
  @moduledoc "Twin for `library.branches`."
  use Ash.Resource,
    domain: AshStrangler.Test.Library.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "branches"
    schema "library"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/library/catalog.json"
    system_actor AshStrangler.Test.Library.SystemActor
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Library.Legacy.Members do
  @moduledoc "Twin for `library.members`."
  use Ash.Resource,
    domain: AshStrangler.Test.Library.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "members"
    schema "library"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/library/catalog.json"
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :home_branch_id, :integer, allow_nil?: false, public?: true
    attribute :referrer_id, :integer, public?: true
    attribute :email, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Library.Legacy.Copies do
  @moduledoc "Twin for `library.copies`, keyed by `(branch_id, copy_no)`."
  use Ash.Resource,
    domain: AshStrangler.Test.Library.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "copies"
    schema "library"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/library/catalog.json"
  end

  attributes do
    attribute :branch_id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :copy_no, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Library.Legacy.Loans do
  @moduledoc "Twin for `library.loans`."
  use Ash.Resource,
    domain: AshStrangler.Test.Library.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "loans"
    schema "library"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/library/catalog.json"
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :member_id, :integer, allow_nil?: false, public?: true
    attribute :branch_id, :integer, allow_nil?: false, public?: true
    attribute :copy_no, :integer, allow_nil?: false, public?: true
    attribute :due_on, :date, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Library.Legacy.Cards do
  @moduledoc "Twin for `library.cards`, keyed by a legacy uuid."
  use Ash.Resource,
    domain: AshStrangler.Test.Library.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "cards"
    schema "library"
    repo AshStrangler.TestRepo
    migrate? false
  end

  twin do
    snapshot "test/fixtures/snapshot/library/catalog.json"
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :member_id, :integer, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Library do
  @moduledoc "The canonical lending resources, each mapped onto a library twin."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshStrangler.Test.Library.Member
    resource AshStrangler.Test.Library.Copy
    resource AshStrangler.Test.Library.Loan
    resource AshStrangler.Test.Library.Card
  end
end

defmodule AshStrangler.Test.Library.Member do
  @moduledoc """
  A 32-bit packed key, a closed reference (`home_branch_id`, backed by a
  validated foreign key) and a soft one (`referred_by_id`, whose foreign key
  is `NOT VALID`).
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "members"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :string, public?: true
    attribute :home_branch_id, :uuid, public?: true
    attribute :referred_by_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Library.Legacy.Members do
      key :id, from: :id, strategy: {:uuid_v8, AshStrangler.Test.Library.Keys, :member}
      map :email, from: :email

      reference :home_branch_id,
        kind: {AshStrangler.Test.Library.Keys, :branch},
        from: :home_branch_id

      reference :referred_by_id,
        kind: {AshStrangler.Test.Library.Keys, :member},
        from: :referrer_id,
        soft: "The referrer foreign key was added NOT VALID over rows that predate it."
    end
  end
end

defmodule AshStrangler.Test.Library.Copy do
  @moduledoc "A composite packed key: `(branch_id smallint, copy_no bigint)`."
  use Ash.Resource,
    domain: AshStrangler.Test.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "copies"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :title, :string, public?: true
    attribute :branch_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Library.Legacy.Copies do
      key :id,
        from: [:branch_id, :copy_no],
        strategy: {:uuid_v8, AshStrangler.Test.Library.Keys, :copy}

      map :title, from: :title
      reference :branch_id, kind: {AshStrangler.Test.Library.Keys, :branch}, from: :branch_id
    end
  end
end

defmodule AshStrangler.Test.Library.Loan do
  @moduledoc """
  A 64-bit packed key in `:dual_write`, with a single-column and a composite
  reference that are written back through the `INSTEAD OF` triggers.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "loans"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :member_id, :uuid, public?: true
    attribute :copy_id, :uuid, public?: true
    attribute :due_on, :date, public?: true
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:member_id, :copy_id, :due_on]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Library.Legacy.Loans do
      key :id, from: :id, strategy: {:uuid_v8, AshStrangler.Test.Library.Keys, :loan}
      reference :member_id, kind: {AshStrangler.Test.Library.Keys, :member}, from: :member_id

      reference :copy_id,
        kind: {AshStrangler.Test.Library.Keys, :copy},
        from: [:branch_id, :copy_no]

      map :due_on, from: :due_on
    end
  end
end

defmodule AshStrangler.Test.Library.Card do
  @moduledoc "An `:identity` key over a legacy uuid, on a pinned twin."
  use Ash.Resource,
    domain: AshStrangler.Test.Library,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "cards"
    schema "lending"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :member_id, :uuid, public?: true
  end

  actions do
    defaults [:read]
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Library.Legacy.Cards do
      key :id, from: :id, strategy: :identity
      reference :member_id, kind: {AshStrangler.Test.Library.Keys, :member}, from: :member_id
    end
  end
end
