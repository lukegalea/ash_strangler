# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.Clinic.Legacy do
  @moduledoc "Domain of the clinic union fixture's twins."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshStrangler.Test.Clinic.Legacy.NorthVisits do
  @moduledoc "Twin of `clinic_union.north_visits`."
  use Ash.Resource,
    domain: AshStrangler.Test.Clinic.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "north_visits"
    schema "clinic_union"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :patient_name, :string, allow_nil?: false, public?: true
    attribute :clinic_id, :integer, public?: true
    attribute :site_id, :integer, public?: true
    attribute :seen_on, :date, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Clinic.Legacy.SouthVisits do
  @moduledoc "Twin of `clinic_union.south_visits`."
  use Ash.Resource,
    domain: AshStrangler.Test.Clinic.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "south_visits"
    schema "clinic_union"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :clinic_id, :integer, public?: true
    attribute :date, :date, public?: true
    attribute :remarks, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.Clinic do
  @moduledoc """
  The clinic union fixture: two legacy visit tables (north: read from legacy;
  south: dual write) and an owned branch, under one `clinic_union.visits` view.
  """

  @north_ns "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"
  @south_ns "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d"

  @doc "Source of a union module over the fixture, with the two branch phases given."
  def source(module, north_phase, south_phase, view \\ "visits") do
    """
    defmodule #{module} do
      use AshStrangler.Union

      union do
        schema "clinic_union"
        view #{inspect(view)}

        column :patient, :string, null?: false
        column :visited_on, :date
        column :notes, :string

        legacy :north do
          twin AshStrangler.Test.Clinic.Legacy.NorthVisits
          phase #{inspect(north_phase)}
          refused_because "the north system writes these rows until its cutover"
          key :id, strategy: {:uuid_v5, namespace: "#{@north_ns}"}
          map :patient, from: :patient_name
          map :visited_on, from: :seen_on
          unmapped [:notes], because: "the north system keeps no notes"
        end

        legacy :south do
          twin AshStrangler.Test.Clinic.Legacy.SouthVisits
          phase #{inspect(south_phase)}
          refused_because "the south system writes these rows until its cutover"
          key :id, strategy: {:uuid_v5, namespace: "#{@south_ns}"}
          map :patient, from: :name
          map :visited_on, from: :date
          map :notes, from: :remarks
        end

        owned :native
      end
    end
    """
  end

  @doc "The legacy DDL the fixture reads."
  def legacy_ddl do
    [
      "DROP SCHEMA IF EXISTS clinic_union CASCADE",
      "CREATE SCHEMA clinic_union",
      "CREATE TABLE clinic_union.north_visits (id integer PRIMARY KEY, patient_name text NOT NULL, seen_on date)",
      "CREATE TABLE clinic_union.south_visits (id integer PRIMARY KEY, name text NOT NULL, date date, remarks text)"
    ]
  end

  @doc "Installs the fixture: legacy tables, then everything the union generates. Committed."
  def install! do
    for sql <- legacy_ddl(), do: AshStrangler.TestRepo.query!(sql)

    for %{up: up} <- AshStrangler.Migration.statements(AshStrangler.Test.Clinic.Visits) do
      AshStrangler.TestRepo.query!(up)
    end
  end
end

defmodule AshStrangler.Test.Clinic.Visits do
  @moduledoc false
  use AshStrangler.Union

  union do
    schema "clinic_union"
    view "visits"

    column :patient, :string, null?: false
    column :visited_on, :date
    column :notes, :string

    legacy :north do
      twin AshStrangler.Test.Clinic.Legacy.NorthVisits
      phase :read_from_legacy
      refused_because "the north system writes these rows until its cutover"
      key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
      map :patient, from: :patient_name
      map :visited_on, from: :seen_on
      unmapped [:notes], because: "the north system keeps no notes"
    end

    legacy :south do
      twin AshStrangler.Test.Clinic.Legacy.SouthVisits
      phase :dual_write
      refused_because "the south system writes these rows until its cutover"
      key :id, strategy: {:uuid_v5, namespace: "0a1b2c3d-4e5f-5a6b-8c7d-9e0f1a2b3c4d"}
      map :patient, from: :name
      map :visited_on, from: :date
      map :notes, from: :remarks
    end

    owned :native
  end
end

defmodule AshStrangler.Test.Clinic.Visit do
  @moduledoc "An Ash resource over the union's view. Not strangler-mapped: the view is its table."
  use Ash.Resource,
    domain: AshStrangler.Test.Clinic.Legacy,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "visits"
    schema "clinic_union"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :patient, :string, allow_nil?: false, public?: true
    attribute :visited_on, :date, public?: true
    attribute :notes, :string, public?: true
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:id, :patient, :visited_on, :notes],
      update: [:patient, :visited_on, :notes]
    ]
  end
end
