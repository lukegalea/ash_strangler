defmodule AshStrangler.Transformers.DeriveStatements do
  @moduledoc """
  Derives the compatibility view (and expression index, where the key strategy
  needs one) from the `strangler` mapping and injects them into
  `[:postgres, :custom_statements]` -- see `AshStrangler.Sql.View` for the SQL
  itself and the plan's §6.1 for why `custom_statements` is the injection point
  at all (mechanically unguarded, verified against the vendored `spark` source;
  `mix ash.codegen` then picks the statements up like any other schema change).

  Only acts in `:read_from_legacy`. `:dual_write`'s `INSTEAD OF` triggers and
  `:read_from_new`'s reversed view are later steps.

  A no-op -- not an error -- for a resource with no `strangler` mapping at all,
  or one not using `AshPostgres.DataLayer` (e.g. the ETS resources the
  verifier test suite builds), so nothing outside a strangled Postgres resource
  is affected by this transformer existing.

  ## Ordering

  Declares `after?/1 -> true` for every other transformer, i.e. runs last. The
  view's `SELECT` list must cover every attribute on the *fully* transformed
  resource (§6.2): if some other extension's transformer adds an attribute
  after this one runs, the view silently omits it. Running last is the
  mitigation available to a single extension that cannot know what else a
  consumer combines it with; `AshStrangler.Verifiers.VerifyCompleteMapping`
  (a verifier, guaranteed to run after every transformer, from any extension)
  is the actual safety net.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    if applies?(dsl) do
      derive(dsl)
    else
      {:ok, dsl}
    end
  end

  defp applies?(dsl) do
    AshStrangler.Info.strangled?(dsl) and
      AshStrangler.Info.strangler_phase!(dsl) == :read_from_legacy and
      Transformer.get_persisted(dsl, :data_layer) == AshPostgres.DataLayer
  end

  defp derive(dsl) do
    %{view: view, key_index: key_index} = AshStrangler.Sql.View.build(dsl)

    dsl
    |> add_statement(view)
    |> add_statement(key_index)
    |> then(&{:ok, &1})
  rescue
    e in ArgumentError ->
      {:error,
       Spark.Error.DslError.exception(
         module: Transformer.get_persisted(dsl, :module),
         path: [:strangler],
         message: Exception.message(e)
       )}
  end

  defp add_statement(dsl, nil), do: dsl

  defp add_statement(dsl, %{name: name, up: up, down: down}) do
    statement =
      Transformer.build_entity!(
        AshPostgres.DataLayer,
        [:postgres, :custom_statements],
        :statement,
        name: name,
        up: up,
        down: down
      )

    Transformer.add_entity(dsl, [:postgres, :custom_statements], statement)
  end
end
