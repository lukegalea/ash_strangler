# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.UnionEdges.EastVisits do
  @moduledoc """
  Twin of `union_edges.east_visits`: an integer `code` next to the text `name`, for the
  union write-back edges. The table is created inside the test's transaction.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.Clinic.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "east_visits"
    schema "union_edges"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :code, :integer, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.UnionEdges do
  @moduledoc "Fixtures for the union write-back edge tests."

  @ns "3c1f0a52-9d1e-5a77-8f0e-2b6d4c7a9e11"

  @doc "Legacy DDL, run inside the test's transaction."
  def ddl do
    [
      "CREATE SCHEMA union_edges",
      "CREATE TABLE union_edges.east_visits (id integer PRIMARY KEY, name text NOT NULL, code integer)"
    ]
  end

  @doc "Source of a union over the east twin, one `dual_write` branch; `mappings` is the branch body."
  def source(module, columns, mappings) do
    """
    defmodule #{module} do
      use AshStrangler.Union

      union do
        schema "union_edges"
        view "visits"

        #{columns}

        legacy :east do
          twin AshStrangler.Test.UnionEdges.EastVisits
          phase :dual_write
          refused_because "the east system writes these rows until its cutover"
          key :id, strategy: {:uuid_v5, namespace: "#{@ns}"}
          #{mappings}
        end

        owned :native
      end
    end
    """
  end
end
