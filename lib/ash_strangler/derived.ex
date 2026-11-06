# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Derived do
  @moduledoc """
  Canonical rows derived from the rows of one legacy relation: zero or more
  for each legacy row, as a read-only view.

      defmodule Clinic.VisitStaff do
        use AshStrangler.Derived

        derived do
          schema "clinic"
          view "visit_staff"
          twin Clinic.Legacy.Visits
          registry Clinic.Keys
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
            path ["guests"]
            type :text
            value :person
            ordinal :position
            map :visit, from: :id
            constant :role, "guest"
          end
        end
      end

  A **slot** is a fixed place in the legacy row; a **synthesized** row has no
  counterpart in the legacy data; an **element** is an entry of a jsonb array.
  The first two are one filtered select each, the third a lateral expansion.
  Every source answers every column (`map`, `constant`, `unmapped`, or for an
  element its `value` and `ordinal`).

  ## Keys

  The canonical key is a logical key (`AshStrangler.KeyKinds.logical/3`): a UUID
  version 5 over the `from` columns of the legacy row, the source's name and, for
  an element, its value, in a namespace made from the registry's estate tag and
  the kind's tag. Two sources never collide, and the key does not move when the
  row's other columns do. It cannot be decoded: reach the row through its
  parent.

  ## The integer guard

  `type: :integer` accepts an element only when it is a JSON number whose
  value is an integer in the 32-bit range. `12.5`, `1e10`, `"12"`, `true` and
  `null` are refused, not cast: a cast would round `12.5` to 13 and a value out
  of range would raise, failing every read of the view. Refusal is counted by the
  obligation `AshStrangler.Derived.Obligations` reports. `type: :text` accepts
  only JSON strings. A repeated element yields one row, the first.

  ## Writes

  A derived view is read-only (it has no triggers): the rows are a function of
  their parent, so a write goes to the parent's resource.

  `AshStrangler.Migration.statements/1` generates the view. List the module in
  `config :ash_strangler, deriveds: [...]` for `mix ash_strangler.gen.migration`.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshStrangler.Derived.Dsl]]
end
