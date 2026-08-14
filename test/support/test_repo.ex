# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.TestRepo do
  @moduledoc """
  The repo the round-trip tests run against. Test-env only.

  `min_pg_version/0` is the one `AshPostgres.Repo` callback with no default
  implementation, so it must be defined. 14 is this project's declared floor --
  the version `CREATE OR REPLACE TRIGGER` first appears in, which later phases
  need.
  """

  use AshPostgres.Repo,
    otp_app: :ash_strangler,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["uuid-ossp", "citext"]

  @impl true
  def prefer_transaction?, do: false
end
