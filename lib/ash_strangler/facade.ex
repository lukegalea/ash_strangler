# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Facade do
  @moduledoc """
  An Ash resource with no storage of its own, giving a different vocabulary to
  the rows of one source resource.

      defmodule MyApp.WorkItem do
        use Ash.Resource,
          domain: MyApp.Domain,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshStrangler.Facade]

        attributes do
          attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
          attribute :title, :string, public?: true
          attribute :state, :atom, public?: true, constraints: [one_of: [:new, :finished]]
          attribute :effort_minutes, :integer, public?: true
          attribute :licence_number, :string, public?: true, sensitive?: true
        end

        facade do
          source MyApp.Task            # the row source (an Ash resource)
          read_action :read            # the source's read action; default :read

          map :id, from: :id
          map :title, from: :name
          decode :state, from: :status, values: %{done: :finished}
          map :effort_minutes, from: :estimate_minutes
          map :licence_number, from: :number

          hide :internal_notes, because: "Not part of this vocabulary."
          defer :legacy_ref

          # Writes: each is a generic action on the facade that runs ONE named
          # source action.
          write :finish, via: :complete, sets: [state: :finished]              # by value
          write :set_estimate, via: :set_estimate, accepts: [:effort_minutes]  # by acceptance
        end
      end

  A facade reads by calling the source's read action as the caller, and each
  `write` runs one named source action as the caller. It declares no rule
  about who may see or change anything: the source's policies and field
  policies decide, because every fact keeps one record, on the source. The
  mapping grammar is the strangler's (`AshStrangler.Dsl.mapping_entities/0`),
  so a lens means the same thing over a view and over an Ash source.

  | | |
  |---|---|
  | what a read does | `AshStrangler.Facade.Read` |
  | what a write does | `AshStrangler.Facade.Write` |
  | what the declaration *means* | `AshStrangler.Facade.Info`, over `AshStrangler.Lens` |
  | what is *legal* | the modules under `AshStrangler.Facade.Verifiers` |
  | what can be *proven* about it | `AshStrangler.Obligations.over/3` |

  Offset pagination only, and no count: Ash reports none for a manual read.
  One write is one source action. `as_of` is read-only on a facade — forwarded
  over a temporal source, refused over any other — and refused on every write.
  A hop chain over a facade source is read hop by hop: see
  `AshStrangler.Facade.Info.hops/1`.
  """

  use Spark.Dsl.Extension,
    sections: AshStrangler.Facade.Dsl.sections(),
    transformers: [AshStrangler.Facade.Transformers.AddReadAndWrites],
    verifiers: [
      AshStrangler.Facade.Verifiers.VerifySource,
      AshStrangler.Facade.Verifiers.VerifyOwnShape,
      AshStrangler.Facade.Verifiers.VerifySensitive,
      AshStrangler.Facade.Verifiers.VerifyWrites,
      AshStrangler.Facade.Verifiers.VerifyEstate,
      AshStrangler.Facade.Verifiers.VerifyAuthorization,
      AshStrangler.Facade.Verifiers.VerifyObligations
    ]
end
