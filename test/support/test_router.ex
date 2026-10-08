defmodule PhoenixKitSync.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitSync`'s admin_tabs so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is empty; admin paths always get the
  default locale ("en") prefix.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitSync.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/en/admin", PhoenixKitSync.Web do
    pipe_through(:browser)

    live_session :sync_test,
      layout: {PhoenixKitSync.Test.Layouts, :app},
      on_mount: {PhoenixKitSync.Test.Hooks, :assign_scope} do
      live("/sync", Index, :index, as: :sync_index)
      live("/sync/connections", ConnectionsLive, :index, as: :sync_connections)
      live("/sync/connections/:action", ConnectionsLive, :index, as: :sync_connections_action)

      live("/sync/connections/:action/:id", ConnectionsLive, :index,
        as: :sync_connections_action_id
      )

      live("/sync/history", History, :index, as: :sync_history)

      live("/sync/send", Sender, :index, as: :sync_send)
      live("/sync/receive", Receiver, :index, as: :sync_receive)
    end
  end

  # Mirror of PhoenixKitSync.Routes.generate/1 production layout, scoped
  # to the test endpoint so ApiController actions are reachable through
  # Phoenix.ConnTest. Mounted at both `/sync/api/*` (used by direct
  # ConnTest tests, and by ConnectionNotifier when `remote_url_prefix` is
  # overridden to "") and `/phoenix_kit/sync/api/*` (used by
  # ConnectionNotifier with the default prefix, since the test env's
  # `PhoenixKit.Config.get_url_prefix/0` resolves to "/phoenix_kit").
  scope "/sync/api", PhoenixKitSync.Web do
    pipe_through(:api)

    post("/register-connection", ApiController, :register_connection)
    post("/delete-connection", ApiController, :delete_connection)
    post("/verify-connection", ApiController, :verify_connection)
    post("/update-status", ApiController, :update_status)
    post("/get-connection-status", ApiController, :get_connection_status)
    post("/list-tables", ApiController, :list_tables)
    post("/pull-data", ApiController, :pull_data)
    post("/table-schema", ApiController, :table_schema)
    post("/table-records", ApiController, :table_records)
    get("/status", ApiController, :status)
  end

  scope "/phoenix_kit/sync/api", PhoenixKitSync.Web do
    pipe_through(:api)

    post("/register-connection", ApiController, :register_connection, as: :pk_register)
    post("/delete-connection", ApiController, :delete_connection, as: :pk_delete)
    post("/verify-connection", ApiController, :verify_connection, as: :pk_verify)
    post("/update-status", ApiController, :update_status, as: :pk_update_status)
    post("/get-connection-status", ApiController, :get_connection_status, as: :pk_get_status)
    post("/list-tables", ApiController, :list_tables, as: :pk_list_tables)
    post("/pull-data", ApiController, :pull_data, as: :pk_pull_data)
    post("/table-schema", ApiController, :table_schema, as: :pk_table_schema)
    post("/table-records", ApiController, :table_records, as: :pk_table_records)
    get("/status", ApiController, :status, as: :pk_status)
  end

  # WebSocket upgrade endpoint mirror of production routes.ex.
  # WebSocketClient connects here in self-loop tests.
  forward("/sync/websocket", PhoenixKitSync.Web.SocketPlug)
  forward("/phoenix_kit/sync/websocket", PhoenixKitSync.Web.SocketPlug)

  # Canned sender for receiver-side pull tests (see StubRemote).
  forward("/stub-remote", PhoenixKitSync.Test.StubRemote)
end
