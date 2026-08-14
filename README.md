# AshStrangler

Strangler-fig migrations for Ash: map an Ash resource onto a legacy Postgres
schema and move it through the migration phases without hand-writing SQL.

> **Alpha (0.1.0).** This version verifies mappings and phase declarations, and
> generates the compatibility view for `:read_from_legacy`. It does not yet
> generate `INSTEAD OF` triggers, backfill, or notifications. See
> [Scope](#scope).

## The problem

You have a legacy database you do not own, and a new Ash application that has to
read and eventually write it. The strangler-fig pattern says: put a compatibility
layer in front of the old schema, move behaviour across it one piece at a time,
and remove the old thing when nothing reaches it any more.

In Postgres that layer is a view, plus — sometimes — `INSTEAD OF` triggers. Both
are easy to write and easy to get subtly wrong in ways that do not fail. This
package makes the mapping declarative, and checks the parts that bite.

## Scope

| | 0.1 |
|---|---|
| Verify mappings and phases at compile time | ✅ |
| `mix ash_strangler.check` pre-flight report | ✅ |
| Generate views (`:read_from_legacy`) | ✅ |
| Generate `INSTEAD OF` triggers (`:dual_write`) | planned |
| The reversed view (`:read_from_new`) | planned |
| Backfill, reconciler, notifications | planned |

Verification shipped first on purpose. It was useful on its own against a
hand-written strangler migration, and it meant the generator got built against
an oracle rather than alongside one. View generation is deliberately narrower
than a full "expand" step: no triggers, no writes, no notifications yet — a
`:read_from_legacy` resource is read-only, and the verifiers already reject an
attempt to write to one.

## Usage

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStrangler.Resource]

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :full_name, :string, public?: true
    attribute :archived_at, :utc_datetime_usec
  end

  identities do
    identity :unique_email, [:email]
  end

  strangler do
    phase :read_from_legacy

    source "legacy.users" do
      key :id, from: "id", strategy: {:uuid_v5, namespace: "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"}

      map :email, "email", cast: :citext
      map :archived_at, "deleted_at", cast: :timestamptz

      map :full_name do
        from "coalesce(first_name,'') || ' ' || coalesce(last_name,'')"
        writable? false
        because "Not decomposable: 'de la Cruz' splits wrong, and no rule fixes it."
      end

      index "index_users_on_email", unique: true, columns: ["email"]
    end
  end
end
```

Add `postgres do table "users" ... end` as usual, then:

```bash
mix ash_strangler.check
mix ash.codegen add_users_view
```

`ash.codegen` finds the view and its expression index through the ordinary
`custom_statements` mechanism — no separate task, no separate migration
folder:

```sql
-- statement :strangler_users_view
CREATE OR REPLACE VIEW "public"."users" AS
SELECT
  uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text) AS id,
  id AS __legacy_id,
  (email)::citext AS email,
  coalesce(first_name,'') || ' ' || coalesce(last_name,'') AS full_name,
  (deleted_at)::timestamptz AS archived_at
FROM legacy.users;

-- statement :strangler_users_key_index
CREATE INDEX IF NOT EXISTS strangler_users_key_idx ON legacy.users
  (uuid_generate_v5('6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71'::uuid, 'legacy.users:' || id::text));
```

`__legacy_id` is unused in this phase — `:read_from_legacy` is read-only, and
the verifiers reject a write to it at compile time — but it costs nothing to
expose now: every later phase's `INSTEAD OF` triggers key off it rather than
inverting the derived uuid.

Every attribute must appear in that `SELECT`, mapped, constant, or
`unmapped`, with no exception for attributes the resource keeps private — a
view cannot leave a column out the way `VerifyCompleteMapping` lets a private
attribute go unmentioned, so generating one is a strictly stronger check than
compiling one.

## What the verifiers catch

Each exists because the mistake it catches **does not fail on its own**.

**An attribute nobody mapped.** The convenient behaviour is to select `NULL`.
That is also how a strangler migration loses data silently: somebody adds an
attribute, the view keeps compiling, and the column reads NULL for every legacy
row. Omissions must be declared with a reason.

**A computed mapping that claims to be writable.** Postgres cannot invert
`first || ' ' || last`, and neither can this package. Either supply the inverse
or declare it read-only — and `because:` is required because that text is shown
to whoever attempts the write.

**An identity the database does not enforce.** Ash will use it to plan upserts
and to report "has already been taken" while Postgres accepts duplicates. An
identity must map to a declared unique index.

**Upserts on a trigger-backed mapping.** See below — this one is the sharpest.

## `writes:` is a trade, not an option

How writes reach the base table is derived from the mapping shape, and can be
overridden. **Both settings cost something**, which is why the package refuses to
pick silently when you declare one:

| | `:auto` (view auto-updatability) | `:triggers` (`INSTEAD OF`) |
|---|---|---|
| `INSERT … ON CONFLICT` | works | **broken** |
| `RETURNING` | correct | correct only if the trigger returns the row |
| `WITH CHECK OPTION` | enforced | **not enforced** |
| Governs every write | no — `MERGE` bypasses the mapping | yes |
| Usage counter ("is legacy dead?") | unavailable | available |

The upsert row is the one that surprises people. Against a view with an
`INSTEAD OF` trigger, `ON CONFLICT DO NOTHING` is **accepted and then does
nothing** — no error, no row. `DO UPDATE` at least fails loudly.

### This collides with `ash_authentication`

Verified against 4.14.1:

- The **`password`** strategy does not upsert. Password-only authentication is
  migratable on the trigger path — the common case for a legacy monolith.
- The **`oauth2`** and **`oidc`** strategies **cannot be defined without an
  upsert**: their transformer validates `upsert? true` and a non-nil
  `upsert_identity`. There is no configuration that avoids it.
- The **`UserIdentity`** resource upserts unconditionally.

So OAuth2 and `INSTEAD OF` triggers are mutually exclusive, and adding OAuth2 to
a resource already on the trigger path is a breaking change. `VerifyNoUpserts`
says this in the error rather than reporting "action `:register_with_oauth2`
requires upserts", which would be true and useless.

## Installation

```elixir
def deps do
  [{:ash_strangler, "~> 0.1"}]
end
```

Add `:ash_strangler` to `import_deps` in `.formatter.exs`.

## Status and stability

Alpha. The DSL will change. Pin an exact version.

By the tier rules of the project this was extracted from, it is **tier 3**:
isolate it behind a seam and keep removal to a deletion until it has real
deployments.

## License

MIT.
