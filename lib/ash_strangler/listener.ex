# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Listener do
  @moduledoc """
  Turns legacy writes into `Ash.Notifier.Notification`s, so downstream
  consumers cannot tell where a change came from.

      children = [
        {AshStrangler.Listener, repo: MyApp.Repo, resources: [MyApp.Accounts.User]}
      ]

  It listens on the `pg_notify` channel the generated `AFTER` trigger announces
  on (see `AshStrangler.Sql.Notify`, and `notify? true` on the source), re-reads
  the affected row **through Ash** so calculations, policies and tenancy apply,
  and dispatches a real notification.

  ## Why this is not `ecto_watch`

  `ecto_watch` is mature, adopted, and does trigger-installation plus
  listen-and-rebroadcast well, so the plan for this package originally said to
  build on it rather than duplicate it. Two things changed that:

    * It rebroadcasts to `Phoenix.PubSub`, which this package does not otherwise
      depend on. Taking it would add `phoenix_pubsub` to the dependency tree of
      a schema-mapping library.
    * It cannot do the part that actually matters here. Re-reading through Ash
      and synthesizing an `Ash.Notifier.Notification` is the whole point, and no
      generic watcher can do it.

  Since this package already generates triggers, generating one more is
  marginal, and the listener below is small and dependency-free. **If you
  already run `ecto_watch`, prefer it for the transport** — its map-form
  `schema_definition` can watch a relation in a non-default schema with no Ecto
  schema module — and call `notify/2` here with the key it hands you.

  ## The changeset is synthesized, and must be

  `Ash.Notifier.PubSub` does not degrade gracefully when a notification has no
  changeset — it **raises**. Verified against `ash` 3.31.3: a topic template
  containing `:_pkey` raises `KeyError` on `notification.changeset.resource`,
  `:_tenant` raises on `.to_tenant`, and for an update or destroy *any* plain
  attribute key dereferences `changeset.data` to compare before-and-after. Since
  `Ash.Notifier.notify/1` dispatches synchronously in the calling process, that
  crash lands here, on every legacy write matching such a publication.

  A minimal `%Ash.Changeset{}` carrying resource, action type, data and tenant
  is enough to make all of those resolve, and is what this builds. It is not a
  real changeset and does not pretend to be: there is no legacy "before" state
  to put in it, so `previous_values?` publications see the current row on both
  sides.

  ## Delivery guarantees, stated plainly

  At-most-once. A listener that is down misses everything sent while it was
  down, and there is no replay. Postgres collapses duplicate notifications
  within a transaction, so this cannot be used to count writes. `LISTEN` is
  session-scoped and therefore **does not work under pgbouncer transaction or
  statement pooling** — the listener needs a connection that bypasses the
  pooler.

  Duplicate notifications for Ash's *own* writes are not suppressed. The plan
  considered a transaction-local GUC for that and rejected it: `SET LOCAL`
  outside a transaction silently does nothing, so suppression would force a
  transaction on every write to work at all. A duplicate is harmless to a
  consumer that re-reads; a missing write is not.
  """

  use GenServer

  require Logger

  @doc """
  Starts the listener.

  Options:

    * `:repo` (required) — the `Ecto.Repo` whose connection config to listen on.
    * `:resources` — resources to accept notifications for. Defaults to
      accepting any resource named in a payload that resolves to a loaded
      module with a strangler mapping. Naming them explicitly is the safer
      choice and is what you want in production.
    * `:channel` — defaults to `AshStrangler.Info.default_notify_channel/0`.
    * `:name` — GenServer name.
    * `:actor`, `:tenant`, `:authorize?` — passed to the `Ash.get/3` that
      re-reads the affected row. **A policy-protected resource needs one of
      these.** The listener is not acting for a person: a legacy write has no
      Ash actor behind it, so with the default of nobody every read of a
      resource carrying policies is forbidden, `notify/2` returns `:ok` having
      dispatched nothing, and the only symptom is a page that stops updating.
      Pass `authorize?: false` (the notification is a system event; consumers
      re-read under their own actor), or a system actor if you have one.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    channel = Keyword.get(opts, :channel, AshStrangler.Info.default_notify_channel())

    # A dedicated connection: `LISTEN` is session state, so it cannot share a
    # pooled connection with query traffic.
    {:ok, notifications} = Postgrex.Notifications.start_link(connection_opts(repo))
    {:ok, _ref} = Postgrex.Notifications.listen(notifications, channel)

    {:ok,
     %{
       repo: repo,
       channel: channel,
       notifications: notifications,
       allowed: opts |> Keyword.get(:resources) |> allowed_set(),
       read_opts: Keyword.take(opts, [:actor, :tenant, :authorize?])
     }}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, _channel, payload}, state) do
    case decode(payload, state.allowed) do
      {:ok, decoded} ->
        notify(decoded, state.read_opts)

      {:error, reason} ->
        # Never crash the listener on a payload it does not understand. A
        # malformed or unexpected notification is a reason to look at the
        # database, not to stop delivering every subsequent one.
        Logger.warning("AshStrangler.Listener ignoring notification: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Connection options for a dedicated `LISTEN` connection, from a repo's config.

  Strips the pooling and Ecto/Ash-specific keys. Not cosmetic: a repo
  configured for tests with `pool: Ecto.Adapters.SQL.Sandbox` cannot be handed
  to `Postgrex.start_link/1` at all — it fails with
  `Ecto.Adapters.SQL.Sandbox.child_spec/1 is undefined`, because the sandbox is
  an Ecto pool rather than a DBConnection one. A listener that works in
  production and cannot start under test is a listener nobody tests.
  """
  @spec connection_opts(module()) :: keyword()
  def connection_opts(repo) do
    Keyword.drop(repo.config(), [
      :pool,
      :pool_size,
      :queue_target,
      :queue_interval,
      :migration_lock,
      :telemetry_prefix,
      :otp_app,
      :adapter,
      :installed_extensions,
      :default_prefix
    ])
  end

  @doc """
  Decodes a raw notification payload.

  Separated from the GenServer so it can be tested directly, and so a
  consumer already running `ecto_watch` can feed it whatever that delivers.
  """
  @spec decode(String.t(), MapSet.t() | nil) ::
          {:ok, %{resource: module(), legacy_id: term(), op: atom()}} | {:error, term()}
  def decode(payload, allowed \\ nil) do
    with {:ok, %{"resource" => name, "legacy_id" => legacy_id, "op" => op}} <-
           JSON.decode(payload),
         {:ok, resource} <- resolve(name, allowed),
         {:ok, op} <- operation(op) do
      {:ok, %{resource: resource, legacy_id: legacy_id, op: op}}
    else
      {:ok, other} -> {:error, {:unexpected_payload, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Re-reads the affected row and dispatches an `Ash.Notifier.Notification`.

  Returns `:ok` even when the row cannot be read: by the time a notification
  arrives the row may legitimately be gone, and a delete never has one.
  """
  @spec notify(%{resource: module(), legacy_id: term(), op: atom()}, keyword()) :: :ok
  def notify(%{resource: resource, legacy_id: legacy_id, op: op}, opts) do
    action_type = action_type(op)

    case record(resource, legacy_id, op, opts) do
      {:ok, record} ->
        dispatch(resource, record, action_type, legacy_id)

      :error ->
        :ok
    end
  end

  defp dispatch(resource, record, action_type, legacy_id) do
    %Ash.Notifier.Notification{
      resource: resource,
      domain: Ash.Resource.Info.domain(resource),
      action: action(resource, action_type),
      data: record,
      changeset: synthesized_changeset(resource, record, action_type),
      metadata: %{ash_strangler: %{origin: :legacy, legacy_id: legacy_id}}
    }
    |> Ash.Notifier.notify()

    :ok
  end

  # The resource's own action when it has one -- so a `publish :some_action`
  # template keeps naming something real, and a `:dual_write` resource's
  # notifications are indistinguishable from Ash's own.
  #
  # Otherwise a synthesized one, for the same reason the changeset above is
  # synthesized: `Ash.Notifier` dereferences `notification.action.name`
  # unconditionally, so an atom or a nil crashes the dispatch rather than
  # degrading. This used to log and skip, which meant the whole bridge was
  # inert on exactly the resource shape it is most useful for -- a
  # `:read_from_legacy` read model, which by definition declares no create,
  # update or destroy action, and which is the phase where the legacy
  # application is the ONLY writer.
  #
  # `:legacy_write` rather than a borrowed name because no Ash action ran. A
  # `publish_all :create, [...]` matches on the action's TYPE and therefore
  # still fires; a `publish :register, [...]` matches on its NAME and
  # correctly does not, because `:register` did not happen.
  defp action(resource, action_type) do
    Ash.Resource.Info.primary_action(resource, action_type) ||
      synthesized_action(action_type)
  end

  defp synthesized_action(:create),
    do: %Ash.Resource.Actions.Create{name: :legacy_write, primary?: false}

  defp synthesized_action(:update),
    do: %Ash.Resource.Actions.Update{name: :legacy_write, primary?: false}

  defp synthesized_action(:destroy),
    do: %Ash.Resource.Actions.Destroy{name: :legacy_write, primary?: false}

  # Minimal on purpose -- see the moduledoc. Every field here exists because
  # `Ash.Notifier.PubSub` dereferences it for some topic template.
  defp synthesized_changeset(resource, record, action_type) do
    %Ash.Changeset{
      resource: resource,
      action_type: action_type,
      data: record,
      to_tenant: Map.get(record, :__metadata__, %{})[:tenant]
    }
  end

  defp record(resource, legacy_id, :delete, _opts) do
    # The row is gone, so there is nothing to re-read. A struct carrying just
    # the derived key is enough for a `:_pkey` topic, which is what a destroy
    # notification is normally used for -- and it is honest about the rest
    # being unavailable rather than inventing values.
    case derived_id(resource, legacy_id) do
      {:ok, attribute, id} -> {:ok, struct(resource, %{attribute => id})}
      :error -> :error
    end
  end

  defp record(resource, legacy_id, _op, opts) do
    with {:ok, _attribute, id} <- derived_id(resource, legacy_id),
         {:ok, record} <-
           Ash.get(resource, id, Keyword.take(opts, [:tenant, :actor, :authorize?])) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  # The relation comes off the twin rather than out of the `source` entity, and
  # that is the whole of this function's history: it used to match
  # `%{keys: [key], relation: relation}` against `%AshStrangler.Source{}`, which no
  # longer carries a `:relation`.
  #
  # The failure that caused is the reason this comment is here. A struct match that
  # stops matching does not raise -- it falls to the `_ -> :error` clause, `record/4`
  # returns `:error`, and `notify/2` returns `:ok` having dispatched nothing. Every
  # legacy write silently produced no notification, and the only symptom was a
  # LiveView that stopped updating. The bridge is exactly the kind of code where a
  # silent no-op is indistinguishable from "the old application happened not to
  # write anything", so it gets `Info.relation/1` -- one accessor, which fails loudly
  # if the source is malformed -- rather than a shape match that can drift again.
  defp derived_id(resource, legacy_id) do
    with %{keys: [key]} <- AshStrangler.Info.source(resource),
         relation when is_binary(relation) <- AshStrangler.Info.relation(resource) do
      {:ok, key.attribute, AshStrangler.KeyDerivation.derive(key, relation, legacy_id)}
    else
      _ -> :error
    end
  end

  defp resolve(name, allowed) do
    # `to_existing_atom` rather than `to_atom`: the payload is data from the
    # database and unbounded atom creation is a memory leak. A compiled resource
    # module's atom always already exists.
    resource = String.to_existing_atom(name)

    cond do
      allowed && not MapSet.member?(allowed, resource) -> {:error, {:unknown_resource, name}}
      not AshStrangler.Info.strangled?(resource) -> {:error, {:not_strangled, resource}}
      true -> {:ok, resource}
    end
  rescue
    ArgumentError -> {:error, {:unknown_resource, name}}
  end

  defp operation(op) when op in ~w(insert update delete), do: {:ok, String.to_atom(op)}
  defp operation(op), do: {:error, {:unknown_operation, op}}

  defp action_type(:insert), do: :create
  defp action_type(:update), do: :update
  defp action_type(:delete), do: :destroy

  defp allowed_set(nil), do: nil
  defp allowed_set(resources), do: MapSet.new(resources)
end
