# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.LegacySchema do
  @moduledoc """
  Creates the `legacy` fixture schema and installs the **generated**
  compatibility view over it.

  The view SQL is not transcribed here. It is built by
  `AshStrangler.Sql.View.build/1` from the resource's own mapping and executed
  verbatim, which is the point: the golden-SQL tests assert what the generator
  *says*, and these assert that what it says actually *runs* and projects
  faithfully. A generator whose output is only ever compared against a fixture
  string is a generator nobody has run.

  Runs once from `test_helper.exs`, before the sandbox is put in `:manual`
  mode, so the DDL is committed and every test sees it. Tests then only insert
  and read rows, inside a sandbox transaction that rolls back.
  """

  alias AshStrangler.Test.DualWriteUser
  alias AshStrangler.Test.LegacyUser
  alias AshStrangler.Test.MixedUser
  alias AshStrangler.TestRepo

  # Two things here are load-bearing for the mapping, not incidental to it.
  #
  # `deleted_at` is deliberately `timestamp` (without time zone) while the
  # resource's attribute is `:utc_datetime_usec`: the mapping's `zone: "UTC"` is
  # what bridges them, and a mapping that only ever ran against an
  # already-timestamptz column would be testing nothing.
  #
  # `state` carries a CHECK constraint naming its five values, which is what
  # `mix ash_strangler.gen.twin` reads to give the twin attribute its `one_of` --
  # and the twin's `one_of` is what makes the `GetTotal` obligation decidable at
  # compile time rather than measurable only against data.
  @users_table """
  CREATE TABLE legacy.users (
    id               bigserial PRIMARY KEY,
    login            text NOT NULL,
    email            text,
    first_name       text,
    last_name        text,
    state            text NOT NULL DEFAULT 'active'
                       CHECK (state IN ('passive', 'pending', 'active', 'suspended', 'deleted')),
    deleted_at       timestamp,
    salt             text,
    crypted_password text,
    created_at       timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
  )
  """

  # The shared-rows fixture schema: `clm_parties` carries the tenant column a
  # contract derives from; `clm_contracts` is exactly the handoff §5 shape.
  # The CHECK on `value` exists so a test can force a legacy-side constraint
  # violation mid-command — the atomicity proof needs a failure that happens
  # INSIDE the legacy write, after the transaction opened.
  @clm_parties_table """
  CREATE TABLE legacy.clm_parties (
    id              uuid PRIMARY KEY,
    name            text NOT NULL,
    organization_id uuid NOT NULL
  )
  """

  @clm_contracts_table """
  CREATE TABLE legacy.clm_contracts (
    id                       uuid PRIMARY KEY,
    name                     text NOT NULL,
    description              text,
    effective_date           date,
    expiry_date              date,
    value                    numeric,
    payment_term             text,
    processed                boolean NOT NULL DEFAULT false,
    verified                 boolean NOT NULL DEFAULT false,
    archived                 timestamp,
    created_at               timestamp NOT NULL DEFAULT now(),
    service_provider_party_id uuid,
    client_party_id          uuid,
    renewal_start_date       date,
    renewal_end_date         date,
    metadata                 jsonb NOT NULL DEFAULT '{}',
    CONSTRAINT clm_contracts_value_non_negative CHECK (value IS NULL OR value >= 0)
  )
  """

  @doc """
  Drops and recreates the fixture schemas, tables, and the generated view.

  Destructive and idempotent, in that order. It owns the `legacy` and
  `strangler` schemas in the test database entirely.
  """
  def install! do
    # The key strategy's SQL calls `uuid_generate_v5`, and the email mapping
    # casts to `citext`. Declaring them in the repo's `installed_extensions/0`
    # only makes the migration generator emit `CREATE EXTENSION` into a
    # migration -- and this harness deliberately runs no migrations, so it
    # creates them itself.
    execute!(~s(CREATE EXTENSION IF NOT EXISTS "uuid-ossp"))
    execute!("CREATE EXTENSION IF NOT EXISTS citext")

    execute!("DROP SCHEMA IF EXISTS strangler CASCADE")
    execute!("DROP SCHEMA IF EXISTS legacy CASCADE")
    execute!("CREATE SCHEMA legacy")
    execute!("CREATE SCHEMA strangler")

    execute!(@users_table)
    execute!("CREATE UNIQUE INDEX index_users_on_login ON legacy.users (login)")
    execute!(@clm_parties_table)
    execute!(@clm_contracts_table)

    install_resource!(LegacyUser)
    install_resource!(DualWriteUser)
    # Three resources over one legacy table, which is the case this package exists
    # for -- and here it is also what lets `AshStrangler.MechanismTest` compare a
    # trigger-backed view against an auto-updatable one over the same rows.
    install_resource!(MixedUser)
    # The ledger fixture. Its statements create `legacy_change_events` and the
    # combined ledger-plus-wake trigger -- so if the generated ledger DDL does
    # not run against a real server, the suite fails to start, which is the
    # same blast radius every other fixture's DDL has.
    install_resource!(AshStrangler.Test.LedgerUser)
    # The extension-store fixture: its statements create the extension table
    # and the extension `LEFT JOIN` in the view -- the same verbatim-install
    # guarantee, for storage this package owns beside the legacy rows.
    install_resource!(AshStrangler.Test.ExtendedUser)
    # The shared-rows fixture: the entire mapping is a fragment (R1.1), the key
    # is :identity (R1.3), the tenant derives through the client party (R1.4),
    # and the extension table carries the columns the legacy schema has no
    # room for (R1.2).
    install_resource!(AshStrangler.Test.Contract)

    :ok
  end

  # Runs the SAME ordered statement list a generated migration would run, via
  # AshStrangler.Migration, executing it verbatim. Nothing here transcribes
  # SQL: if the generator emits something Postgres rejects, the whole suite
  # fails to start, which is the intended blast radius.
  defp install_resource!(resource) do
    resource
    |> AshStrangler.Migration.statements()
    |> Enum.each(&execute!(&1.up))
  end

  defp execute!(sql), do: TestRepo.query!(sql, [])
end
