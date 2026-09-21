# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

# This config exists for AshStrangler's OWN dev and test runs. It is not
# shipped -- `files:` in mix.exs excludes it -- and a consuming application
# configures its own repos.
config :ash_strangler, ecto_repos: [AshStrangler.TestRepo]

# Required by ash >= 3.33 (`Ash.Resource.Transformers.RequireStringLengthCountConfig`
# refuses to compile a resource carrying `:string`/`:ci_string` attributes without
# it). Codepoints matches how SQL data layers count length, so validation is
# consistent everywhere. Consuming applications must set this themselves; the
# demo/support resources here only need it to compile the suite.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
