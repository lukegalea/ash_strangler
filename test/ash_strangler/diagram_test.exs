# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.DiagramTest do
  @moduledoc """
  The diagrams in the README are generated from `AshStrangler.Demo`, and this
  keeps them that way.

  A picture in a README has no compiler behind it. It is written once, the model
  moves, and it quietly becomes a description of something that no longer
  exists — worse than no diagram, because a reader trusts it. Rendering the real
  resources and asserting the README still contains the output makes that
  failure loud.

  When this fails, the fix is to paste the printed output into the README, not
  to adjust the assertion.
  """

  use ExUnit.Case, async: true

  @readme Path.join([__DIR__, "..", "..", "README.md"]) |> Path.expand()

  defp readme, do: File.read!(@readme)

  test "the entity-relationship diagram matches the model" do
    rendered =
      [AshStrangler.Demo.Domain]
      |> AshDiagram.Data.EntityRelationship.for_domains()
      |> AshDiagram.compose()
      |> IO.iodata_to_binary()
      |> String.trim()

    assert String.contains?(readme(), rendered), """
    The README's entity-relationship diagram no longer matches the model.

    Replace the `erDiagram` block under "What that actually bought you" with:

    #{rendered}
    """
  end

  test "the state machine diagram matches the lifecycle" do
    rendered =
      AshStrangler.Demo.Customer
      |> AshStateMachine.Charts.mermaid_state_diagram()
      |> String.trim()

    assert String.contains?(readme(), rendered), """
    The README's state diagram no longer matches Customer's state machine.

    Replace the `stateDiagram-v2` block under "What that actually bought you" with:

    #{rendered}
    """
  end

  test "the legacy schema diagram lists every column the demo maps" do
    # Hand-written rather than generated -- there is no Ash resource for a table
    # this package deliberately does not own -- so it is checked against the DDL
    # instead, which is the thing it claims to depict.
    ddl = AshStrangler.Demo.legacy_ddl()
    readme = readme()

    # Matches the column lines, which are the ones naming a SQL type. The
    # heredoc strips the common indentation, so anchoring on a fixed depth
    # would silently match nothing -- as it did.
    columns =
      ~r/^\s+(\w+)\s+(?:bigserial|text|boolean|timestamp)/m
      |> Regex.scan(ddl)
      |> Enum.map(fn [_, column] -> column end)

    assert length(columns) == 12

    for column <- columns do
      assert readme =~ column,
             "the README's legacy schema diagram is missing #{inspect(column)}"
    end
  end

  test "every mermaid block in the README parses" do
    # Cheap insurance: a diagram that fails to parse renders as raw source on
    # GitHub, which is worse than omitting it.
    blocks =
      ~r/```mermaid\n(.*?)```/s
      |> Regex.scan(readme())
      |> Enum.map(fn [_, source] -> source end)

    assert length(blocks) >= 6

    for source <- blocks do
      first = source |> String.trim() |> String.split("\n") |> List.first()

      assert first in [
               "flowchart LR",
               "flowchart TB",
               "stateDiagram-v2",
               "erDiagram",
               "sequenceDiagram"
             ],
             "unexpected diagram type: #{inspect(first)}"

      # No theme overrides: GitHub only auto-adapts to dark mode when the
      # diagram does not pin its own colours.
      refute source =~ "%%{init", "a diagram pins a theme and will break dark mode"
      refute source =~ "classDef", "a diagram pins colours and will break dark mode"
    end
  end
end
