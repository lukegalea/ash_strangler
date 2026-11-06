# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Error.BranchWriteRefused do
  @moduledoc """
  A write that would land on a union's legacy branch, refused.

  The `INSTEAD OF` triggers of an `AshStrangler.Union` raise it in the form
  AshPostgres turns back into this exception (`ash_error: <json>`), so an Ash
  action over the union's view fails with this typed error and the branch's
  declared reason, not a database error. `branch` and `operation` are strings
  when the error comes back from the database.
  """

  use Splode.Error, fields: [:branch, :phase, :operation, :reason], class: :invalid

  @impl true
  def message(%{branch: branch, operation: operation, reason: reason}),
    do: "#{operation} refused on the #{branch} branch: #{reason}"
end
