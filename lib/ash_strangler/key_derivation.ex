defmodule AshStrangler.KeyDerivation do
  @moduledoc """
  Derives a resource's modern primary key from a legacy key, in Elixir.

  The SQL side of this lives in `AshStrangler.Sql.View`, which emits the same
  derivation as a view expression. **The two must agree exactly**, and that is
  not a nicety: it is the property that lets a strangler mapping avoid a lookup
  table. A lookup table would be a second source of truth and a join on every
  row, so the plan requires the derivation be deterministic and reproducible on
  both sides.

  Both sides build the hashed name through `name/2` here, so the format cannot
  drift between them by editing one and forgetting the other. `uuid_v5/2` is
  asserted against Postgres's own `uuid_generate_v5` in the test suite, over
  generated inputs including non-ASCII ones.

  ## Why this exists at all

  Without it, computing a record's id from a legacy id means asking the
  database. That is a round trip in the middle of code that usually has no
  reason to touch the database at all -- building a URL, deduplicating an
  import, correlating a webhook against a legacy id. With it, the derivation is
  a pure function.

      iex> AshStrangler.KeyDerivation.uuid_v5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "www.example.org")
      "74738ff5-5367-5958-9aee-98fffdcd1876"

  That is the published RFC 4122 test vector for the DNS namespace, which
  Postgres's `uuid_generate_v5` also reproduces.
  """

  alias AshStrangler.Key

  @doc """
  The modern id for `legacy_id` under `key`, for a source on `relation`.

  Mirrors `AshStrangler.Sql.View`'s generated key expression.
  """
  @spec derive(Key.t(), String.t(), term()) :: String.t()
  def derive(%Key{strategy: {:uuid_v5, namespace: namespace}}, relation, legacy_id) do
    uuid_v5(namespace, name(relation, legacy_id))
  end

  def derive(%Key{strategy: :identity}, _relation, legacy_id) do
    to_string(legacy_id)
  end

  def derive(%Key{strategy: strategy}, _relation, _legacy_id) do
    raise ArgumentError, """
    key strategy #{inspect(strategy)} is not yet implemented.

    Only `{:uuid_v5, namespace: "..."}` and `:identity` are supported.
    """
  end

  @doc """
  The name that gets hashed, for a `{:uuid_v5, ...}` key.

  Qualifying the legacy id with the relation is what stops row 1 of
  `legacy.users` and row 1 of `legacy.orders` deriving the same uuid.
  """
  @spec name(String.t(), term()) :: String.t()
  def name(relation, legacy_id), do: name_prefix(relation) <> to_string(legacy_id)

  @doc """
  Everything in the hashed name before the legacy id.

  Exists so the name format is defined in exactly one place. The Elixir side
  appends the id to this directly; the SQL side interpolates it into a
  concatenation (`'<prefix>' || id::text`) because it builds the name in the
  database at query time. Those are different enough in shape that the
  separator would otherwise be written out twice and could drift by editing one
  and forgetting the other -- which is a silent failure, because a mapping
  whose two sides disagree still compiles, still runs, and simply never finds
  any row.
  """
  @spec name_prefix(String.t()) :: String.t()
  def name_prefix(relation), do: "#{relation}:"

  @doc """
  RFC 4122 version 5 (SHA-1, name-based) UUID, as a lowercase hyphenated string.

  `namespace` is a UUID string; `name` is hashed as raw bytes, so a non-ASCII
  name hashes its UTF-8 encoding -- which is what Postgres does too, and is
  asserted rather than assumed.
  """
  @spec uuid_v5(String.t(), String.t()) :: String.t()
  def uuid_v5(namespace, name) when is_binary(namespace) and is_binary(name) do
    <<hashed::binary-size(16), _rest::binary>> =
      :crypto.hash(:sha, decode!(namespace) <> name)

    # Overwrite the 4-bit version field with 5 and the 2-bit variant field with
    # 0b10, per RFC 4122 §4.3, leaving every other bit of the hash intact.
    <<head::48, _version::4, middle::12, _variant::2, tail::62>> = hashed

    encode(<<head::48, 5::4, middle::12, 2::2, tail::62>>)
  end

  @doc """
  The 16 raw bytes of a UUID string, hyphens optional.

  Raises `ArgumentError` rather than returning an error tuple: a malformed
  namespace is a mistake in a DSL literal, caught the first time the mapping is
  exercised, not a runtime condition to handle.
  """
  @spec decode!(String.t()) :: binary()
  def decode!(uuid) when is_binary(uuid) do
    stripped = String.replace(uuid, "-", "")

    case Base.decode16(stripped, case: :mixed) do
      {:ok, <<bytes::binary-size(16)>>} ->
        bytes

      _ ->
        raise ArgumentError, "expected a UUID, got: #{inspect(uuid)}"
    end
  end

  defp encode(
         <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(6)>>
       ) do
    [a, b, c, d, e]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
