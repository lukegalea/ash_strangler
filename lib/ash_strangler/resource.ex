defmodule AshStrangler.Resource do
  @moduledoc """
  Ash resource extension for strangler-fig migrations.

      use Ash.Resource,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStrangler.Resource]

  Adds the `strangler` section (see `AshStrangler.Dsl`) and the verifiers that
  decide whether a mapping is legal.

  ## What this version does

  **Verification only.** It checks mappings and phase transitions; it does not
  yet generate SQL. That is deliberate — the checks are useful on their own
  against a hand-written strangler migration, and shipping them first means the
  generator is built against an oracle rather than alongside one.
  """

  use Spark.Dsl.Extension,
    sections: AshStrangler.Dsl.sections(),
    verifiers: [
      AshStrangler.Verifiers.VerifyCompleteMapping,
      AshStrangler.Verifiers.VerifyWritableMappingsReversible,
      AshStrangler.Verifiers.VerifyNoUpserts,
      AshStrangler.Verifiers.VerifyIdentitiesBacked,
      AshStrangler.Verifiers.VerifyPhaseTransition
    ]
end
