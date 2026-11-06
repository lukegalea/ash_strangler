# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.ClinicDerived.Keys do
  @moduledoc "The registry of the derived-rows fixture: one logical kind per derived view."
  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x0C11
    kind :clinic, 0x001, parts: [{"clinic_derived.clinics.id", 32}], tenant?: true
    kind :site, 0x002, parts: [{"clinic_derived.sites.id", 32}]
    logical(:staff, 0x010)
    logical(:property, 0x011)
  end
end

defmodule AshStrangler.Test.ClinicDerived.Legacy do
  @moduledoc "Domain of the derived-rows fixture's twin."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshStrangler.Test.ClinicDerived.Legacy.Visits do
  @moduledoc "Twin of `clinic_derived.visits`."
  use Ash.Resource,
    domain: AshStrangler.Test.ClinicDerived.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "visits"
    schema "clinic_derived"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :lead_nurse, :string, public?: true
    attribute :booked_at, :utc_datetime_usec, public?: true
    attribute :details, :map, public?: true
    attribute :metadata, :map, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.ClinicDerived.Staff do
  @moduledoc "A slot, a synthesized row and text elements of one legacy row."
  use AshStrangler.Derived

  derived do
    schema "clinic_derived"
    view "staff"
    twin AshStrangler.Test.ClinicDerived.Legacy.Visits
    registry(AshStrangler.Test.ClinicDerived.Keys)
    kind :staff
    from [:id]

    column :visit, :integer, null?: false
    column :person, :string
    column :role, :string
    column :position, :integer

    slot :lead do
      filter expr(not is_nil(lead_nurse))
      map :visit, from: :id
      map :person, from: :lead_nurse
      constant :role, "lead"
      unmapped [:position], because: "a slot has no position"
    end

    synthesized :booked do
      filter expr(not is_nil(booked_at))
      map :visit, from: :id
      constant :person, "front desk"
      constant :role, "booked"
      unmapped [:position], because: "a synthesized row has no position"
    end

    element :guest do
      from :details
      path(["guests"])
      type :text
      value(:person)
      ordinal(:position)
      map :visit, from: :id
      constant :role, "guest"
    end
  end
end

defmodule AshStrangler.Test.ClinicDerived.Properties do
  @moduledoc "Integer elements of a jsonb array, behind the integer guard."
  use AshStrangler.Derived

  derived do
    schema "clinic_derived"
    view "properties"
    twin AshStrangler.Test.ClinicDerived.Legacy.Visits
    registry(AshStrangler.Test.ClinicDerived.Keys)
    kind :property
    from [:id]
    filter expr(id > 0)
    tenant :clinic

    column :clinic, :uuid, null?: false
    column :visit, :integer, null?: false
    column :property, :integer, null?: false

    element :listed do
      from :metadata
      path(["propertyIds"])
      type :integer
      value(:property)
      tenant_of(:clinic, kind: {AshStrangler.Test.ClinicDerived.Keys, :clinic}, from: :id)
      map :visit, from: :id
    end
  end
end

defmodule AshStrangler.Test.ClinicDerived do
  @moduledoc "The derived-rows fixture: legacy DDL and the generated views."

  @doc "The legacy DDL the fixture reads."
  def legacy_ddl do
    [
      "DROP SCHEMA IF EXISTS clinic_derived CASCADE",
      "CREATE SCHEMA clinic_derived",
      """
      CREATE TABLE clinic_derived.visits (
        id integer PRIMARY KEY, lead_nurse text, booked_at timestamptz, details jsonb, metadata jsonb
      )
      """
    ]
  end

  @doc "Installs the fixture. Committed."
  def install! do
    for sql <- legacy_ddl(), do: AshStrangler.TestRepo.query!(sql)

    for module <- [
          AshStrangler.Test.ClinicDerived.Staff,
          AshStrangler.Test.ClinicDerived.Properties
        ],
        %{up: up} <- AshStrangler.Migration.statements(module) do
      AshStrangler.TestRepo.query!(up)
    end
  end
end
