# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.KeyDerivationTest do
  @moduledoc """
  The claim under test: **SQL and Elixir derive the same modern id, always.**

  This is what lets a strangler mapping avoid a legacy-id-to-modern-id lookup
  table, which would otherwise be a second source of truth and a join on every
  row. If the two implementations disagree for any input, `Ash.get/2` on an id
  computed in Elixir silently returns nothing for a row that exists.

  So the agreement is asserted over generated inputs — including non-ASCII ones,
  where a byte-versus-codepoint mistake would show up — rather than on a couple
  of hand-picked examples.
  """

  use AshStrangler.DataCase, async: false
  use ExUnitProperties

  alias AshStrangler.KeyDerivation
  alias AshStrangler.Test.Generators

  @namespace "6b1e8b2c-6f6d-4a4a-9f1a-5b0e0d3c4a71"

  describe "uuid_v5/2 against published vectors" do
    test "reproduces the RFC 4122 DNS-namespace test vector" do
      # The canonical published vector. If this passes, the implementation is
      # RFC 4122 version 5 rather than merely self-consistent -- which a test
      # comparing it only against Postgres could not distinguish.
      assert KeyDerivation.uuid_v5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "www.example.org") ==
               "74738ff5-5367-5958-9aee-98fffdcd1876"
    end

    test "sets the version and variant fields" do
      <<_::binary-size(14), version::binary-size(1), _::binary-size(4), variant::binary-size(1),
        _::binary>> = KeyDerivation.uuid_v5(@namespace, "legacy.users:1")

      assert version == "5"
      # RFC 4122 variant is the two high bits 0b10, so the nibble is 8..b.
      assert variant in ["8", "9", "a", "b"]
    end

    test "accepts a namespace with or without hyphens" do
      assert KeyDerivation.uuid_v5(@namespace, "x") ==
               KeyDerivation.uuid_v5(String.replace(@namespace, "-", ""), "x")
    end

    test "rejects a malformed namespace loudly" do
      assert_raise ArgumentError, ~r/expected a UUID/, fn ->
        KeyDerivation.uuid_v5("not-a-uuid", "x")
      end
    end
  end

  describe "agreement with Postgres uuid_generate_v5" do
    property "Elixir and SQL derive the same uuid for the same name" do
      check all(name <- Generators.adversarial_text(), max_runs: 50) do
        assert KeyDerivation.uuid_v5(@namespace, name) == postgres_uuid_v5(@namespace, name)
      end
    end

    property "Elixir and SQL agree on the full derived key for a legacy id" do
      check all(legacy_id <- StreamData.integer(1..1_000_000_000), max_runs: 50) do
        name = KeyDerivation.name("legacy.users", legacy_id)

        assert KeyDerivation.uuid_v5(@namespace, name) == postgres_uuid_v5(@namespace, name)
      end
    end

    test "agrees for non-ASCII names, where a byte/codepoint mistake would show" do
      # Hashing the codepoints rather than the UTF-8 bytes would still produce a
      # valid-looking uuid, and would still be stable in Elixir. It would just
      # never match the database.
      for name <- ["legacy.users:é☃", "légàcy.üsers:1", "legacy.users:👨‍👩‍👧‍👦"] do
        assert KeyDerivation.uuid_v5(@namespace, name) == postgres_uuid_v5(@namespace, name),
               "disagreed for #{inspect(name)}"
      end
    end
  end

  describe "derive/3" do
    test "qualifies the legacy id with the relation" do
      key = %AshStrangler.Key{
        attribute: :id,
        from: :id,
        strategy: {:uuid_v5, namespace: @namespace}
      }

      # Row 1 of two different tables must not collide -- otherwise a shared
      # namespace across a strangled schema produces silent id collisions
      # between unrelated entities.
      refute KeyDerivation.derive(key, "legacy.users", 1) ==
               KeyDerivation.derive(key, "legacy.orders", 1)
    end

    test "the :identity strategy passes the legacy key through" do
      key = %AshStrangler.Key{attribute: :id, from: :row_uuid, strategy: :identity}
      uuid = "0e6b0c1e-0c1e-4c1e-8c1e-0c1e0c1e0c1e"

      assert KeyDerivation.derive(key, "legacy.things", uuid) == uuid
    end
  end

  defp postgres_uuid_v5(namespace, name) do
    %Postgrex.Result{rows: [[uuid]]} =
      TestRepo.query!("SELECT uuid_generate_v5($1::uuid, $2)::text", [
        Ecto.UUID.dump!(namespace),
        name
      ])

    uuid
  end
end
