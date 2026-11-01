# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.GenTwinTest do
  @moduledoc """
  `mix ash_strangler.gen.twin --from-snapshot`, end to end through Igniter: no
  database, a pinned twin, and secrets that survive regeneration because they
  are read back from the twin's source.
  """

  use ExUnit.Case, async: true

  import Igniter.Test

  @catalog "test/fixtures/snapshot/clinic/catalog.json"
  @path "lib/clinic/patients.ex"

  defp generate(igniter, extra) do
    Igniter.compose_task(
      igniter,
      "ash_strangler.gen.twin",
      [
        "--from-snapshot",
        @catalog,
        "--relation",
        "clinic.patients",
        "--module",
        "Clinic.Patients",
        "--domain",
        "Clinic.Legacy",
        "--repo",
        "AshStrangler.TestRepo"
      ] ++ extra
    )
  end

  # The test project has no Spark formatter configuration, so the DSL comes
  # back with parentheses; the patterns accept both spellings.
  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  test "generates a pinned twin from the snapshot alone, leaving the secret out" do
    igniter =
      test_project()
      |> generate(["--secret", "clinic.patients.password_digest"])
      |> assert_creates(@path)

    twin = content(igniter, @path)

    assert twin =~ ~r/snapshot\(?"#{Regex.escape(@catalog)}"/
    assert twin =~ ~r/secrets\(?\[:password_digest\]/
    assert twin =~ ~r/attribute\(?:email, :ci_string/
    refute twin =~ ~r/attribute\(?:password_digest/
    assert twin =~ "--from-snapshot #{@catalog}"
  end

  test "regeneration keeps the secrets the existing twin declares" do
    igniter =
      test_project()
      |> generate(["--secret", "clinic.patients.password_digest"])
      |> apply_igniter!()
      |> generate([])

    twin = content(igniter, @path)

    assert twin =~ ~r/secrets\(?\[:password_digest\]/
    refute twin =~ ~r/attribute\(?:password_digest/
  end

  test "a malformed --secret is an issue, not a guess" do
    test_project()
    |> generate(["--secret", "password_digest"])
    |> assert_has_issue("`--secret` takes schema.table.column, got \"password_digest\"")
  end
end
