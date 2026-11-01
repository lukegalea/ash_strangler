# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Estate.Plugin do
  @moduledoc """
  The host's half of the estate checks.

  The estate checks only what this package can know: the catalog, the
  declared dispositions and the mappings of its resources. A host has
  machinery of its own that reads legacy rows without mapping them, and rules
  of its own about what may be strangled. A plug-in brings both:

    * `claims/2` returns the columns that machinery reads, as
      `AshStrangler.Estate.Claim`s of a kind the host names (`:projected`,
      `:access_input`, `:test_oracle`, ...). A claimed column is computed, like
      a mapped one: it needs no declaration, and a declaration beside it is a
      conflict. A claim may not use a kind the estate computes or declares
      itself (`AshStrangler.Estate.Claim.reserved_kinds/0`).
    * `check/1` receives the finished `AshStrangler.Estate.Report` and
      returns problems, as messages. Typical checks: a vocabulary rule over the
      new model, a hazard list whose columns must carry one claim kind, or the
      reach of a user-facing surface through the resource graph.

  Both callbacks are optional. They run on every evaluation, which includes
  every `mix compile` when the `:ash_strangler_estate` compiler is enabled, so
  they must not touch a database.

      defmodule MyApp.Legacy.EstateRules do
        @behaviour AshStrangler.Estate.Plugin

        alias AshStrangler.Estate.Claim

        @impl true
        def claims(_estate, _catalog) do
          for column <- ["id", "name"] do
            %Claim{relation: "lending.branches", column: column, kind: :projected, by: MyApp.Branches}
          end
        end

        @impl true
        def check(report) do
          for {"lending.loans", relation} <- report.relations,
              relation.declared != nil,
              do: "lending.loans must be strangled, not declared \#{relation.declared.kind}"
        end
      end
  """

  @doc "Columns the host's own machinery reads. `catalog` is the decoded `catalog.json`."
  @callback claims(estate :: module(), catalog :: map()) :: [AshStrangler.Estate.Claim.t()]

  @doc "Problems with the estate as evaluated, as messages. `[]` when there are none."
  @callback check(report :: AshStrangler.Estate.Report.t()) :: [String.t()]

  @optional_callbacks claims: 2, check: 1
end
