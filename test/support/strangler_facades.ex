# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Facades do
  @moduledoc """
  The facade fixtures: a Task source with policies and attribute multitenancy,
  a Credential source whose number is hidden behind a field policy, a temporal
  Meeting source, an owned Postgres-backed Document, and one facade over each —
  plus a facade over a facade, and one over a strangled resource.

  All ETS-backed except the Document, whose data layer only names a dataset:
  a hop chain reads declarations and repo configuration, never rows.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    # `allow_unregistered?` because the policy-filter probes below compile a
    # facade at test time; nothing else reads through this domain unlisted.
    allow_unregistered? true

    resource AshStrangler.Test.Facades.Task
    resource AshStrangler.Test.Facades.WorkItem
    resource AshStrangler.Test.Facades.WorkItemRow
    resource AshStrangler.Test.Facades.Credential
    resource AshStrangler.Test.Facades.CredentialCard
    resource AshStrangler.Test.Facades.Meeting
    resource AshStrangler.Test.Facades.MeetingMinute
    resource AshStrangler.Test.Facades.Document
    resource AshStrangler.Test.Facades.DocumentView
    resource AshStrangler.Test.Facades.UserContact
  end
end

defmodule AshStrangler.Test.Facades.SystemActor do
  @moduledoc "The fixtures' system actor check: the actor `%{system?: true}`."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the system actor"

  @impl true
  def match?(%{system?: true}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end

defmodule AshStrangler.Test.Facades.HasCredentialAccess do
  @moduledoc "The field-policy check behind the Credential's number: `%{credential_access?: true}`."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor holds credential access"

  @impl true
  def match?(%{credential_access?: true}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end

defmodule AshStrangler.Test.Facades.Task do
  @moduledoc """
  The row source for the WorkItem facade: ETS, attribute multitenancy on an
  `org_id` (`global? true` — a tenant-less read is legal at the source, which
  is exactly why the facade has to refuse it), a policy that lets a member
  read only their own organisation's rows, a guarded `:complete`, and an
  accepting `:set_estimate`.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? true
  end

  multitenancy do
    strategy :attribute
    global? true
    attribute :org_id
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:open, :done, :cancelled]]

    attribute :estimate_minutes, :integer, public?: true
    attribute :internal_notes, :string, public?: true
    attribute :legacy_ref, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:id, :org_id, :name, :status, :estimate_minutes, :internal_notes, :legacy_ref]
    end

    update :complete do
      accept []
      # `after_action` wraps an arbitrary function, which cannot be atomic.
      require_atomic? false

      validate attribute_equals(:status, :open),
        message: "only an open task can be completed"

      change set_attribute(:status, :done)

      # The one-action-per-write counter: a write test sends this to its own
      # process and refuses a second message.
      change after_action(fn _changeset, result, _context ->
               send(self(), {:source_action, :complete})
               {:ok, result}
             end)
    end

    update :set_estimate do
      accept [:estimate_minutes]
    end
  end

  policies do
    bypass always() do
      authorize_if AshStrangler.Test.Facades.SystemActor
    end

    policy always() do
      description "a member reads and updates the rows of their own organisation"
      authorize_if expr(org_id == ^actor(:org_id))
    end
  end
end

defmodule AshStrangler.Test.Facades.WorkItem do
  @moduledoc """
  The facade over the Task: rename, decode, hidden and deferred attributes,
  and one write by value and one by acceptance.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :title, :string, public?: true

    attribute :state, :atom,
      public?: true,
      constraints: [one_of: [:new, :finished, :cancelled]]

    attribute :effort_minutes, :integer, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Task
    read_action :read

    map :id, from: :id
    map :org_id, from: :org_id
    map :title, from: :name

    decode :state, from: :status, values: %{open: :new, done: :finished, cancelled: :cancelled}

    map :effort_minutes, from: :estimate_minutes

    hide :internal_notes, because: "Not part of this vocabulary."
    defer :legacy_ref

    write(:finish, via: :complete, sets: [state: :finished])
    write(:set_estimate, via: :set_estimate, accepts: [:effort_minutes])
  end
end

defmodule AshStrangler.Test.Facades.WorkItemRow do
  @moduledoc "A facade over the WorkItem facade: the chain reads hop by hop."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.WorkItem

    map :id, from: :id
    map :label, from: :title

    hide :org_id, because: "The row's organisation is decided one hop up."
    hide :state, because: "This view of the work shows only its label."
    defer :effort_minutes
  end
end

defmodule AshStrangler.Test.Facades.Credential do
  @moduledoc """
  The Credential source: its `number` is sensitive and hidden behind a field
  policy from readers without the flag on their actor.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? true
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :holder, :string, public?: true
    attribute :number, :string, sensitive?: true, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:id, :holder, :number]
    end
  end

  field_policies do
    field_policy :number do
      authorize_if AshStrangler.Test.Facades.HasCredentialAccess
    end

    field_policy :* do
      authorize_if always()
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end

defmodule AshStrangler.Test.Facades.CredentialCard do
  @moduledoc "The facade over the Credential: the number is inherited sensitive."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :holder, :string, public?: true
    attribute :number, :string, public?: true, sensitive?: true
    attribute :display, :string, public?: true, sensitive?: true
  end

  facade do
    source AshStrangler.Test.Facades.Credential

    map :id, from: :id
    map :holder, from: :holder
    map :number, from: :number

    concat :display,
      from: [:holder, :number],
      read_only?: true,
      because: "A display string cannot be split back into a holder and a number."
  end
end

defmodule AshStrangler.Test.Facades.Meeting do
  @moduledoc "The temporal source: every read is a point in time."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  temporal do
    strategy :context
    attribute :valid_at
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:title]
    end

    update :update do
      accept [:title]
    end
  end
end

defmodule AshStrangler.Test.Facades.MeetingMinute do
  @moduledoc "The facade over the temporal Meeting: `as_of` forwards."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Meeting

    map :id, from: :id
    map :title, from: :title

    defer :valid_at

    write(:retitle, via: :update, accepts: [:title])
  end
end

defmodule AshStrangler.Test.Facades.Document do
  @moduledoc "An owned source on the test repo, so a hop can name a dataset."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "facade_documents"
    schema "verified"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Facades.DocumentView do
  @moduledoc "The facade over the owned Document."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Document

    map :id, from: :id
    map :title, from: :title
  end
end

defmodule AshStrangler.Test.Facades.UserContact do
  @moduledoc "A facade over a strangled resource: the chain continues into the twin."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :email, :ci_string, public?: true
  end

  facade do
    source AshStrangler.Test.LegacyUser

    map :id, from: :id
    map :email, from: :email

    hide :login, because: "The login is not part of a contact card."
    hide :full_name, because: "This card shows the address only."
    hide :archived_at, because: "Archival is decided by the source."
    hide :organization_id, because: "Organisation placement is decided one hop up."
    defer :created_by_id
  end
end
