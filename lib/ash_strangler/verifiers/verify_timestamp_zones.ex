# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Verifiers.VerifyTimestampZones do
  @moduledoc """
  A naive legacy timestamp read as an instant must say which zone it is in.

  ## Why this is an error rather than a default

  `(deleted_at)::timestamptz` on a `timestamp without time zone` column reads the
  stored value as wall-clock time in the **session's** `TimeZone` and converts to an
  instant accordingly. That setting is per-connection, so the same row, through the
  same view, yields different instants on different connections. Measured against
  PostgreSQL 17.10, one stored value:

  | session `TimeZone` | resulting instant |
  |---|---|
  | `UTC` | `2024-06-15 12:00:00+00` |
  | `America/New_York` | `2024-06-15 12:00:00-04` |
  | `Australia/Lord_Howe` | `2024-06-15 12:00:00+10:30` |

  Fourteen and a half hours of spread, with no error and nothing to notice. A
  background job, a `psql` session, a replica with a different default, or a pooled
  connection that inherited a `SET TimeZone` each read something different.

  Defaulting to UTC would be right for most legacy schemas and silently wrong for
  the rest, moving every timestamp in the system by a fixed offset. Which zone a
  naive column is recorded in is a fact about the *old application*, not about its
  schema, so it cannot be read off the corpus and is not guessed — the mapping has
  to say, where the decision is reviewable.

  ## What changed, and why this verifier had to come back

  In 0.1 the cast was typed by hand, so this refused `cast: :timestamptz` without a
  `from_zone:`. Deriving the cast from the twin's column type against the target
  attribute's type removed the typing — and quietly reintroduced exactly what the
  verifier existed to refuse: a `:naive_datetime` twin column feeding a
  `:utc_datetime_usec` attribute derives `(deleted_at)::timestamptz`, the
  session-dependent form, and every other verifier passes it.

  That is worth recording rather than fixing silently. Deriving a decision from
  types is the right move and it does not inherit the *judgement* the hand-typed
  version carried: the type system can see that a cast is needed and cannot see that
  one particular cast is non-deterministic. A derived layer still needs the
  refusals the declared one had.

  ## The form it demands is also the only one that can be indexed

  `timezone(text, timestamp without time zone)` — what `zone:` renders — is
  `IMMUTABLE`. The one-argument `timezone(timestamp without time zone)` that a bare
  `::timestamptz` resolves to is `STABLE`, and PostgreSQL refuses a `STABLE`
  function in an index expression. So this is not only preventing drift; the cast it
  refuses could never have carried an expression index.

  This is the same move `read_only?` + `because:` makes: force the ambiguity into
  the open rather than resolving it invisibly.
  """

  use Spark.Dsl.Verifier

  alias AshStrangler.Info
  alias AshStrangler.Map, as: MapEntry
  alias Spark.Dsl.Verifier

  @naive [Ash.Type.NaiveDatetime]
  @aware [Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec]

  @impl true
  def verify(dsl) do
    if Info.strangled?(dsl) do
      twin = Info.twin(dsl)
      attributes = Map.new(Ash.Resource.Info.attributes(dsl), &{&1.name, &1})

      dsl
      |> Info.mappings()
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case check(entry, twin, attributes) do
          :ok -> {:cont, :ok}
          {:error, direction} -> {:halt, {:error, error(dsl, entry, direction)}}
        end
      end)
    else
      :ok
    end
  rescue
    # A stale or unusable twin is `VerifyTwin`'s finding, reported with the column
    # named. Failing here as well would report one problem twice, in the less useful
    # of the two places.
    _ -> :ok
  end

  # Only a bare column mapping with no `zone:` can derive the offending cast. An
  # expression is the author's own, and `zone:` is the fix being demanded.
  defp check(%MapEntry{from: column, zone: nil} = entry, twin, attributes)
       when is_atom(column) and not is_nil(column) do
    legacy = twin_type(twin, column)
    target = attributes |> Map.get(entry.attribute, %{}) |> Map.get(:type)

    cond do
      legacy in @naive and target in @aware -> {:error, :reading}
      legacy in @aware and target in @naive -> {:error, :writing}
      true -> :ok
    end
  end

  defp check(_entry, _twin, _attributes), do: :ok

  defp twin_type(twin, column) do
    case Ash.Resource.Info.attribute(twin, column) do
      nil -> nil
      %{type: type} -> type
    end
  end

  defp error(dsl, entry, direction) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl, :module),
      path: [:strangler, :source, :map, entry.attribute],
      message: """
      The mapping for #{inspect(entry.attribute)} would derive a time-zone cast that is not deterministic.

      #{describe(direction, entry)}

      A bare cast reads a naive `timestamp` as wall-clock time in whatever the
      reading connection's `TimeZone` happens to be, so the instant it produces
      differs per connection -- silently, and by a fixed offset. Measured on 17.10,
      one stored value read as three different instants fourteen and a half hours
      apart.

      Say what zone the legacy column is recorded in:

          map #{inspect(entry.attribute)}, from: #{inspect(entry.from)}, zone: "UTC"

      That renders `AT TIME ZONE 'UTC'` in both directions, which is deterministic
      and -- unlike the cast -- `IMMUTABLE`, so it can carry an expression index.

      If the legacy column is genuinely already time-zone aware, the attribute
      should be too; the two types disagreeing is what asked for a cast at all.
      """
    )
  end

  defp describe(:reading, entry) do
    "The twin's #{inspect(entry.from)} is naive and #{inspect(entry.attribute)} is an instant, " <>
      "so the view would read it as `(#{entry.from})::timestamptz`."
  end

  defp describe(:writing, entry) do
    "The twin's #{inspect(entry.from)} is an instant and #{inspect(entry.attribute)} is naive, " <>
      "so the projection would discard the zone rather than convert it."
  end
end
