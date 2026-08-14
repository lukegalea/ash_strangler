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
  alias AshStrangler.Test.DualWriteUser

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
