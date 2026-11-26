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
    resource AshStrangler.Test.Facades.MeetingLine
    resource AshStrangler.Test.Facades.Document
    resource AshStrangler.Test.Facades.DocumentView
    resource AshStrangler.Test.Facades.UserContact
    resource AshStrangler.Test.Facades.AnnotatedItem
    resource AshStrangler.Test.Facades.TaggedItem
    resource AshStrangler.Test.Facades.Ticket
    resource AshStrangler.Test.Facades.TicketView
    resource AshStrangler.Test.Facades.Gauge
    resource AshStrangler.Test.Facades.GaugeView
    resource AshStrangler.Test.Facades.Cabinet
    resource AshStrangler.Test.Facades.CabinetView
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

    # An argument copied into a column: the column is not in `accept`, the
    # argument reaches it through `set_attribute`.
    update :annotate do
      accept []

      argument :note, :string, allow_nil?: false

      change set_attribute(:internal_notes, arg(:note))
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

defmodule AshStrangler.Test.Facades.MeetingLine do
  @moduledoc "A facade over the MeetingMinute facade: the temporal source's time reaches it hop by hop."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :heading, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.MeetingMinute

    map :id, from: :id
    map :heading, from: :title
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

defmodule AshStrangler.Test.Facades.AnnotatedItem do
  @moduledoc """
  A facade whose write names a column the source action takes as an argument:
  `annotate` copies its `note` argument into `internal_notes` and accepts
  nothing.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :note, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Task
    read_action :read

    map :id, from: :id
    map :org_id, from: :org_id
    map :note, from: :internal_notes

    hide :name, because: "Not part of this vocabulary."
    hide :status, because: "Not part of this vocabulary."
    hide :estimate_minutes, because: "Not part of this vocabulary."
    hide :legacy_ref, because: "Not part of this vocabulary."

    write(:annotate, via: :annotate, accepts: [:note])
  end
end

defmodule AshStrangler.Test.Facades.Ticket do
  @moduledoc """
  A source with a state machine: `close` moves it with `transition_state`,
  which sets the state attribute to the transition's target.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  ets do
    private? true
  end

  state_machine do
    initial_states [:open]
    default_initial_state :open

    transitions do
      transition :close, from: :open, to: :closed
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:id, :title]
    end

    update :close do
      accept []
      change transition_state(:closed)
    end
  end
end

defmodule AshStrangler.Test.Facades.TicketView do
  @moduledoc "The facade over the state-machine source: its `close` write sets `state` by value."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true

    attribute :phase, :atom,
      public?: true,
      constraints: [one_of: [:new, :done]]
  end

  facade do
    source AshStrangler.Test.Facades.Ticket

    map :id, from: :id
    map :title, from: :title
    decode :phase, from: :state, values: %{open: :new, closed: :done}

    write(:close, via: :close, sets: [phase: :done])
  end
end

defmodule AshStrangler.Test.Facades.Gauge do
  @moduledoc """
  A source for the comparison probes: two measured columns a facade renames,
  a `code` column the facade hides, and an `alias` column.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :alias, :string, public?: true
    attribute :code, :string, public?: true
    attribute :span, :integer, public?: true
    attribute :load, :integer, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:id, :title, :alias, :code, :span, :load]
    end
  end
end

defmodule AshStrangler.Test.Facades.GaugeView do
  @moduledoc """
  The facade over the Gauge: `width` and `height` rename two different source
  columns, and `code` is a facade attribute mapped from `alias`, named like
  the source column the facade hides.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :width, :integer, public?: true
    attribute :height, :integer, public?: true
    attribute :code, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Gauge

    map :id, from: :id
    map :title, from: :title
    map :width, from: :span
    map :height, from: :load
    map :code, from: :alias

    hide :code, because: "The gauge's code is not part of this vocabulary."
  end
end

defmodule AshStrangler.Test.Facades.ByScope do
  @moduledoc "The Cabinet's `:scoped` read preparation: it narrows by the caller's scope."
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    case context.actor do
      %{scope: wanted} -> Ash.Query.filter(query, scope == ^wanted)
      _ -> query
    end
  end
end

defmodule AshStrangler.Test.Facades.Cabinet do
  @moduledoc """
  A source with a second read action, `:scoped`, whose preparation narrows by
  the caller's `scope`: a caller whose scope names nothing reads nothing, and
  a write through the facade must be held to the same reach.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :scope, :string, public?: true
    attribute :count, :integer, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read]

    read :scoped do
      prepare AshStrangler.Test.Facades.ByScope
    end

    create :create do
      accept [:id, :scope, :count, :note]
    end

    update :recount do
      accept [:count, :note]
    end
  end
end

defmodule AshStrangler.Test.Facades.CabinetView do
  @moduledoc "The facade over the Cabinet: it reads through `:scoped`."
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :size, :integer, public?: true
    attribute :note, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Cabinet
    read_action :scoped

    map :id, from: :id
    map :size, from: :count
    map :note, from: :note

    hide :scope, because: "The row's scope is the source's decision."

    write(:set_note, via: :recount, accepts: [:note])
  end
end

defmodule AshStrangler.Test.Facades.TaggedItem do
  @moduledoc """
  A facade with an attribute that has no source attribute: `kind` is a
  constant of this vocabulary, so its value was generated by the mapping and
  not derived from any source value.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Facades,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :org_id, :string, public?: true
    attribute :kind, :string, public?: true
  end

  facade do
    source AshStrangler.Test.Facades.Task
    read_action :read

    map :id, from: :id
    map :org_id, from: :org_id
    constant :kind, expr(type("task", :string))

    hide :name, because: "Not part of this vocabulary."
    hide :status, because: "Not part of this vocabulary."
    hide :estimate_minutes, because: "Not part of this vocabulary."
    hide :internal_notes, because: "Not part of this vocabulary."
    hide :legacy_ref, because: "Not part of this vocabulary."
  end
end
