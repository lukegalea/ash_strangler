alias AshStrangler.Test.LegacySchema
alias AshStrangler.TestRepo

# AshStrangler is a library, so nothing starts the repo for us.
case Ecto.Adapters.Postgres.storage_up(TestRepo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  {:error, reason} -> raise "could not create the test database: #{inspect(reason)}"
end

{:ok, _pid} = TestRepo.start_link()

# Installs the legacy fixture schema and the GENERATED view over it, committed,
# before the sandbox starts intercepting. Tests then run inside a transaction
# that rolls back, so they share this schema and never rebuild it.
LegacySchema.install!()

Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

ExUnit.start()
