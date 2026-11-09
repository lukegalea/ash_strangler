# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Migration do
  @moduledoc """
  Assembles every generated statement for a resource, in dependency order.

  This is the single place that knows the *order* the compatibility layer has
  to be built in — view, then key index, then `INSTEAD OF` triggers, then the
  notify trigger — and it is shared by `mix ash_strangler.gen.migration` and by
  the test harness, so the suite exercises exactly what a migration would run.

  Statements are `%{name: atom, up: String.t(), down: String.t()}` with **one
  SQL command each**. That is not stylistic: Ecto sends a migration's
  `execute/1` string on the extended protocol, which rejects multiple commands
  with `42601 cannot insert multiple commands into a prepared statement`.
  """

  alias AshStrangler.{Observation, Sql}

  @doc """
  Every statement for `resource`, ordered so that running them in sequence
  works from an empty database.

  A watched twin (`twin do watch "channel" end`) gets its watch trigger
  (`AshStrangler.Sql.Watch`). Returns `[]` for anything else.
  """
  @spec statements(Ash.Resource.t()) :: [%{name: atom(), up: String.t(), down: String.t()}]
  def statements(resource) do
    cond do
      union?(resource) -> AshStrangler.Union.Sql.statements(resource)
      derived?(resource) -> AshStrangler.Derived.Sql.statements(resource)
      true -> resource_statements(resource)
    end
  end

  @doc "Whether `module` is an `AshStrangler.Union`."
  @spec union?(term()) :: boolean()
  def union?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      AshStrangler.Union.Dsl in Spark.extensions(module)
  end

  def union?(_other), do: false

  @doc "Whether `module` is an `AshStrangler.Derived`."
  @spec derived?(term()) :: boolean()
  def derived?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      AshStrangler.Derived.Dsl in Spark.extensions(module)
  end

  def derived?(_other), do: false

  defp resource_statements(resource) do
    if AshStrangler.Info.strangled?(resource) do
      case AshStrangler.Info.strangler_phase!(resource) do
        :decommissioned ->
          # Nothing is generated: the compatibility layer is gone and the
          # mapping is vestigial. Removing the resource's `strangler` block
          # entirely is the next edit.
          []

        :read_from_new ->
          # No compatibility notify trigger here, deliberately. `Sql.Notify`
          # attaches an `AFTER ... FOR EACH ROW` trigger to the legacy relation,
          # and in this phase that name is the reverse *view* -- which Postgres
          # rejects outright ("Views cannot have row-level BEFORE or AFTER
          # triggers"), so emitting it would produce a migration that cannot run.
          #
          # The LEDGER trigger is different, and v0.4.0 corrected this: it is a
          # trigger on the OWNED table (the reverse view reads from it), which
          # Postgres accepts. Capture follows the authoritative base storage for
          # as long as any compatibility writer exists -- including legacy
          # writers going through the reverse view, which fire NO Ash notifier.
          # The claim that Ash's own events cover writes past cutover is true
          # only if every writer goes through Ash.
          Sql.ReverseView.build(resource) ++
            Sql.Ledger.build(resource) ++ Observation.Store.statements()

        phase ->
          %{view: view, key_index: key_index} = Sql.View.build(resource)
          triggers = if phase == :dual_write, do: Sql.Triggers.build(resource), else: []

          # The schema comes first, because everything after it is declared
          # inside it. `:read_from_new` is exempt: the reverse view takes the
          # legacy relation's own name, in a schema the legacy application
          # already owns.
          #
          # The extension table comes BEFORE the view, because the view's
          # `FROM` clause `LEFT JOIN`s it — `CREATE VIEW` resolves every
          # referenced relation at creation time. (`Sql.Extension.build/1`
          # returns [] in the phases that cannot have one, so the ordering
          # contract is unconditional.)
          #
          # The ledger comes before the notify statements, and at most one of
          # the two is non-empty: a `ledger?` source's trigger writes the
          # durable event and then notifies `wake:<id>` itself, so
          # `Sql.Notify` stands down for it. See `AshStrangler.Sql.Ledger` --
          # "One trigger, not two".
          (Enum.reject([Sql.View.schema_statement(resource)], &is_nil/1) ++
             List.flatten(Sql.Extension.build(resource)) ++
             Enum.reject([view, key_index], &is_nil/1)) ++
            triggers ++
            Sql.Ledger.build(resource) ++
            Sql.Notify.build(resource) ++
            Observation.Store.statements()
      end
    else
      if AshStrangler.Twin.twin?(resource), do: Sql.Watch.build(resource), else: []
    end
  end

  @doc """
  Every strangler-mapped resource and every watched twin across the configured
  domains, or across `domains` when given, then the unions listed in
  `config :ash_strangler, unions: [...]`, then the `deriveds: [...]`.
  """
  @spec resources(list(module()) | nil) :: [Ash.Resource.t()]
  def resources(domains \\ nil) do
    (domains || Ash.Info.domains(Mix.Project.config()[:app]))
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&(AshStrangler.Info.strangled?(&1) or watched?(&1)))
    |> Enum.concat(Application.get_env(:ash_strangler, :unions, []))
    |> Enum.concat(Application.get_env(:ash_strangler, :deriveds, []))
    |> Enum.uniq()
  end

  defp watched?(resource),
    do: AshStrangler.Twin.twin?(resource) and AshStrangler.Twin.watch(resource) != nil

  @doc """
  Renders an Ecto migration module for the given resources.

  `down` reverses the statement order, since a trigger cannot outlive the view
  it is attached to and a function cannot be dropped before the trigger that
  executes it. That is a luxury the `custom_statements` path did not have —
  it runs every `down` before every `up`, in list order, which is why those
  statements had to be individually order-independent.
  """
  @spec render(String.t(), [Ash.Resource.t()]) :: String.t()
  def render(module_name, resources) do
    # `uniq_by` the SQL rather than the name: resources sharing a schema each
    # emit the same `CREATE SCHEMA IF NOT EXISTS`, and a statement whose text is
    # byte-identical to one already in the list cannot do anything the first did
    # not. Applied before the reverse so `down` stays the exact mirror of `up`.
    statements =
      resources
      |> Enum.flat_map(&statements/1)
      |> Enum.uniq_by(& &1.up)

    ups = Enum.map_join(statements, "\n", &render_execute(&1.up))
    downs = statements |> Enum.reverse() |> Enum.map_join("\n", &render_execute(&1.down))

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Strangler compatibility layer, generated by `mix ash_strangler.gen.migration`.

      Covers: #{Enum.map_join(resources, ", ", &inspect/1)}

      Regenerate rather than hand-editing. Re-running statements that have not
      changed is safe (`CREATE OR REPLACE`, `IF NOT EXISTS`). A change of shape --
      renaming, retyping, dropping or reordering a view column -- is refused when
      the migration runs and needs a written `DROP VIEW` and `CREATE VIEW`; see
      documentation/topics/phases.md, "Changing a view's shape, in any phase".
      \"\"\"

      use Ecto.Migration

      def up do
    #{ups}  end

      def down do
    #{downs}  end
    end
    """
  end

  # Every SQL line carries the closing delimiter's indentation. A heredoc line
  # indented LESS than its closing `\"\"\"` is a compiler warning in Elixir 1.18
  # ("The current heredoc line is indented too little"), and it fired on every
  # statement of every generated migration — which makes the file unusable under
  # `--warnings-as-errors` and trains people to ignore warnings in the ones that
  # matter. Heredoc parsing strips exactly this indentation back off, so the SQL
  # Postgres receives is unchanged.
  defp render_execute(sql) do
    body =
      sql
      |> String.trim_trailing()
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ""
        line -> "    " <> line
      end)

    "    execute(\"\"\"\n" <> body <> "\n    \"\"\")\n"
  end
end
