defmodule PhoenixKitSync.Test.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_kit_sync,
    adapter: Ecto.Adapters.Postgres
end
