# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Resource do
  @moduledoc """
  Ash resource extension for strangler-fig migrations.

      use Ash.Resource,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

  Adds the `strangler` section (see `AshStrangler.Dsl`), the verifiers that
  decide whether a mapping is legal, and -- for `:read_from_legacy` on
  `AshPostgres.DataLayer` -- the transformer that derives the compatibility
  view.

  ## What this version does

  Verification, plus view generation for `:read_from_legacy` only. `:dual_write`
  `INSTEAD OF` triggers, the reversed `:read_from_new` view, backfill, the
  reconciler and the listener are later steps — see the plan's §11 step table.
  The checks were shipped first and stayed useful on their own against a
  hand-written strangler migration; the generator is built against that oracle
  rather than alongside it.
  """

  use Spark.Dsl.Extension,
    sections: AshStrangler.Dsl.sections(),
    transformers: [
      AshStrangler.Transformers.MarkKeyGenerated
    ],
    verifiers: [
      AshStrangler.Verifiers.VerifyCompleteMapping,
      AshStrangler.Verifiers.VerifyNotMigrated,
      AshStrangler.Verifiers.VerifyTimestampZones,
      AshStrangler.Verifiers.VerifyWritableMappingsReversible,
      AshStrangler.Verifiers.VerifyNoUpserts,
      AshStrangler.Verifiers.VerifyReverseMappable,
      AshStrangler.Verifiers.VerifyIdentitiesBacked,
      AshStrangler.Verifiers.VerifyPhaseTransition
    ]
end
