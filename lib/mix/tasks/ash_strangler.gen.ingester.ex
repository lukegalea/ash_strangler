# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshStrangler.Gen.Ingester do
    @shortdoc "Generates the ingestion module and Oban drain worker for a ledger"

    @example "mix ash_strangler.gen.ingester MyApp.Accounts.User"

    @moduledoc """
    Generates the code that turns the durable change ledger (see
    `AshStrangler.Sql.Ledger`, enabled with `ledger? true`) into writes on the
    canonical resource — the half the ledger deliberately leaves to the host.

        #{@example}
        mix ash_strangler.gen.ingester MyApp.Accounts.User --namespace MyApp.Ledger

    Two modules, written into the host's `lib/` tree:

      * `<Namespace>.<Resource>Ingestion` — turns one `legacy_change_events`
        row into **ordinary Ash actions** on the resource, carrying `actor:`
        from a `resolve_actor/1` stub (which returns `{:ok, actor}` or
        `:unattributed`) and `metadata:` with the source envelope. The delete
        path works as generated; the insert/update branch raises until the
        legacy-column-to-action-input mapping is written by hand.
      * `<Namespace>.<Resource>DrainWorker` — an idempotent Oban worker that
        drains unprocessed rows by cursor (`WHERE processed_at IS NULL ...
        FOR UPDATE SKIP LOCKED`, mark `processed_at` on success) and calls the
        ingestion module. The `pg_notify` wake is a hint; the periodic sweep
        is the recovery net, and the generated moduledoc carries the Oban
        config for both.

    ## Why the generated code raises instead of guessing

    The one thing this generator cannot derive is which legacy column becomes
    which action input. Writing a plausible guess would put plausible wrong
    rows into the new model — the failure this whole package exists to make
    loud — so the skeleton raises with instructions instead, and everything
    the generator CAN derive (the ledger row shape, the key derivation, the
    envelope, the actor plumbing, the delete path) already works.

    ## Regenerating

    An existing file is left alone: this is a skeleton the host is expected to
    finish, and overwriting a finished ingester with a fresh skeleton would
    discard exactly the code that made it real. Delete the file and re-run to
    start over.

    ## Options

      * `--namespace` — module prefix for both generated modules. Defaults to
        `<App>.Ledger`.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        positional: [:resource],
        schema: [namespace: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Mix.Task.run("compile")

      with {:ok, resource} <- resolve_resource(igniter.args.positional[:resource]),
           {:ok, ctx} <- AshStrangler.Ingester.context(resource, namespace(igniter)) do
        write(igniter, ctx)
      else
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    defp resolve_resource(nil) do
      {:error,
       """
       No resource given. Name the CANONICAL resource the ledger drains into:

           #{@example}
       """}
    end

    defp resolve_resource(name) do
      resource = Igniter.Project.Module.parse(name)

      if Code.ensure_loaded?(resource) do
        {:ok, resource}
      else
        {:error, "#{inspect(resource)} is not a compiled module. Compile first."}
      end
    end

    defp namespace(igniter) do
      case igniter.args.options[:namespace] do
        nil ->
          app = Mix.Project.config()[:app] |> to_string() |> Macro.camelize()
          Module.concat([app, "Ledger"])

        name ->
          Igniter.Project.Module.parse(name)
      end
    end

    defp write(igniter, ctx) do
      igniter
      |> write_skeleton(ctx.ingestion, AshStrangler.Ingester.render_ingestion(ctx))
      |> write_worker(ctx)
      |> Igniter.add_notice("""
      Generated the ingestion skeleton for #{inspect(ctx.resource)}:

        #{inspect(ctx.ingestion)}   -- finish the insert/update branch
        #{inspect(ctx.worker)}      -- needs the `oban` dependency and config

      Then:

        1. Add `{:oban, "~> 2.18"}` if it is not already a dependency, and
           configure the instance (the worker's moduledoc carries the queue
           and cron-sweep config).
        2. Wire the wake: `config :ash_strangler, ledger_drain: {#{inspect(ctx.worker)}, :nudge}`
        3. Make sure `AshStrangler.Migration.statements/1` has been emitted
           (`mix ash_strangler.gen.migration`) and migrated, so the
           `legacy_change_events` table and its trigger exist.

      The drain is at-least-once: the sweep is the recovery net for missed
      wakes, so the ingestion must tolerate replays.
      """)
    end

    # Only when the host already has Oban. A generated file that cannot
    # compile until a dependency is added would take the WHOLE project's
    # compilation down with it -- worse than a missing file, and worse than
    # this check, which leaves the project green and names the two commands
    # (add the dep, re-run) that complete the generation.
    defp write_worker(igniter, ctx) do
      if Code.ensure_loaded?(Oban) do
        write_skeleton(igniter, ctx.worker, AshStrangler.Ingester.render_worker(ctx))
      else
        Igniter.add_notice(igniter, """
        #{inspect(ctx.worker)} was NOT generated: `oban` is not a dependency of this project.

        Add `{:oban, "~> 2.18"}` and configure an instance, then re-run
        `mix ash_strangler.gen.ingester #{inspect(ctx.resource)}` -- the ingestion
        module above is complete and the worker is the only missing piece.
        """)
      end
    end

    # A skeleton the host is expected to finish, unlike the twin which is
    # rewritten wholesale: overwriting a finished ingester would discard the
    # hand-written mapping, which is the only part of the file that was worth
    # anything.
    defp write_skeleton(igniter, module, contents) do
      path = Igniter.Project.Module.proper_location(igniter, module)

      if Igniter.exists?(igniter, path) do
        Igniter.add_notice(
          igniter,
          "#{path} already exists and was left alone. Delete it and re-run to regenerate."
        )
      else
        Igniter.create_new_file(igniter, path, contents)
      end
    end
  end
else
  defmodule Mix.Tasks.AshStrangler.Gen.Ingester do
    @shortdoc "Generates the ledger ingester | Install `igniter` to use"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_strangler.gen.ingester' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
