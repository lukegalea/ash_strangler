# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.CodegenTest do
  @moduledoc """
  `AshStrangler.Codegen.pending/1`: rendered statements against a snapshot
  directory, with no database — the comparison that `mix ash.codegen --check`,
  `--dry-run` and `mix ash_strangler.gen.migration` share.

  Coverage is opt-in by attachment: the default test config lists
  `AshStrangler.Test.Domain`, which does not attach the extension, so every
  attached-behaviour test opts in by putting `AshStrangler.Test.CodegenDomain`
  into `:ash_domains` for the duration of one test.
  """

  use ExUnit.Case, async: false

  alias AshStrangler.Codegen

  @resource AshStrangler.Test.LegacyUser
  @uncovered AshStrangler.Test.Library.Member
  @repo_dir "test_repo"

  describe "opt-in by attachment" do
    test "an application whose domains do not attach the extension renders nothing" do
      # The default test config's domain holds strangled resources, so this
      # asserts the extension stays silent despite having work to do.
      assert Codegen.attached?() == false
      assert Codegen.rendered() == %{}
      assert Codegen.pending() == []
    end

    test "a domain that attaches the extension opts its resources in" do
      attach!()
      resource = @resource

      assert Codegen.attached?() == true
      assert %{^resource => statements} = Codegen.rendered()
      assert statements != []

      Enum.each(statements, fn statement ->
        assert is_atom(statement.name)
        assert is_binary(statement.up) and statement.up != ""
        assert is_binary(statement.down) and statement.down != ""
      end)
    end

    test "resources of unattached domains stay uncovered" do
      attach!()

      # `@uncovered` is strangled too, but its domain does not attach.
      assert Codegen.covered_resources([@resource, @uncovered]) == [@resource]
    end
  end

  describe "snapshot paths" do
    test "one directory per repo, one file per resource" do
      assert Codegen.snapshot_path("/base", @resource) ==
               "/base/#{@repo_dir}/ash_strangler_test_legacy_user.json"
    end
  end

  describe "write_snapshots!/1" do
    test "writes the reference format, and freshly written snapshots are clean" do
      attach!()
      root = tmp_root()

      [path] = Codegen.write_snapshots!(snapshot_root: root)

      assert path == Codegen.snapshot_path(root, @resource)

      doc = path |> File.read!() |> Jason.decode!()
      assert doc["resource"] == "AshStrangler.Test.LegacyUser"

      assert [%{"name" => name, "up" => up} | _] = doc["statements"]
      assert is_binary(name) and is_binary(up)

      # Writing twice changes nothing, and nothing is pending against it.
      assert Codegen.write_snapshots!(snapshot_root: root) == [path]
      assert Codegen.pending(snapshot_root: root) == []
    end

    test "the :resources option drops resources the extension does not cover" do
      attach!()
      root = tmp_root()

      paths = Codegen.write_snapshots!(snapshot_root: root, resources: [@resource, @uncovered])

      assert paths == [Codegen.snapshot_path(root, @resource)]
    end
  end

  describe "pending/1" do
    test "a missing snapshot reports every statement of the resource" do
      attach!()
      root = Path.join(System.tmp_dir!(), "strangler-codegen-missing-#{System.unique_integer()}")

      [entry] = Codegen.pending(snapshot_root: root)

      assert entry.resource == @resource
      assert entry.status == :missing
      assert entry.summary == "no snapshot yet"

      current = Codegen.rendered()[@resource]
      assert length(entry.pending) == length(current)
      assert Enum.map(entry.pending, &elem(&1, 0)) == Enum.map(current, &to_string(&1.name))
    end

    test "a changed statement is reported as pending, naming the resource" do
      attach!()

      # The snapshot is the stale half: it holds an older body of the first
      # statement, the way the installed DDL predates a mapping change.
      root =
        doctored_root(fn doc ->
          update_in(doc, ["statements", Access.at(0), "up"], &(&1 <> "\n-- older body"))
        end)

      [entry] = Codegen.pending(snapshot_root: root)

      assert entry.resource == @resource
      assert entry.status == :changed
      assert entry.summary =~ "changed: "

      # What is pending is the current render — the statement to put in the
      # next migration — not the stale text.
      [{_name, up} | _] = entry.pending
      first = Codegen.rendered()[@resource] |> List.first()
      assert up == String.trim_trailing(first.up)
    end

    test "a corrupt snapshot is reported, not crashed on" do
      attach!()
      root = tmp_root()

      path = Codegen.snapshot_path(root, @resource)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json at all")

      [entry] = Codegen.pending(snapshot_root: root)

      assert entry.resource == @resource
      assert entry.status == :invalid
      assert entry.summary =~ "unreadable snapshot:"
    end

    test "a statement added by a mapping change is reported as added" do
      attach!()

      # The snapshot is stale: it predates the statement the renderer now
      # produces, so the renderer has one statement the snapshot lacks.
      root =
        doctored_root(fn doc ->
          update_in(doc, ["statements"], &Enum.drop(&1, -1))
        end)

      [entry] = Codegen.pending(snapshot_root: root)

      assert entry.status == :changed
      assert entry.summary =~ "added: "

      last = Codegen.rendered()[@resource] |> List.last()
      assert entry.pending == [{to_string(last.name), String.trim_trailing(last.up)}]
    end

    test "a statement removed by a mapping change is reported as removed" do
      attach!()

      # The snapshot holds a statement the renderer no longer produces.
      root =
        doctored_root(fn doc ->
          update_in(doc, ["statements"], fn statements ->
            statements ++ [%{"name" => "retired_statement", "up" => "SELECT 1;"}]
          end)
        end)

      [entry] = Codegen.pending(snapshot_root: root)

      assert entry.status == :changed
      assert entry.summary =~ "removed: 1"

      # Nothing is pending for a removal: the next migration carries only what
      # the renderer still produces.
      assert entry.pending == []
    end

    test "matching snapshots are clean, in order, including the reshape guard" do
      attach!()
      root = doctored_root(&Function.identity/1)

      assert Codegen.pending(snapshot_root: root) == []

      # Statement for statement: a reorder must be drift, so the comparison is
      # positional and a reordered snapshot is a changed one.
      root =
        doctored_root(fn doc ->
          [first, second | rest] = doc["statements"]
          put_in(doc, ["statements"], [second, first | rest])
        end)

      [entry] = Codegen.pending(snapshot_root: root)
      assert entry.status == :changed
    end
  end

  describe "next_migration_version/1" do
    test "it allocates strictly after an existing newer file" do
      dir = migrations_tmp_dir()
      File.write!(Path.join(dir, "20991231235959_someone_elses.exs"), "")

      version = Codegen.next_migration_version(dir)

      assert String.match?(version, ~r/^\d{14}$/)
      assert String.to_integer(version) > 20_991_231_235_959
    end

    test "it stays strictly after AshPostgres's in-process counter" do
      dir = migrations_tmp_dir()

      # The counter AshPostgres's generator publishes into; whichever generator
      # runs first, the second must not land on the same second.
      Process.put(:ash_postgres_last_migration_timestamp, "20300101000000")

      version = Codegen.next_migration_version(dir)

      assert String.to_integer(version) > 20_300_101_000_000
    end

    test "it is a 14-digit version on an empty directory" do
      dir = migrations_tmp_dir()

      assert String.match?(Codegen.next_migration_version(dir), ~r/^\d{14}$/)
    end
  end

  # -- helpers -----------------------------------------------------------------

  # The attached path needs a domain that attaches the extension in the app's
  # `:ash_domains`; restored on exit so no other test inherits it.
  defp attach! do
    original = Application.get_env(:ash_strangler, :ash_domains, [])
    Application.put_env(:ash_strangler, :ash_domains, [AshStrangler.Test.CodegenDomain])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:ash_strangler, :ash_domains, original)
    end)
  end

  defp tmp_root do
    Path.join(System.tmp_dir!(), "strangler-codegen-#{System.unique_integer()}")
  end

  defp migrations_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "strangler-migrations-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    dir
  end

  # Renders the current statements to a fresh snapshot dir, then lets the test
  # rewrite the JSON the way a stale mapping would have left it.
  defp doctored_root(transform) do
    root = tmp_root()
    Codegen.write_snapshots!(snapshot_root: root)

    path = Codegen.snapshot_path(root, @resource)
    doc = path |> File.read!() |> Jason.decode!() |> transform.()
    File.write!(path, Jason.encode!(doc, pretty: true) <> "\n")

    root
  end
end
