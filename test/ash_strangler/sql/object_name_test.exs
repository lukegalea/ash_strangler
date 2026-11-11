# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Sql.ObjectNameTest do
  use ExUnit.Case, async: true

  alias AshStrangler.Sql.ObjectName

  test "byte_prefix never splits a UTF-8 sequence" do
    assert ObjectName.byte_prefix("abc", 25) == "abc"
    assert ObjectName.byte_prefix("abcdef", 3) == "abc"
    assert ObjectName.byte_prefix(String.duplicate("é", 30), 25) == String.duplicate("é", 12)
    assert ObjectName.byte_prefix(String.duplicate("表", 30), 25) == String.duplicate("表", 8)
    assert ObjectName.byte_prefix("aé", 2) == "a"
  end

  test "truncate cuts to 63 bytes on a character boundary" do
    name = "strangler_" <> String.duplicate("é", 40)
    cut = ObjectName.truncate(name)
    assert byte_size(cut) <= 63
    assert String.valid?(cut)
    assert String.starts_with?(name, cut)
    assert ObjectName.truncate("short") == "short"
  end
end
