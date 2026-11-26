# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade.ExplainTest do
  @moduledoc """
  Where a facade value came from: the lens step and the source value it names.

  The explainer reads nothing, so every case builds the facade record by a real
  facade read as a real caller, and the answer is checked against what that read
  gave: a value the caller was refused names no source, and a value derived from
  a source value names exactly that source value and no other.
  """

  use ExUnit.Case, async: false

  alias AshProvenance.{Address, Plan}
  alias AshStrangler.Facade.{Explain, Info}

  alias AshStrangler.Test.Facades.{
    Credential,
    CredentialCard,
    TaggedItem,
    Task,
    WorkItem,
    WorkItemRow
  }

  @base "https://app.example.test/id"

  setup do
    org = "org_#{System.unique_integer([:positive])}"

    task =
      Ash.create!(
        Ash.Changeset.for_create(Task, :create, %{
          id: Ash.UUID.generate(),
          org_id: org,
          name: "First",
          status: :open,
          estimate_minutes: 30,
          internal_notes: "n",
          legacy_ref: "L"
        }),
        authorize?: false
      )

    %{org: org, actor: %{org_id: org}, task: task}
  end

  defp read_one!(facade, id, opts) do
    facade
    |> Ash.Query.filter_input(%{id: id})
    |> Ash.read!(opts)
    |> case do
      [record] -> record
      other -> flunk("expected one #{inspect(facade)} row, got #{length(other)}")
    end
  end

  defp address(type, id, attribute) do
    Address.new!(base: @base, type: type, id: id, attribute: Atom.to_string(attribute))
  end

  defp explain(record, attribute, type, source_type, extra \\ []) do
    Explain.value(
      record,
      attribute,
      [address: address(type, to_string(record.id), attribute), source_type: source_type] ++
        extra
    )
  end

  describe "a value read through a lens" do
    test "is derived from the source value it was read from", %{
      org: org,
      actor: actor,
      task: task
    } do
      record = read_one!(WorkItem, task.id, actor: actor, tenant: org)

      answer = explain(record, :title, "work_item", "task")

      assert [step] = answer.steps
      assert step.relation == :was_derived_from
      assert step.granularity == :value
      assert Address.to_iri(step.entity) == "#{@base}/work_item/#{task.id}#title"
      assert Address.to_iri(step.antecedent) == "#{@base}/task/#{task.id}#name"
      assert answer.antecedents == [step.antecedent]
      assert answer.gaps == []
    end

    test "names the mapping that read it, by its mapping version", %{
      org: org,
      actor: actor,
      task: task
    } do
      record = read_one!(WorkItem, task.id, actor: actor, tenant: org)

      assert [%{plan: plan}] = explain(record, :state, "work_item", "task").steps
      assert {:ok, ^plan} = Plan.new(key: "work_item", version: Info.mapping_version(WorkItem))
    end

    test "a decode names the column it decodes, not the value", %{
      org: org,
      actor: actor,
      task: task
    } do
      record = read_one!(WorkItem, task.id, actor: actor, tenant: org)

      assert [step] = explain(record, :state, "work_item", "task").steps
      assert step.antecedent.attribute == "status"
      assert step.summary == "through a decode lens"
      refute inspect(step) =~ "finished"
      refute inspect(step) =~ "open"
    end

    test "the shown value is the caller's, and nothing more", %{
      org: org,
      actor: actor,
      task: task
    } do
      record = read_one!(WorkItem, task.id, actor: actor, tenant: org)

      assert [%{value: nil}] = explain(record, :title, "work_item", "task").steps

      assert [%{value: {:value, "First"}}] =
               explain(record, :title, "work_item", "task", value: {:value, "First"}).steps
    end

    test "a lens over several source attributes has a step for each", %{
      actor: actor
    } do
      id = Ash.UUID.generate()

      Ash.create!(
        Ash.Changeset.for_create(Credential, :create, %{id: id, holder: "H", number: "N"}),
        authorize?: false
      )

      record = read_one!(CredentialCard, id, actor: Map.put(actor, :credential_access?, true))

      answer = explain(record, :display, "card", "credential")

      assert answer.steps |> Enum.map(& &1.antecedent.attribute) |> Enum.sort() == [
               "holder",
               "number"
             ]

      assert answer.antecedents |> Enum.map(& &1.attribute) |> Enum.sort() == [
               "holder",
               "number"
             ]
    end

    test "a read-only lens explains forward, and says why it cannot be written", %{actor: actor} do
      id = Ash.UUID.generate()

      Ash.create!(
        Ash.Changeset.for_create(Credential, :create, %{id: id, holder: "H", number: "N"}),
        authorize?: false
      )

      record = read_one!(CredentialCard, id, actor: Map.put(actor, :credential_access?, true))

      answer = explain(record, :display, "card", "credential")

      assert answer.gaps == []
      assert answer.steps != []

      assert Enum.all?(answer.steps, fn step ->
               step.summary ==
                 "through a concat lens: A display string cannot be split back into a holder and a number."
             end)
    end
  end

  describe "a value with no source attribute" do
    test "was generated by the facade's mapping, with no antecedent", %{
      org: org,
      actor: actor,
      task: task
    } do
      record = read_one!(TaggedItem, task.id, actor: actor, tenant: org)

      answer = explain(record, :kind, "tagged_item", "task")

      assert [step] = answer.steps
      assert step.relation == :was_generated_by
      assert step.activity == "tagged_item:#{task.id}"
      assert step.plan.key == "tagged_item"
      assert step.plan.version == Info.mapping_version(TaggedItem)
      assert answer.antecedents == []
      assert answer.gaps == []
    end
  end

  describe "a value the caller may not read" do
    test "is an unreadable gap with no step and no source identifier", %{actor: actor} do
      id = Ash.UUID.generate()

      Ash.create!(
        Ash.Changeset.for_create(Credential, :create, %{id: id, holder: "H", number: "N"}),
        authorize?: false
      )

      record = read_one!(CredentialCard, id, actor: actor)
      assert %Ash.ForbiddenField{} = record.number

      for attribute <- [:number, :display] do
        answer = explain(record, attribute, "card", "credential")

        assert answer.steps == []
        assert answer.antecedents == []
        assert [%{kind: :unreadable, of: of} = gap] = answer.gaps
        assert of.attribute == Atom.to_string(attribute)
        assert gap.receipt == nil and gap.summary == nil and gap.at == nil
        refute inspect(answer) =~ "credential"
      end
    end
  end

  describe "the source row" do
    test "is named by its primary key as the facade read kept it, not by the facade's own key" do
      # A facade whose `id` is read from another column would put the facade's
      # key in the address. The read keeps the source's key in its metadata.
      task_id = Ash.UUID.generate()
      org = "org_#{System.unique_integer([:positive])}"

      Ash.create!(
        Ash.Changeset.for_create(Task, :create, %{
          id: task_id,
          org_id: org,
          name: "Second",
          status: :done,
          estimate_minutes: 5,
          internal_notes: "n",
          legacy_ref: "L"
        }),
        authorize?: false
      )

      record = read_one!(WorkItem, task_id, actor: %{org_id: org}, tenant: org)
      forged = %{record | __metadata__: %{source: %{id: "another-row"}}}

      assert [step | _] = explain(forged, :title, "work_item", "task").steps
      assert step.antecedent.id == "another-row"
    end

    test "a record that carries no source key is a failed gap" do
      bare = struct(WorkItem, id: Ash.UUID.generate(), title: "x")

      answer = explain(bare, :title, "work_item", "task")

      assert answer.steps == []
      assert answer.antecedents == []
      assert [%{kind: :failed}] = answer.gaps
    end

    test "carries the instant the value was read as of" do
      source_id = Ash.UUID.generate()

      as_of = ~U[2026-01-15 00:00:00Z]

      record =
        struct(WorkItem, id: source_id, title: "x")
        |> Ash.Resource.put_metadata(:source, %{id: source_id})

      answer =
        Explain.value(record, :title,
          address:
            Address.new!(
              base: @base,
              type: "work_item",
              id: source_id,
              attribute: "title",
              as_of: as_of
            ),
          source_type: "task"
        )

      assert [%{antecedent: %{as_of: ^as_of}}] = answer.steps
    end
  end

  describe "a facade over a facade" do
    test "is one hop to the facade below, which is the next hop's to explain", %{
      org: org,
      actor: actor,
      task: task
    } do
      record = read_one!(WorkItemRow, task.id, actor: actor, tenant: org)

      answer = explain(record, :label, "work_item_row", "work_item")

      assert [step] = answer.steps
      assert Address.to_iri(step.antecedent) == "#{@base}/work_item/#{task.id}#title"
      assert step.plan.key == "work_item_row"
      assert step.plan.version == Info.mapping_version(WorkItemRow)
    end
  end

  test "an attribute the facade does not declare is a failed gap, never an empty answer", %{
    org: org,
    actor: actor,
    task: task
  } do
    record = read_one!(WorkItem, task.id, actor: actor, tenant: org)

    answer =
      Explain.value(record, :not_an_attribute,
        address: address("work_item", to_string(task.id), :title),
        source_type: "task"
      )

    assert answer.steps == []
    assert [%{kind: :failed}] = answer.gaps
  end
end
