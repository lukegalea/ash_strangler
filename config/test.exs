# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

# Port comes from the environment because the development Postgres is started
# by devenv, which shifts it when 5432 is already taken. Never hardcode it.
#
# The host override is deliberately NOT named `PGHOST`. That is libpq's own
# variable, and CI sets it to the service-container name `postgres` -- a
# hostname that only resolves for jobs running inside a container, which these
# do not. Reading it made every CI test fail with
# `tcp connect (postgres:5432): non-existing domain`. `DB_HOST` matches the
# `DB_USER`/`DB_PASSWORD` pair below and collides with nothing.
config :ash_strangler, AshStrangler.TestRepo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "ash_strangler_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Ash loads relationships and calculations in spawned Tasks by default. Those
# are separate processes, so they are not owners of the sandbox connection and
# hit `DBConnection.OwnershipError` intermittently -- the failure is a flake,
# not a consistent error, which is the worst kind. Disabling async in test is
# the standard fix and is what `mix igniter.install ash_postgres` writes.
config :ash, disable_async?: true

config :logger, level: :warning

# Lets `mix ash.codegen` run against the fixture resources in the test
# environment, so the generated migration itself can be inspected.
config :ash_strangler, ash_domains: [AshStrangler.Test.Domain]
