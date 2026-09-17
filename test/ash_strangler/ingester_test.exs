# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.IngesterTest.ExoticKey do
  @moduledoc """
  A mapping whose key strategy the generator cannot spell.

  The DSL's `strategy:` is `:any` and `KeyDerivation` raises on what it does
  not implement at *runtime*; the generator has to bake id derivation in as
  source text, so it must refuse an unspelligable strategy at *generation*
  time -- which is what this fixture reaches.
  """

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  postgres do
    table "exotic_keys"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  strangler do
    phase :read_from_legacy

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:some_other, :strategy}
      map :login, from: :login
    end
  end
end

defmodule AshStrangler.IngesterTest do
  @moduledoc """
  Tests for what `mix ash_strangler.gen.ingester` renders, against the same
  support fixtures the round-trip suite uses.

  The repo has no end-to-end generator tests -- `gen.twin` needs a live
  legacy schema and `gen.migration` is covered through `Migration.render/2`
  in the view tests -- so this file covers the split the same way: the
  rendering is a pure function (`AshStrangler.Ingester`), and these assert
  that what it emits parses cleanly and carries the parts of the contract
  that make the skeleton safe rather than plausible.

  The worker is only smoke-compiled against a real host repo: the rendered
  worker needs the `oban` dependency, which this package deliberately does
  not carry (the generated moduledoc tells the host to add it). So the
  failing-ingest branch is asserted at the source level -- it must name the
  host repo's `rollback/1` in full, never an unqualified `Repo.` -- and the
  exact rollback call it renders is executed against the host repo to prove
  it surfaces as the drain's error tuple rather than a raise.
  """

  use AshStrangler.DataCase, async: true

  import ExUnit.CaptureIO

  alias AshStrangler.Ingester
  alias AshStrangler.Test.DualWriteUser

  @namespace AshStrangler.Test.Ledger

  describe "context/2" do
    test "derives the module names, repo, relation and key from the resource" do
      assert {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)

      assert ctx.resource == DualWriteUser
      assert ctx.ingestion == AshStrangler.Test.Ledger.DualWriteUserIngestion
      assert ctx.worker == AshStrangler.Test.Ledger.DualWriteUserDrainWorker
      assert ctx.repo == AshStrangler.TestRepo
      assert ctx.relation == "legacy.users"
      assert ctx.schema == "legacy"
      assert ctx.table == "users"
      assert ctx.key_column == "id"
    end

    test "refuses a resource with no strangler mapping" do
      # The twin is a resource and even shares the relation -- but nothing is
      # mapped onto it, so there is no ledger to drain and no key to locate
      # rows by.
      assert {:error, message} =
               Ingester.context(AshStrangler.Test.Legacy.Users, @namespace)

      assert message =~ "no strangler mapping"
    end

    test "refuses a key strategy it cannot spell, rather than baking a broken derivation" do
      assert {:error, message} =
               Ingester.context(AshStrangler.IngesterTest.ExoticKey, @namespace)

      assert message =~ "{:some_other, :strategy}"
      assert message =~ "uuid_v5"
      assert message =~ ":identity"
    end
  end

  describe "render_ingestion/1" do
    test "emits a module that parses without compiler diagnostics" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_ingestion(ctx)

      {_ast, stderr} = with_io(:stderr, fn -> Code.string_to_quoted!(source) end)

      assert stderr == "", "rendering emitted compiler diagnostics:\n#{stderr}"
    end

    test "carries the actor stub and the source envelope, not a guessed mapping" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_ingestion(ctx)

      # The two forms resolve_actor/1 may return, both routed.
      assert source =~ "{:ok, actor} -> apply_event(event, metadata, actor: actor)"
      assert source =~ ":unattributed -> apply_event(event, metadata, [])"
      assert source =~ "def resolve_actor(_event), do: :unattributed"

      # The envelope is the provenance contract with the host's event log.
      assert source =~ "source_event_id: event.id"
      assert source =~ "source_user: event.source_user"
      assert source =~ "transaction_id: event.transaction_id"
      assert source =~ "actor_confidence: event.actor_confidence"

      # The insert/update branch raises rather than inventing a column mapping.
      assert source =~ "implement the insert/update branch"
    end

    test "locates rows through KeyDerivation, never a re-implemented hash" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_ingestion(ctx)

      assert source =~ "AshStrangler.KeyDerivation.uuid_v5("
      assert source =~ "AshStrangler.KeyDerivation.name(\"legacy.users\", legacy_key)"
      # The namespace comes from the key declaration, byte for byte.
      assert source =~ DualWriteUser.namespace()

      refute source =~ "uuid_generate_v5", "the hash is Elixir-side here, not SQL"
    end
  end

  describe "render_worker/1" do
    test "emits a module that parses without compiler diagnostics" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_worker(ctx)

      {_ast, stderr} = with_io(:stderr, fn -> Code.string_to_quoted!(source) end)

      assert stderr == "", "rendering emitted compiler diagnostics:\n#{stderr}"
    end

    test "drains by cursor with SKIP LOCKED and marks processed on success" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_worker(ctx)

      assert source =~ "WHERE processed_at IS NULL"
      assert source =~ "FOR UPDATE SKIP LOCKED"
      assert source =~ "ORDER BY id"
      assert source =~ "SET processed_at = now()"
      assert source =~ "source_schema = $1"
      assert source =~ "source_table = $2"

      # One definition of the table name, read through -- never spelled again.
      assert source =~ "AshStrangler.Sql.Ledger.events_table()"
    end

    test "says that the sweep is the recovery net for missed wakes" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_worker(ctx)

      assert source =~ "the sweep is the guarantee"
      assert source =~ "Oban.Plugins.Cron"
      assert source =~ "ledger_drain"
    end

    test "rolls back through the host repo, spelled out in full" do
      {:ok, ctx} = Ingester.context(DualWriteUser, @namespace)
      source = Ingester.render_worker(ctx)

      # The failing-ingest branch runs inside the drain's transaction, and
      # the module aliases the host repo under its own name -- so an
      # unqualified `Repo.rollback` would compile as a reference to a module
      # that does not exist and raise UndefinedFunctionError on the first
      # poison event. The rollback must carry the host repo's name.
      assert source =~ "#{inspect(ctx.repo)}.rollback({:ingest_failed, event.id, reason})"

      refute Regex.match?(~r/\bRepo\./, source),
             "the rendered worker must never reference an unqualified `Repo.`"
    end

    test "the rollback it renders surfaces as the drain's error tuple, not a raise" do
      # The exact call the rendered branch performs, run against the host
      # repo the template was rendered with: `rollback/1` must exist there
      # and abort the transaction into `{:error, reason}` -- the shape
      # `drain/1` returns to its caller for the at-least-once retry.
      assert {:error, {:ingest_failed, 42, :poison}} =
               TestRepo.transaction(fn ->
                 ingest_result = {:error, :poison}

                 case ingest_result do
                   {:ok, _ingested} -> :ok
                   {:error, reason} -> TestRepo.rollback({:ingest_failed, 42, reason})
                 end
               end)
    end
  end
end
