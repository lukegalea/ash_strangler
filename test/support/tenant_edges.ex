# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.TenantEdges.Keys do
  @moduledoc "The registry of the tenant-closure fixture: a tenant kind and a plain one."
  use AshStrangler.KeyKinds

  key_kinds do
    estate 0x7E01
    kind :clinic, 0x001, parts: [{"tenant_edges.clinics.id", 32}], tenant?: true
    kind :site, 0x002, parts: [{"tenant_edges.sites.id", 32}]
    logical(:property, 0x010)
  end
end

defmodule AshStrangler.Test.TenantEdges.Legacy do
  @moduledoc "Domain of the tenant-closure fixture's twins."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshStrangler.Test.TenantEdges.East do
  @moduledoc """
  Twin of `tenant_edges.east_visits`: `clinic_id` has a validated foreign key to the
  tenant kind's home column in the catalog fixture, `other_id` has none.
  """
  use Ash.Resource,
    domain: AshStrangler.Test.TenantEdges.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "east_visits"
    schema "tenant_edges"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :clinic_id, :integer, allow_nil?: false, public?: true
    attribute :other_id, :integer, public?: true
    attribute :patient, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshStrangler.Test.TenantEdges.West do
  @moduledoc "Twin of `tenant_edges.west_visits`, shaped like `East`."
  use Ash.Resource,
    domain: AshStrangler.Test.TenantEdges.Legacy,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Twin]

  postgres do
    table "west_visits"
    schema "tenant_edges"
    repo AshStrangler.TestRepo
    migrate? false
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :clinic_id, :integer, allow_nil?: false, public?: true
    attribute :other_id, :integer, public?: true
    attribute :patient, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end
