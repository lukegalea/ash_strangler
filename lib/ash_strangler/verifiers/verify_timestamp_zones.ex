# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyTimestampZones do
  @moduledoc """
  `cast: :timestamptz` must say which zone the legacy column is in.

  ## Why this is an error rather than a default

  `(deleted_at)::timestamptz` on a `timestamp without time zone` column reads
  the stored value as wall-clock time in the **session's** `TimeZone` and
  converts to an instant accordingly. That setting is per-connection, so the
  same row, through the same view, yields different instants on different
  connections. Verified against PostgreSQL 17.10:

  | session `TimeZone` | resulting instant |
  |---|---|
  | `UTC` | `2024-06-15 12:00:00Z` |
  | `America/New_York` | `2024-06-15 16:00:00Z` |
  | `Australia/Lord_Howe` | `2024-06-15 01:30:00Z` |

  Ten and a half hours of drift, with no error and nothing to notice. A
  background job, a `psql` session, a replica with a different default, or a
  pooled connection that inherited a `SET TimeZone` each read something
  different.

  Defaulting to UTC would be right for most legacy schemas and silently wrong
  for the rest, moving every timestamp in the system by a fixed offset. Which
  zone a naive column is recorded in is a fact about the *old application*, not
  about its schema, so it cannot be read off the corpus and is not guessed —
  the mapping has to say, where the decision is reviewable.

  This is the same move `writable? false` + `because:` makes: force the
  ambiguity into the open rather than resolving it invisibly.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    if AshStrangler.Info.strangled?(dsl) do
      dsl
      |> AshStrangler.Info.mappings()
      |> Enum.filter(&(&1.cast == :timestamptz and is_nil(&1.from_zone)))
      |> case do
        [] -> :ok
        offenders -> {:error, error(dsl, offenders)}
      end
    else
      :ok
    end
  end

  defp error(dsl, offenders) do
    first = List.first(offenders)

    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :map],
      message: """
      These mappings cast to `:timestamptz` without saying which time zone the
      legacy column is in:

        #{Enum.map_join(offenders, "\n  ", &inspect(&1.attribute))}

      A bare cast reads a naive `timestamp` as wall-clock time in whatever the
      reading connection's `TimeZone` happens to be, so the instant it produces
      differs per connection -- silently, and by a fixed offset.

      If the legacy column is naive, say what it is in:

          map #{inspect(first.attribute)}, #{inspect(first.column || first.from)},
            cast: :timestamptz, from_zone: "UTC"

      If it is already `timestamptz`, drop the cast instead -- it is a no-op,
      and `AT TIME ZONE` on an already-aware value converts it back to naive:

          map #{inspect(first.attribute)}, #{inspect(first.column || first.from)}
      """
    )
  end
end
