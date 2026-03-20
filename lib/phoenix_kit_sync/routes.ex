defmodule PhoenixKitSync.Routes do
  @moduledoc """
  Route module for PhoenixKit Sync non-admin routes.

  Provides API endpoints and WebSocket forward for cross-site sync communication.
  Called by `compile_module_public_routes/1` in PhoenixKit's integration.ex
  via the `route_module/0` callback.

  Admin LiveView routes are auto-generated from `admin_tabs/0` `live_view:` tuples.
  """

  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through [:phoenix_kit_api]

        post "/sync/api/register-connection",
             PhoenixKitSync.Web.ApiController,
             :register_connection

        post "/sync/api/delete-connection",
             PhoenixKitSync.Web.ApiController,
             :delete_connection

        post "/sync/api/verify-connection",
             PhoenixKitSync.Web.ApiController,
             :verify_connection

        post "/sync/api/update-status",
             PhoenixKitSync.Web.ApiController,
             :update_status

        post "/sync/api/get-connection-status",
             PhoenixKitSync.Web.ApiController,
             :get_connection_status

        post "/sync/api/list-tables",
             PhoenixKitSync.Web.ApiController,
             :list_tables

        post "/sync/api/pull-data",
             PhoenixKitSync.Web.ApiController,
             :pull_data

        post "/sync/api/table-schema",
             PhoenixKitSync.Web.ApiController,
             :table_schema

        post "/sync/api/table-records",
             PhoenixKitSync.Web.ApiController,
             :table_records

        get "/sync/api/status", PhoenixKitSync.Web.ApiController, :status
      end

      forward "#{unquote(url_prefix)}/sync/websocket", PhoenixKitSync.Web.SocketPlug
    end
  end
end
