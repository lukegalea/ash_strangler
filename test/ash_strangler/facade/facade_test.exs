# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.FacadeTest do
  @moduledoc """
  A facade reads as its caller and writes through one source action.

  These tests are the ADR's behaviour, not its implementation: the source's
  policies decide what a caller sees, a filter the caller may not read matches
  nothing, `as_of` is read-only on a facade, and one write is one source
  action — counted, not assumed.
  """

  use ExUnit.Case, async: false

  import Ash.Expr
  import ExUnit.CaptureIO
  require Ash.Query

  alias Ash.Error.Forbidden.ForbiddenField, as: ForbiddenFieldError
  alias Ash.Error.Invalid.TenantRequired
  alias Ash.Error.Query.NotFound
  alias Ash.ForbiddenField

  alias AshStrangler.Test.Facades.{
    AnnotatedItem,
    Cabinet,
    CabinetView,
    Credential,
    CredentialCard,
    Flag,
    FlagView,
    Gauge,
    GaugeView,
    Meeting,
    MeetingLine,
    MeetingMinute,
    Task,
    Ticket,
    TicketView,
    WorkItem,
    WorkItemRow
  }

  setup do
    org = "org_#{System.unique_integer([:positive])}"
    other_org = "other_#{System.unique_integer([:positive])}"

    open = task!(org, "First", :open, 30, "n1", "L1")
    done = task!(org, "Second", :done, 90, "n2", "L2")
    _foreign = task!(other_org, "Third", :open, 15, "n3", "L3")

    actor = %{org_id: org}

    %{org: org, other_org: other_org, actor: actor, open: open, done: done}
  end

  defp task!(org, name, status, estimate, notes, ref) do
    Ash.create!(
      Ash.Changeset.for_create(Task, :create, %{
        id: Ash.UUID.generate(),
        org_id: org,
        name: name,
        status: status,
        estimate_minutes: estimate,
        internal_notes: notes,
        legacy_ref: ref
      }),
      authorize?: false
    )
  end

  defp read!(resource, opts) do
    {:ok, rows} = Ash.read(resource, opts)
    rows
  end

  # A facade with a policy of its own, compiled for one test: the policy
  # filter travels with the read, so these fail if the manual read dropped
  # `query.filter`. The facade's own verifier objects to the `policies` block —
  # by design — and the capture keeps that objection out of the test output.
  defp facade_with_policy_probe(policy_body) do
    name = "AshStrangler.FacadeTest.PolicyProbe#{System.unique_integer([:positive])}"

    {result, _io} =
      with_io(:stderr, fn ->
        Code.eval_string("""
        defmodule #{name} do
          use Ash.Resource,
            domain: AshStrangler.Test.Facades,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshStrangler.Facade],
            authorizers: [Ash.Policy.Authorizer]

          attributes do
            attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
            attribute :org_id, :string, public?: true
            attribute :title, :string, public?: true
          end

          facade do
            source AshStrangler.Test.Facades.Task

            map :id, from: :id
            map :org_id, from: :org_id
            map :title, from: :name

            hide :estimate_minutes, because: "The probe does not show effort."
            hide :internal_notes, because: "Not part of this vocabulary."
            hide :status, because: "The probe does not show state."
            defer :legacy_ref

            #{policy_body}
          end
        end
        """)
      end)

    {{:module, module, _, _}, _binding} = result
    module
  end

  # --- reads -------------------------------------------------------------------

  describe "a read is the source's read, in the facade's vocabulary" do
    test "every attribute is evaluated through its lens", %{org: org, actor: actor, open: open} do
      [row] =
        WorkItem
        |> Ash.Query.filter(expr(title == "First"))
        |> read!(actor: actor, tenant: org, authorize?: true)

      assert row.id == open.id
      assert row.org_id == org
      assert row.title == "First"
      assert row.state == :new
      assert row.effort_minutes == 30
    end

    test "the source row's primary key is kept as metadata", %{org: org, actor: actor, open: open} do
      [row] =
        WorkItem
        |> Ash.Query.filter(expr(title == "First"))
        |> read!(actor: actor, tenant: org, authorize?: true)

      assert row.__metadata__[:source] == %{id: open.id}
    end

    test "a caller with no grant returns no rows: the source's policy decides", %{
      org: org,
      other_org: other_org
    } do
      rows = read!(WorkItem, actor: %{org_id: other_org}, tenant: org, authorize?: true)
      assert rows == []
    end

    test "another tenant's rows never appear", %{org: org, actor: actor} do
      titles =
        read!(WorkItem, actor: actor, tenant: org, authorize?: true) |> Enum.map(& &1.title)

      assert Enum.sort(titles) == ["First", "Second"]
    end

    test "a read with no tenant is refused, for a person and for a system actor", %{actor: actor} do
      for actor <- [actor, %{system?: true}] do
        assert {:error, %Ash.Error.Invalid{errors: [reason | _]}} =
                 Ash.read(WorkItem, actor: actor, authorize?: true)

        assert %TenantRequired{} = reason
        assert reason.resource == WorkItem
      end
    end
  end

  describe "the facade's own policy filter travels whole" do
    test "a policy whose filter is false gives the caller nothing", %{org: org, actor: actor} do
      probe =
        facade_with_policy_probe("""
        policies do
          policy always() do
            authorize_if expr(false)
          end
        end
        """)

      # Ash refuses an always-false policy before the data layer. What must
      # never happen is rows: the caller sees either the refusal or nothing.
      case Ash.read(probe, actor: actor, tenant: org, authorize?: true) do
        {:ok, []} -> :ok
        {:error, _refused} -> :ok
        {:ok, rows} -> flunk("a policy-false read returned #{length(rows)} rows")
      end
    end

    test "an unsatisfiable policy filter reaches the manual read and returns no rows", %{
      org: org,
      actor: actor
    } do
      probe =
        facade_with_policy_probe("""
        policies do
          policy always() do
            authorize_if expr(org_id == :not_an_org)
          end
        end
        """)

      # A filter check is not strict-checkable, so the policy filter travels
      # to the manual read. If the read ignored `query.filter`, the fixture's
      # rows would come back.
      assert [] = read!(probe, actor: actor, tenant: org, authorize?: true)
    end

    test "a policy restricted to the actor's rows still limits the result", %{
      org: org,
      other_org: other_org
    } do
      probe =
        facade_with_policy_probe("""
        policies do
          policy always() do
            authorize_if expr(org_id == ^actor(:org_id))
          end
        end
        """)

      # The actor's org has no rows; a read that ignored the policy filter
      # would return the fixture's.
      assert [] =
               read!(probe, actor: %{org_id: other_org}, tenant: org, authorize?: true)

      rows = read!(probe, actor: %{org_id: org}, tenant: org, authorize?: true)
      assert length(rows) == 2
    end
  end

  # --- filters and sorts -------------------------------------------------------

  describe "filters and sorts push down" do
    test "a rename filters on the source column", %{org: org, actor: actor} do
      titles =
        org
        |> facade_query(actor)
        |> Ash.Query.filter(expr(title == "First"))
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.title)

      assert titles == ["First"]
    end

    test "a decode filter finds the source's encoded rows", %{org: org, actor: actor} do
      titles =
        org
        |> facade_query(actor)
        |> Ash.Query.filter(expr(state == :finished))
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.title)

      assert titles == ["Second"]
    end

    test "`in` travels through the decode", %{org: org, actor: actor} do
      titles =
        org
        |> facade_query(actor)
        |> Ash.Query.filter(expr(state in [:new, :cancelled]))
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.title)

      assert titles == ["First"]
    end

    test "`contains` travels through the rename", %{org: org, actor: actor} do
      titles =
        org
        |> facade_query(actor)
        |> Ash.Query.filter(expr(contains(title, "irs")))
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.title)

      assert titles == ["First"]
    end

    test "a comparison of two attributes compares their source columns" do
      equal = gauge!(%{title: "equal", span: 3, load: 3})
      _unequal = gauge!(%{title: "unequal", span: 3, load: 4})

      ids =
        GaugeView
        |> Ash.Query.filter(expr(width == height))
        |> read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert ids == [equal.id]
    end

    test "a facade attribute named like a hidden source column compares through its own lens" do
      # `code` is a facade attribute mapped from `alias`; the source column
      # `code` is hidden. The row whose hidden column equals its title must
      # not come back.
      trap = gauge!(%{title: "same", alias: nil, code: "same", span: 1, load: 1})
      hit = gauge!(%{title: "echo", alias: "echo", code: "other", span: 1, load: 1})

      ids =
        GaugeView
        |> Ash.Query.filter(expr(title == code))
        |> read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute trap.id in ids
      assert hit.id in ids
    end

    test "a comparison of two attributes translates both sides onto the source" do
      query = Ash.Query.new(GaugeView) |> Ash.Query.filter(expr(width == height))
      lenses = AshStrangler.Facade.Info.lenses(GaugeView)

      {:ok, translated} = AshStrangler.Translate.filter(lenses, query.filter, Gauge)

      refs = Ash.Filter.list_refs(translated)
      assert refs != []
      refute Enum.any?(refs, &(&1.resource == GaugeView))
    end

    test "a relationship path or exists is refused, not ignored", %{org: org, actor: actor} do
      # Refused at the facade query: the path names nothing, so the filter is
      # never built — and a filter that cannot be built is never silently
      # dropped.
      assert_raise RuntimeError, ~r/exists/, fn ->
        org
        |> facade_query(actor)
        |> Ash.Query.filter(expr(exists(not_a_relationship, true)))
        |> read!(actor: actor, tenant: org, authorize?: true)
      end
    end

    test "a sort by a rename orders by the source column", %{org: org, actor: actor} do
      titles =
        org
        |> facade_query(actor)
        |> Ash.Query.sort(title: :asc)
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.title)

      assert titles == ["First", "Second"]
    end

    test "a sort by a decode orders by the decoded value", %{org: org, actor: actor} do
      states =
        org
        |> facade_query(actor)
        |> Ash.Query.sort(state: :desc)
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.state)

      assert states == [:new, :finished]
    end

    test "limit and offset are passed", %{org: org, actor: actor} do
      titles =
        org
        |> facade_query(actor)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.limit(1)
        |> Ash.Query.offset(1)
        |> read!(actor: actor, tenant: org, authorize?: true)
        |> Enum.map(& &1.title)

      assert titles == ["Second"]
    end

    test "a count is refused: Ash reports none for a manual read", %{org: org, actor: actor} do
      query = org |> facade_query(actor) |> Ash.Query.sort(title: :asc)

      assert {:error, _} =
               Ash.read(query, actor: actor, tenant: org, authorize?: true, page: [count: true])
    end

    test "keyset pagination is refused, not translated", %{org: org, actor: actor} do
      query = org |> facade_query(actor)

      assert {:error, _} =
               Ash.read(query,
                 actor: actor,
                 tenant: org,
                 authorize?: true,
                 page: [limit: 1, after: "g3AAA"]
               )
    end

    defp facade_query(org, _actor), do: WorkItem |> Ash.Query.new() |> Ash.Query.set_tenant(org)
  end

  # --- the source's preparations ----------------------------------------------

  describe "the source's preparations see the caller" do
    test "a facade read reaches a source read whose preparation narrows by the actor" do
      _theirs = cabinet!(%{scope: "theirs", count: 1, note: "not yours"})
      actor = %{scope: "mine"}

      direct =
        Cabinet
        |> Ash.Query.for_read(:scoped, %{}, actor: actor)
        |> Ash.read!(authorize?: false)

      via =
        CabinetView
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.read!(authorize?: false)

      assert direct == []
      assert via == []
    end

    test "a facade write cannot reach a row the caller's source read does not reach" do
      theirs = cabinet!(%{scope: "theirs", count: 1, note: "not yours"})
      actor = %{scope: "mine"}

      assert {:error, %{errors: [error | _]}} =
               Ash.ActionInput.for_action(
                 CabinetView,
                 :set_note,
                 %{
                   id: theirs.id,
                   note: "tampered"
                 },
                 actor: actor,
                 authorize?: false
               )
               |> Ash.run_action()

      assert %NotFound{} = error

      assert Ash.get!(Cabinet, theirs.id, authorize?: false).note == "not yours"
    end

    test "the caller's own row reads and writes through the facade" do
      mine = cabinet!(%{scope: "mine", count: 7, note: "mine"})
      actor = %{scope: "mine"}

      [row] =
        CabinetView
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.read!(authorize?: false)

      assert row.id == mine.id

      {:ok, record} =
        Ash.ActionInput.for_action(CabinetView, :set_note, %{id: mine.id, note: "changed"},
          actor: actor,
          authorize?: false
        )
        |> Ash.run_action()

      assert record.note == "changed"
      assert Ash.get!(Cabinet, mine.id, authorize?: false).note == "changed"
    end
  end

  # --- forbidden fields --------------------------------------------------------

  describe "a hidden source column reads as a forbidden field" do
    test "for a caller without the grant, computed values included" do
      holder = "holder_#{System.unique_integer([:positive])}"
      credential!(holder, "555-9")

      [card] =
        CredentialCard
        |> Ash.Query.filter(expr(holder == ^holder))
        |> read!(actor: %{}, authorize?: true)

      assert %ForbiddenField{field: :number} = card.number
      # A value computed from a forbidden value is forbidden too, never computed.
      assert %ForbiddenField{field: :display} = card.display
    end

    test "the value for a caller with the grant" do
      holder = "holder_#{System.unique_integer([:positive])}"
      credential!(holder, "555-9")

      [card] =
        CredentialCard
        |> Ash.Query.filter(expr(holder == ^holder))
        |> read!(actor: %{credential_access?: true}, authorize?: true)

      assert card.number == "555-9"
      assert card.display == "#{holder} 555-9"
    end

    test "a filter on it matches nothing without the grant, and matches with it" do
      holder = "holder_#{System.unique_integer([:positive])}"
      credential!(holder, "555-9")

      assert [] =
               CredentialCard
               |> Ash.Query.filter(expr(number == "555-9"))
               |> read!(actor: %{}, authorize?: true)

      assert [_card] =
               CredentialCard
               |> Ash.Query.filter(expr(number == "555-9"))
               |> read!(actor: %{credential_access?: true}, authorize?: true)
    end

    test "a sort on it is refused without the grant, naming the facade attribute" do
      holder = "holder_#{System.unique_integer([:positive])}"
      credential!(holder, "555-9")

      assert {:error, %{errors: [error | _]}} =
               CredentialCard
               |> Ash.Query.sort(number: :asc)
               |> Ash.read(actor: %{}, authorize?: true)

      assert %ForbiddenFieldError{field: :number, resource: CredentialCard} = error
    end

    test "a sort on it is allowed with the grant" do
      holder = "holder_#{System.unique_integer([:positive])}"
      credential!(holder, "555-9")

      assert [_card] =
               CredentialCard
               |> Ash.Query.sort(number: :asc)
               |> read!(actor: %{credential_access?: true}, authorize?: true)
    end
  end

  defp credential!(holder, number) do
    Ash.create!(
      Ash.Changeset.for_create(Credential, :create, %{
        id: Ash.UUID.generate(),
        holder: holder,
        number: number
      }),
      authorize?: false
    )
  end

  defp gauge!(attrs) do
    Ash.create!(
      Ash.Changeset.for_create(Gauge, :create, Map.put_new(attrs, :id, Ash.UUID.generate())),
      authorize?: false
    )
  end

  defp cabinet!(attrs) do
    Ash.create!(
      Ash.Changeset.for_create(Cabinet, :create, Map.put_new(attrs, :id, Ash.UUID.generate())),
      authorize?: false
    )
  end

  defp flag!(attrs) do
    Ash.create!(
      Ash.Changeset.for_create(Flag, :create, Map.put_new(attrs, :id, Ash.UUID.generate())),
      authorize?: false
    )
  end

  # --- as_of -------------------------------------------------------------------

  describe "as_of" do
    test "over a temporal source returns the version that was valid", %{
      org: org,
      actor: actor
    } do
      # The facade's non-temporal read carrying as_of is refused first, which
      # is the temporal test's control: the same instant over Task refuses.
      assert {:error, %{errors: [error | _]}} =
               Ash.Query.new(WorkItem)
               |> Ash.Query.as_of(~U[2020-01-01 00:00:00Z])
               |> Ash.read(actor: actor, tenant: org, authorize?: true)

      assert Exception.message(error) =~ "as_of"
    end

    test "over a temporal source the earlier version is returned, and [] before it existed" do
      title = "meeting_#{System.unique_integer([:positive])}"
      start = DateTime.add(DateTime.utc_now(), -10, :second)
      change = DateTime.add(DateTime.utc_now(), -5, :second)

      meeting =
        Ash.create!(
          Ash.Changeset.for_create(Meeting, :create, %{title: title}, as_of: start),
          authorize?: false
        )

      assert [] =
               read!(MeetingMinute, as_of: DateTime.add(start, -5, :second), authorize?: false)
               |> Enum.filter(&(&1.id == meeting.id))

      Ash.update!(
        Ash.Changeset.for_update(meeting, :update, %{title: title <> "_changed"}, as_of: change),
        authorize?: false
      )

      [earlier] =
        read!(MeetingMinute, as_of: start, authorize?: false)
        |> Enum.filter(&(&1.id == meeting.id))

      assert earlier.title == title

      [later] =
        read!(MeetingMinute, as_of: change, authorize?: false)
        |> Enum.filter(&(&1.id == meeting.id))

      assert later.title == title <> "_changed"

      # Reading now sees the current version, not the one in hand.
      [current] =
        read!(MeetingMinute, authorize?: false) |> Enum.filter(&(&1.id == meeting.id))

      assert current.title == title <> "_changed"
    end

    test "a facade over a facade over a temporal source forwards it hop by hop" do
      title = "meeting_#{System.unique_integer([:positive])}"
      start = DateTime.add(DateTime.utc_now(), -10, :second)
      change = DateTime.add(DateTime.utc_now(), -5, :second)

      meeting =
        Ash.create!(
          Ash.Changeset.for_create(Meeting, :create, %{title: title}, as_of: start),
          authorize?: false
        )

      Ash.update!(
        Ash.Changeset.for_update(meeting, :update, %{title: title <> "_changed"}, as_of: change),
        authorize?: false
      )

      assert [] =
               read!(MeetingLine, as_of: DateTime.add(start, -5, :second), authorize?: false)
               |> Enum.filter(&(&1.id == meeting.id))

      [earlier] =
        read!(MeetingLine, as_of: start, authorize?: false)
        |> Enum.filter(&(&1.id == meeting.id))

      assert earlier.heading == title

      [later] =
        read!(MeetingLine, as_of: change, authorize?: false)
        |> Enum.filter(&(&1.id == meeting.id))

      assert later.heading == title <> "_changed"
    end

    test "a facade over a facade over a source with no time still refuses as_of" do
      assert {:error, %{errors: [error | _]}} =
               Ash.Query.new(WorkItemRow)
               |> Ash.Query.as_of(~U[2020-01-01 00:00:00Z])
               |> Ash.read(authorize?: false, tenant: "any")

      assert Exception.message(error) =~ "as_of"
    end

    test "as_of on a write is refused before anything runs" do
      title = "meeting_#{System.unique_integer([:positive])}"
      start = DateTime.add(DateTime.utc_now(), -10, :second)

      meeting =
        Ash.create!(
          Ash.Changeset.for_create(Meeting, :create, %{title: title}, as_of: start),
          authorize?: false
        )

      assert {:error, %{errors: [error | _]}} =
               Ash.ActionInput.for_action(MeetingMinute, :retitle, %{id: meeting.id, title: "x"},
                 as_of: ~U[2020-01-01 00:00:00Z]
               )
               |> Ash.run_action()

      assert Exception.message(error) =~ "as_of"
      assert Exception.message(error) =~ "now"

      # Nothing ran: the source still holds exactly the one version, with the
      # original title.
      [only] =
        read!(MeetingMinute, authorize?: false) |> Enum.filter(&(&1.id == meeting.id))

      assert only.title == title
    end
  end

  # --- writes ------------------------------------------------------------------

  describe "a write runs one source action, as the caller" do
    test "finish moves the source row through complete and returns the new state", %{
      org: org,
      actor: actor,
      open: open
    } do
      {:ok, record} =
        Ash.ActionInput.for_action(WorkItem, :finish, %{id: open.id},
          actor: actor,
          tenant: org,
          authorize?: true
        )
        |> Ash.run_action()

      assert record.state == :finished
      assert record.__metadata__[:source] == %{id: open.id}

      assert_received {:source_action, :complete}
      refute_received {:source_action, :complete}

      [source] =
        Task
        |> Ash.Query.filter(expr(id == ^open.id))
        |> read!(authorize?: false)

      assert source.status == :done
    end

    test "the source's own guard still fires, in the source's words", %{
      org: org,
      actor: actor,
      done: done
    } do
      assert {:error, %{errors: [error | _]}} =
               Ash.ActionInput.for_action(WorkItem, :finish, %{id: done.id},
                 actor: actor,
                 tenant: org,
                 authorize?: true
               )
               |> Ash.run_action()

      assert Exception.message(error) =~ "only an open task can be completed"
      refute_received {:source_action, :complete}
    end

    test "a row the caller cannot read is not found, and nothing is written", %{
      org: org,
      other_org: other_org,
      open: open
    } do
      assert {:error, %{errors: [error | _]}} =
               Ash.ActionInput.for_action(WorkItem, :finish, %{id: open.id},
                 actor: %{org_id: other_org},
                 tenant: org,
                 authorize?: true
               )
               |> Ash.run_action()

      assert %NotFound{} = error
      refute_received {:source_action, :complete}

      [source] =
        Task
        |> Ash.Query.filter(expr(id == ^open.id))
        |> read!(authorize?: false)

      assert source.status == :open
    end

    test "a write with no tenant is refused, for a person and for a system actor, and unchanged",
         %{
           actor: actor,
           open: open
         } do
      for caller <- [actor, %{system?: true}] do
        assert {:error, %{errors: [error | _]}} =
                 Ash.ActionInput.for_action(WorkItem, :finish, %{id: open.id},
                   actor: caller,
                   authorize?: true
                 )
                 |> Ash.run_action()

        assert %Ash.Error.Invalid.TenantRequired{} = error
      end

      refute_received {:source_action, :complete}

      [source] =
        Task
        |> Ash.Query.filter(expr(id == ^open.id))
        |> read!(authorize?: false)

      assert source.status == :open
    end

    test "a write whose caller the source forbids is forbidden, and unchanged", %{
      other_org: other_org,
      open: open
    } do
      assert {:error, _} =
               Ash.ActionInput.for_action(WorkItem, :finish, %{id: open.id},
                 actor: %{org_id: other_org},
                 tenant: other_org,
                 authorize?: true
               )
               |> Ash.run_action()

      refute_received {:source_action, :complete}

      [source] =
        Task
        |> Ash.Query.filter(expr(id == ^open.id))
        |> read!(authorize?: false)

      assert source.status == :open
    end

    test "an accepted value travels through the lens", %{org: org, actor: actor, open: open} do
      {:ok, record} =
        Ash.ActionInput.for_action(WorkItem, :set_estimate, %{id: open.id, effort_minutes: 45},
          actor: actor,
          tenant: org,
          authorize?: true
        )
        |> Ash.run_action()

      assert record.effort_minutes == 45

      [source] =
        Task
        |> Ash.Query.filter(expr(id == ^open.id))
        |> read!(authorize?: false)

      assert source.estimate_minutes == 45
    end

    test "an accepted value the source takes as an argument travels through that argument", %{
      org: org,
      actor: actor,
      open: open
    } do
      {:ok, record} =
        Ash.ActionInput.for_action(AnnotatedItem, :annotate, %{id: open.id, note: "call back"},
          actor: actor,
          tenant: org,
          authorize?: true
        )
        |> Ash.run_action()

      assert record.note == "call back"

      [source] =
        Task
        |> Ash.Query.filter(expr(id == ^open.id))
        |> read!(authorize?: false)

      assert source.internal_notes == "call back"
    end

    test "a write over a state-machine source moves it through its transition" do
      ticket =
        Ticket
        |> Ash.Changeset.for_create(:create, %{id: Ash.UUID.generate(), title: "Printer"})
        |> Ash.create!()

      assert ticket.state == :open

      {:ok, record} =
        TicketView
        |> Ash.ActionInput.for_action(:close, %{id: ticket.id})
        |> Ash.run_action()

      assert record.phase == :done
      assert Ash.get!(Ticket, ticket.id).state == :closed
    end

    test "a facade over a facade reads hop by hop", %{org: org, actor: actor} do
      labels =
        WorkItemRow
        |> Ash.Query.set_tenant(org)
        |> read!(actor: actor, authorize?: true)
        |> Enum.map(& &1.label)

      assert Enum.sort(labels) == ["First", "Second"]
    end
  end

  describe "a collapse write holds the row it read" do
    test "a state whose set omits a column keeps the column's stored value" do
      flag = flag!(%{kept: false, shown: true})

      {:ok, record} =
        Ash.ActionInput.for_action(FlagView, :set_state, %{id: flag.id, state: :kept},
          authorize?: false
        )
        |> Ash.run_action()

      assert record.state == :kept

      source = Ash.get!(Flag, flag.id, authorize?: false)
      assert source.kept == true
      # The `:kept` state's `set:` omits the other column: it holds.
      assert source.shown == true
    end

    test "a state whose set names both columns writes both" do
      flag = flag!(%{kept: true, shown: false})

      {:ok, record} =
        Ash.ActionInput.for_action(FlagView, :set_state, %{id: flag.id, state: :shown},
          authorize?: false
        )
        |> Ash.run_action()

      assert record.state == :shown

      source = Ash.get!(Flag, flag.id, authorize?: false)
      assert source.kept == false
      assert source.shown == true
    end
  end

  describe "an accepted argument the caller omits is not written" do
    test "an omitted argument leaves the source column alone" do
      flag = flag!(%{count: 5, label: "keep me"})

      {:ok, _record} =
        Ash.ActionInput.for_action(FlagView, :set_details, %{id: flag.id, count: 9},
          authorize?: false
        )
        |> Ash.run_action()

      source = Ash.get!(Flag, flag.id, authorize?: false)
      assert {source.count, source.label} == {9, "keep me"}
    end

    test "an argument supplied as nil is still written as a nil" do
      flag = flag!(%{count: 5, label: "keep me"})

      {:ok, _record} =
        Ash.ActionInput.for_action(FlagView, :set_details, %{
          id: flag.id,
          count: 9,
          label: nil
        })
        |> Ash.run_action()

      source = Ash.get!(Flag, flag.id, authorize?: false)
      assert {source.count, source.label} == {9, nil}
    end
  end

  describe "a write returns what a read returns" do
    test "the write's record carries what the read's does, calculations included" do
      gauge = gauge!(%{title: "quiet", span: 1, load: 1})

      {:ok, written} =
        Ash.ActionInput.for_action(GaugeView, :set_width, %{id: gauge.id, width: 9},
          authorize?: false
        )
        |> Ash.run_action()

      [read_back] =
        GaugeView
        |> Ash.Query.filter(expr(id == ^gauge.id))
        |> read!(authorize?: false)

      assert written.title == "quiet"
      assert written.width == 9
      # A lens reads a source calculation: the update loaded it, so the write
      # answers it instead of failing after the fact.
      assert written.shout == "quiet!"
      assert written.shout == read_back.shout
      assert written.__metadata__[:source] == read_back.__metadata__[:source]
    end

    test "a calculation the caller may not read is a forbidden field, never the value" do
      holder = "holder_#{System.unique_integer([:positive])}"
      credential!(holder, "555-9")

      [card] =
        CredentialCard
        |> Ash.Query.filter(expr(holder == ^holder))
        |> read!(actor: %{}, authorize?: true)

      {:ok, written} =
        Ash.ActionInput.for_action(CredentialCard, :set_holder, %{id: card.id, holder: "renamed"},
          actor: %{},
          authorize?: true
        )
        |> Ash.run_action()

      assert %ForbiddenField{field: :line} = written.line
    end
  end
end
