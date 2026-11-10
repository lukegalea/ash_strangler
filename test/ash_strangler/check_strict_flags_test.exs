# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.CheckStrictFlagsTest do
  @moduledoc """
  `--strict` and `--no-data` contradict each other, with and without `--estate`.

  The refusal comes before either mode starts, so no database is needed.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.AshStrangler.Check

  test "--strict with --no-data is refused" do
    assert_raise Mix.Error, ~r/--strict and --no-data contradict each other/, fn ->
      Check.run(["--strict", "--no-data"])
    end
  end

  test "--strict with --no-data is refused for --estate too" do
    assert_raise Mix.Error, ~r/--strict and --no-data contradict each other/, fn ->
      Check.run(["--estate", "AshStrangler.NoSuchEstate", "--strict", "--no-data"])
    end
  end
end
