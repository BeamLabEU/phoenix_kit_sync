defmodule PhoenixKitSync.TestActor do
  @moduledoc """
  Returns the uuid of a real, persisted user to attribute a connection
  decision to.

  `phoenix_kit_sync_connections` carries genuine foreign keys to
  `phoenix_kit_users` — `fk_sync_connections_approved_by_uuid`,
  `..._suspended_by_uuid`, `..._revoked_by_uuid`. Passing a freshly generated
  `UUIDv7.generate()` as the actor therefore raises `Ecto.ConstraintError`
  rather than recording an approval, which is exactly what the suite did for
  every approve/suspend/revoke call site.

  Deliberately a plain module rather than a helper on `DataCase`: these call
  sites are spread across `DataCase`, `ConnCase`, `LiveCase` and
  `ChannelCase` tests, and a fully-qualified call needs no import in any of
  them.
  """

  alias PhoenixKit.Users.Auth

  @doc "Registers a fresh user and returns its uuid."
  def uuid do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "sync-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    user.uuid
  end
end
