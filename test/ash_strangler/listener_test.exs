defmodule AshStrangler.ListenerTest.Notifier do
  @moduledoc """
  Forwards every notification to the process registered under this module's name.

  `Ash.Notifier.notify/1` dispatches synchronously in the calling process, so a
  test can register itself and then assert on its own mailbox.
  """
  use Ash.Notifier

  @impl true
  def notify(notification) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:notification, notification})
    end

    :ok
  end
end

defmodule AshStrangler.ListenerTest.NotifiedUser do
  @moduledoc """
  A copy of the dual-write mapping with a notifier attached, so a dispatch is
  observable.

  It reads the same view as `AshStrangler.Test.DualWriteUser` and generates no
  migration of its own -- only `:delete` notifications are exercised through it, and
  those need no re-read.
  """
  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: AshPostgres.DataLayer,
    notifiers: [AshStrangler.ListenerTest.Notifier],
    extensions: [AshStrangler.Resource]

  postgres do
    table "dual_users"
    schema "strangler"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :login, :string, public?: true
  end

  actions do
    defaults [:read, :destroy]
  end

  strangler do
    phase :dual_write

    source AshStrangler.Test.Legacy.Users do
      key :id, from: :id, strategy: {:uuid_v5, namespace: @namespace}
      map :login, from: :login
    end
  end
