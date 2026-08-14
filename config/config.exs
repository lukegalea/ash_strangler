import Config

# This config exists for AshStrangler's OWN dev and test runs. It is not
# shipped -- `files:` in mix.exs excludes it -- and a consuming application
# configures its own repos.
config :ash_strangler, ecto_repos: [AshStrangler.TestRepo]

if config_env() == :test do
  import_config "test.exs"
end
