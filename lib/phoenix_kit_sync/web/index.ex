defmodule PhoenixKitSync.Web.Index do
  @moduledoc """
  Landing page for DB Sync module.

  Provides access to:
  - Manage Connections: Create and manage permanent connections with other sites
  - Transfer History: View all data transfers with approval workflow
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitSync.Gettext

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitSync
  alias PhoenixKitSync.Connections

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_project_title()

    # Subscribed before the first read, so a change that lands between the
    # read and the subscription is not lost.
    if connected?(socket), do: subscribe()

    socket =
      socket
      |> assign(:page_title, gettext("Sync"))
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/sync", locale: locale))
      |> load_overview()

    {:ok, socket}
  end

  defp subscribe do
    case PhoenixKit.Config.pubsub_server() do
      nil -> :ok
      pubsub -> Phoenix.PubSub.subscribe(pubsub, Connections.pubsub_topic())
    end
  end

  defp load_overview(socket) do
    socket
    |> assign(:config, PhoenixKitSync.get_config())
    |> assign(:stats, get_connection_stats())
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # A connection was created, changed or deleted, here or by the remote
  # site: the numbers on this page are read again.
  @impl true
  def handle_info({event, _uuid}, socket)
      when event in [:connection_created, :connection_updated, :connection_deleted] do
    {:noreply, load_overview(socket)}
  end

  def handle_info({:connection_status_changed, _uuid, _status}, socket) do
    {:noreply, load_overview(socket)}
  end

  # Catch-all so a stray PubSub message or an internal monitor signal can't
  # crash the LV. Mirrors the defensive clause on ConnectionsLive.
  def handle_info(msg, socket) do
    Logger.debug("[Sync.Index] unhandled message | msg=#{inspect(msg)}")
    {:noreply, socket}
  end

  defp get_connection_stats do
    default_stats = %{
      total_senders: 0,
      total_receivers: 0,
      active_senders: 0,
      active_receivers: 0
    }

    with {:ok, sender_connections} <- safe_list_connections("sender"),
         {:ok, receiver_connections} <- safe_list_connections("receiver") do
      active_senders = Enum.count(sender_connections, &(&1.status == "active"))
      active_receivers = Enum.count(receiver_connections, &(&1.status == "active"))

      %{
        total_senders: length(sender_connections),
        total_receivers: length(receiver_connections),
        active_senders: active_senders,
        active_receivers: active_receivers
      }
    else
      _ -> default_stats
    end
  end

  defp safe_list_connections(direction) do
    {:ok, Connections.list_connections(direction: direction)}
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin")}
            class="btn btn-ghost btn-sm -mb-12"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>

          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">{gettext("DB Sync")}</h1>
            <p class="text-lg text-base-content/70">
              {gettext("Sync data between sites")}
            </p>
          </div>
        </header>

        <%= if not @config.enabled do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              {gettext("The DB Sync module is disabled.")}
              <.link navigate={Routes.path("/admin/modules")} class="link link-primary">
                {gettext("Enable it on the Modules page")}
              </.link>
            </span>
          </div>
        <% end %>

        <%!-- Main Actions --%>
        <div class="grid gap-6 md:grid-cols-2 max-w-4xl mx-auto">
          <%!-- Manage Connections Card --%>
          <div class={[
            "card bg-base-100 shadow-xl",
            if(not @config.enabled, do: "opacity-50 pointer-events-none")
          ]}>
            <div class="card-body items-center text-center">
              <div class="text-6xl mb-4">
                <.icon name="hero-link" class="w-16 h-16 text-primary" />
              </div>
              <h2 class="card-title text-2xl">{gettext("Manage Connections")}</h2>
              <p class="text-base-content/70 mb-4">
                {gettext(
                  "Create connections to share your data with other sites. Incoming connections appear when a remote site connects, and wait for your approval unless this site accepts them automatically."
                )}
              </p>
              <div class="card-actions">
                <.link
                  navigate={Routes.path("/admin/sync/connections", locale: @current_locale)}
                  class="btn btn-primary btn-lg"
                >
                  <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> {gettext("Manage Connections")}
                </.link>
              </div>
            </div>
          </div>

          <%!-- Transfer History Card --%>
          <div class={[
            "card bg-base-100 shadow-xl",
            if(not @config.enabled, do: "opacity-50 pointer-events-none")
          ]}>
            <div class="card-body items-center text-center">
              <div class="text-6xl mb-4">
                <.icon name="hero-clock" class="w-16 h-16 text-secondary" />
              </div>
              <h2 class="card-title text-2xl">{gettext("Transfer History")}</h2>
              <p class="text-base-content/70 mb-4">
                {gettext(
                  "View all data transfers and monitor sync activity. Track records transferred and connection statistics."
                )}
              </p>
              <div class="card-actions">
                <.link
                  navigate={Routes.path("/admin/sync/history", locale: @current_locale)}
                  class="btn btn-secondary btn-lg"
                >
                  <.icon name="hero-queue-list" class="w-5 h-5" /> {gettext("View History")}
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- How It Works Section --%>
        <div class="mt-12 max-w-4xl mx-auto">
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title text-lg">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                {gettext("How Cross-Site Connections Work")}
              </h3>
              <div class="grid gap-6 md:grid-cols-2 mt-4">
                <div>
                  <h4 class="font-bold text-primary mb-2 flex items-center gap-2">
                    <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> {gettext("As a Sender")}
                  </h4>
                  <ol class="list-decimal list-inside space-y-2 text-sm text-base-content/80">
                    <li>{gettext("Create a connection with a name")}</li>
                    <li>{gettext("Enter the remote site's URL")}</li>
                    <li>{gettext("The remote site is notified automatically")}</li>
                    <li>{gettext("Once it accepts, it can pull data from your tables")}</li>
                  </ol>
                </div>
                <div>
                  <h4 class="font-bold text-secondary mb-2 flex items-center gap-2">
                    <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> {gettext("As a Receiver")}
                  </h4>
                  <ol class="list-decimal list-inside space-y-2 text-sm text-base-content/80">
                    <li>{gettext("Another site creates a connection to you")}</li>
                    <li>{gettext("The connection appears on your end, pending your approval")}</li>
                    <li>{gettext("Approve it, then use it to sync data from their site")}</li>
                    <li>{gettext("Choose a conflict strategy when importing")}</li>
                  </ol>
                </div>
              </div>
              <div class="divider"></div>
              <div class="text-sm text-base-content/70">
                <strong>{gettext("Security:")}</strong>
                {gettext("All connections use token-based authentication.")}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