end

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.ListenerTest do
  @moduledoc """
  Step 5: a legacy write becomes an `Ash.Notifier.Notification` that consumers
  cannot distinguish from an Ash-originated one.

  ## Why the end-to-end test does not use the sandbox

  `NOTIFY` does not fire on rollback — correctly, and that is what you want. But
  every other test here runs inside a sandbox transaction that always rolls
  back, so a notification would never be delivered and the test would pass
  whether or not the trigger worked.

  So the delivery test opens its **own committed connection**, outside the
  sandbox, and cleans up after itself. That is the only way to exercise a
  mechanism whose entire contract is "on commit".
  """

  use AshStrangler.DataCase, async: false

  alias AshStrangler.Listener
  alias AshStrangler.ListenerTest.NotifiedUser
  alias AshStrangler.Sql.Notify
  alias AshStrangler.Test.DualWriteUser

  describe "the generated trigger" do
    test "attaches to the relation the twin names, and keys off the twin's key column" do
      # The relation is read off the twin's own `postgres do table/schema end`
      # rather than from a `source "legacy.users"` string in the mapping. That
      # removed the one place these two facts could disagree -- and a notify
      # trigger attached to the wrong relation is silent, because nothing ever
      # arrives to be missed.
      [function, trigger] = Notify.build(DualWriteUser)

      assert trigger.up =~ "AFTER INSERT OR UPDATE OR DELETE ON legacy.users"
      assert function.up =~ "affected.id"

      # The resource module is baked in, in the atom's real text form, because
      # `String.to_existing_atom/1` on the way back needs exactly that.
      assert function.up =~ "'resource', 'Elixir.AshStrangler.Test.DualWriteUser'"
    end

    test "is not generated for a resource that did not opt in" do
      # Off by default, and the default is not free to withhold: every legacy write
      # would pay a `pg_notify`, and a full notify queue fails the transaction that
      # issued it -- which is the legacy application's transaction, not ours.
      assert Notify.build(LegacyUser) == []
    end
  end

  describe "decode/2" do
    test "resolves the resource, key and operation from a payload" do
      payload = JSON.encode!(%{resource: to_string(DualWriteUser), legacy_id: 7, op: "insert"})

      assert {:ok, %{resource: DualWriteUser, legacy_id: 7, op: :insert}} =
               Listener.decode(payload)
    end

    test "refuses a resource outside the allowed set" do
      payload = JSON.encode!(%{resource: to_string(DualWriteUser), legacy_id: 1, op: "insert"})

      assert {:error, {:unknown_resource, _}} =
               Listener.decode(payload, MapSet.new([AshStrangler.Test.LegacyUser]))
    end

    test "refuses a module name that does not exist, without creating the atom" do
      # `String.to_atom/1` on database-supplied data is an unbounded atom leak.
      # This asserts the safe path: an unknown name is rejected, not interned.
      payload = JSON.encode!(%{resource: "Elixir.Nope.Not.A.Module", legacy_id: 1, op: "insert"})

      assert {:error, {:unknown_resource, _}} = Listener.decode(payload)
    end

    test "refuses an unknown operation and malformed JSON rather than crashing" do
      assert {:error, {:unknown_operation, "truncate"}} =
               Listener.decode(
                 JSON.encode!(%{resource: to_string(DualWriteUser), legacy_id: 1, op: "truncate"})
               )

      assert {:error, _} = Listener.decode("{not json")
      assert {:error, {:unexpected_payload, _}} = Listener.decode(JSON.encode!(%{"a" => 1}))
    end
  end

  describe "notify/2" do
    setup do
      Process.register(self(), AshStrangler.ListenerTest.Notifier)
      on_exit(fn -> :ok end)
      :ok
    end

    test "dispatches a notification carrying the re-read record" do
      # `Ash.Notifier.notify/1` dispatches synchronously in the calling process,
      # so a test notifier can simply send to self().
      legacy_id = insert_legacy_user!(%{login: "listen-#{System.unique_integer([:positive])}"})

      :ok = Listener.notify(%{resource: DualWriteUser, legacy_id: legacy_id, op: :insert}, [])

      # The resource has no notifiers configured, so nothing is delivered --
      # what this asserts is that building and dispatching the notification does
      # not raise, which is the failure mode spike 6 found.
      assert true
    end

    test "a synthesized notification survives a :_pkey topic template" do
      # The regression for spike 6. With `changeset: nil` this raises
      # `KeyError: key :resource not found in: nil` from deep inside
      # Ash.Notifier.PubSub, in the listener's own process.
      legacy_id = insert_legacy_user!(%{login: "pkey-#{System.unique_integer([:positive])}"})

      {:ok, decoded} =
        Listener.decode(
          JSON.encode!(%{resource: to_string(DualWriteUser), legacy_id: legacy_id, op: "insert"})
        )

      assert :ok = Listener.notify(decoded, [])
    end

    test "a delete needs no re-read and still produces a keyed record" do
      # There is no row left to read, so this must not fail -- and must still
      # carry the derived primary key, which is what a destroy topic uses.
      assert :ok =
               Listener.notify(%{resource: DualWriteUser, legacy_id: 999_999, op: :delete}, [])
    end

    test "it actually dispatches, rather than returning :ok having done nothing" do
      # This is the assertion every other test in this block was missing, and the
      # gap was not academic: `derived_id/2` matched `%{keys: [key], relation: _}`
      # against `%AshStrangler.Source{}`, and once `source` began carrying a twin
      # instead of a relation name that match simply stopped matching. A struct
      # match that stops matching does not raise — it fell to `_ -> :error`,
      # `notify/2` returned `:ok`, and **every legacy write produced no
      # notification at all**.
      #
      # Every test here asserted `:ok`, which `notify/2` returns either way, so the
      # bridge was dead and green. The only way to tell the difference is to watch
      # for the notification, which is what a notifier is for.
      legacy_id = insert_legacy_user!(%{login: "dispatch-#{System.unique_integer([:positive])}"})

      Listener.notify(%{resource: NotifiedUser, legacy_id: legacy_id, op: :delete}, [])

      assert_receive {:notification, notification}

      assert notification.resource == NotifiedUser
      assert notification.metadata.ash_strangler == %{origin: :legacy, legacy_id: legacy_id}

      # And the derived id is the one Elixir computes independently, so this also
      # covers the half of `derived_id/2` that reads the relation off the twin --
      # a wrong relation would hash to a different uuid and still look like a
      # working notification.
      assert notification.data.id ==
               AshStrangler.KeyDerivation.uuid_v5(
                 DualWriteUser.namespace(),
                 AshStrangler.KeyDerivation.name("legacy.users", legacy_id)
               )
    end

    test "a vanished row on insert/update is ignored rather than raising" do
      assert :ok =
               Listener.notify(%{resource: DualWriteUser, legacy_id: 999_999, op: :insert}, [])
    end
  end

  describe "the generated notify trigger, end to end" do
    @tag :integration
    test "a committed legacy write is delivered on the channel" do
      # Own connection, outside the sandbox: NOTIFY only fires on commit.
      config = Listener.connection_opts(AshStrangler.TestRepo)
      {:ok, conn} = Postgrex.start_link(config)
      {:ok, notifications} = Postgrex.Notifications.start_link(config)

      {:ok, _ref} =
        Postgrex.Notifications.listen(notifications, AshStrangler.Info.default_notify_channel())

      login = "notify-#{System.unique_integer([:positive])}"

      try do
        %Postgrex.Result{rows: [[legacy_id]]} =
          Postgrex.query!(
            conn,
            "INSERT INTO legacy.users (login, state) VALUES ($1, 'active') RETURNING id",
            [login]
          )

        assert_receive {:notification, _pid, _ref, _channel, payload}, 5_000

        assert {:ok, decoded} = Listener.decode(payload)
        assert decoded.resource == DualWriteUser
        assert decoded.legacy_id == legacy_id
        assert decoded.op == :insert
      after
        Postgrex.query!(conn, "DELETE FROM legacy.users WHERE login = $1", [login])
        GenServer.stop(notifications)
        GenServer.stop(conn)
      end
    end

    @tag :integration
    test "the payload carries only the key, never row data" do
      # The 7999-byte ceiling is a hard error that aborts the LEGACY
      # application's transaction, so a payload that grows with row content is a
      # latent outage in the old system. This asserts the payload stays small
      # even when the row is not.
      config = Listener.connection_opts(AshStrangler.TestRepo)
      {:ok, conn} = Postgrex.start_link(config)
      {:ok, notifications} = Postgrex.Notifications.start_link(config)

      {:ok, _ref} =
        Postgrex.Notifications.listen(notifications, AshStrangler.Info.default_notify_channel())

      login = "big-#{System.unique_integer([:positive])}"
      huge = String.duplicate("x", 20_000)

      try do
        Postgrex.query!(
          conn,
          "INSERT INTO legacy.users (login, state, email) VALUES ($1, 'active', $2)",
          [login, huge]
        )

        assert_receive {:notification, _pid, _ref, _channel, payload}, 5_000

        assert byte_size(payload) < 200
        refute payload =~ "xxxx"
      after
        Postgrex.query!(conn, "DELETE FROM legacy.users WHERE login = $1", [login])
        GenServer.stop(notifications)
        GenServer.stop(conn)
      end
    end
  end
end
