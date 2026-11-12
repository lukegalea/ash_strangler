# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshStrangler.Test.CodegenDomain do
  @moduledoc """
  A domain that attaches `AshStrangler.Codegen`, so the codegen tests can flip
  one application between the attached and unattached paths: the default test
  config (`AshStrangler.Test.Domain`) does not attach it, and these tests put
  this domain into `:ash_domains` when they need the attached behaviour.
  """

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshStrangler.Codegen]

  resources do
    resource AshStrangler.Test.LegacyUser
  end
end
