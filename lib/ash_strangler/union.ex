# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Union do
  @moduledoc """
  One canonical relation backed by several legacy branches and one owned branch.

      defmodule Clinic.Visits do
        use AshStrangler.Union

        union do
          schema "clinic"
          view "visits"

          column :patient, :string, null?: false
          column :visited_on, :date
          column :notes, :string

          legacy :north do
            twin Clinic.Legacy.NorthVisits
            phase :read_from_legacy
            refused_because "the north system writes these rows until its cutover"
            key :id, strategy: {:uuid_v5, namespace: "6b1e0c1e-7a54-5d8e-9b1a-3f6f1c9d2a10"}
            map :patient, from: :patient_name
            map :visited_on, from: :seen_on
            unmapped [:notes], because: "the north system keeps no notes"
          end

          legacy :south do
            twin Clinic.Legacy.SouthVisits
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

  `AshStrangler.Migration.statements/1` generates, in order: the owned table, a
  key index per legacy branch, the view (a `UNION ALL` of the branches that
  are still in it, with a `__branch` column naming each row's branch), and the
  `INSTEAD OF` insert, update and delete triggers. Point an Ash resource at the
  view with `migrate? false`.

  ## Writes

    * **Insert** lands in the owned branch. The trigger returns the stored
      row, so `RETURNING` is correct (the primary key and every default
      included). An insert that names a legacy branch is refused, unless that
      branch is at `:dual_write` and declares `insert_through`: then it lands
      in the legacy table, which allocates its own key, and `RETURNING`
      carries the view row of that key, `__branch` naming the branch.
    * **Update and delete of an owned row** go to the owned table.
    * **Update and delete of a legacy row** follow that branch's phase.
      `:read_from_legacy`: refused with the branch's `refused_because`, as
      `AshStrangler.Error.BranchWriteRefused`. `:dual_write`: carried to the
      legacy table through the key and the renamed columns; assigning a
      column that has no legacy column to write (an expression, a constant or
      an unmapped column) is refused.
    * `:read_from_new` and `:decommissioned`: the branch is no longer in the
      view. Its rows are expected to have been backfilled into the owned
      table first; the estate check E8 holds the cutover to that.

  ## Concurrency

  A phase is compiled into the trigger functions, so moving a branch is a
  `CREATE OR REPLACE FUNCTION`, which is transactional DDL. A write that
  fires its trigger before the migration commits runs under the old phase and
  one that fires after runs under the new one. An insert naming a branch with
  no `insert_through` never reads a branch's phase, so it always succeeds in
  the owned branch; a route declared with `insert_through` is compiled into
  the same function, so declaring or removing one is a function replace, not a
  trigger change. Two concurrent owned inserts do not interact. Two inserts of the
  same supplied key conflict on the owned table's primary key (`23505`).
  `AshStrangler.Union.Info` has the declarations; the keys of different
  branches must not collide, which the verifier checks for equal namespaces.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshStrangler.Union.Dsl]]
end
