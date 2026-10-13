defmodule PhoenixKitSync.Web.History do
  @moduledoc """
  LiveView for DB Sync transfer history.

  Displays all data transfers with filtering and approval workflow support.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitSync.Gettext

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Pagination
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitSync
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.Params
  alias PhoenixKitSync.Transfers
  alias PhoenixKitWeb.Actor

  @per_page 20
  @statuses ~w(pending pending_approval approved denied in_progress completed failed cancelled expired)
  # Transfers are never pruned (a WebSocket pull writes a row per batch),
  # so the cap sits far beyond any real history; it only keeps a forged
  # page from producing an offset out of the database's range. A page past
  # the last one is clamped in load_transfers/1.
  @max_page 1_000_000

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_project_title()
    config = PhoenixKitSync.get_config()

    # Subscribed before the first read, so a change that lands between the
    # read and the subscription is not lost.
    if connected?(socket), do: subscribe()

    socket =
      socket
      |> assign(:page_section, gettext("Sync"))
      |> assign(:page_section_path, Routes.path("/admin/sync", locale: locale))
      |> assign(:page_title, gettext("History"))
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/sync/history", locale: locale))
      |> assign(:config, config)
      |> assign(:page, 1)
      |> assign(:direction_filter, nil)
      |> assign(:status_filter, nil)
      |> assign(:show_approval_modal, false)
      |> assign(:selected_transfer, nil)
      |> assign(:statuses, @statuses)
      |> maybe_load_transfers()

    {:ok, socket}
  end

  defp subscribe do
    case PhoenixKit.Config.pubsub_server() do
      nil ->
        :ok

      pubsub ->
        Phoenix.PubSub.subscribe(pubsub, Transfers.pubsub_topic())
        Phoenix.PubSub.subscribe(pubsub, Connections.pubsub_topic())
    end
  end

  defp maybe_load_transfers(socket) do
    if connected?(socket), do: load_transfers(socket), else: assign_empty_transfers(socket)
  end

  defp assign_empty_transfers(socket) do
    socket
    |> assign(:transfers, [])
    |> assign(:total_count, 0)
    |> assign(:total_pages, 0)
  end

  @impl true
  def handle_params(params, _url, socket) do
    page = Params.page(params["page"], @max_page)
    direction_filter = params["direction"]
    status_filter = params["status"]

    socket =
      socket
      |> assign(:page, page)
      |> assign(:direction_filter, direction_filter)
      |> assign(:status_filter, status_filter)
      |> load_transfers()

    # A page past the last one was clamped: the address follows, so the URL
    # names the page that is shown (and a reload or a shared link lands on it).
    if connected?(socket) and socket.assigns.page != page do
      {:noreply, push_patch(socket, to: history_path(socket, socket.assigns.page), replace: true)}
    else
      {:noreply, socket}
    end
  end

  defp history_path(socket, page) do
    query =
      [
        {"page", page},
        {"direction", socket.assigns.direction_filter},
        {"status", socket.assigns.status_filter}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> URI.encode_query()

    Routes.path("/admin/sync/history") <> "?" <> query
  end

  defp load_transfers(socket) do
    direction = socket.assigns.direction_filter
    status = socket.assigns.status_filter

    filters = []
    filters = if direction, do: Keyword.put(filters, :direction, direction), else: filters
    filters = if status, do: Keyword.put(filters, :status, status), else: filters

    total_count = Transfers.count_transfers(filters)
    total_pages = Pagination.total_pages(total_count, @per_page)
    # A page past the end (an old link, a narrower filter) shows the last one.
    page = min(socket.assigns.page, total_pages)

    opts = [
      limit: @per_page,
      offset: (page - 1) * @per_page,
      preload: [:connection]
    ]

    transfers = Transfers.list_transfers(filters ++ opts)

    pending_count = Transfers.count_transfers(status: "pending_approval")

    socket
    |> assign(:page, page)
    |> assign(:transfers, transfers)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
    |> assign(:pending_approval_count, pending_count)
  end

  @impl true
  def handle_event("filter", %{"direction" => direction, "status" => status}, socket) do
    query_params = %{}

    query_params =
      if direction != "", do: Map.put(query_params, "direction", direction), else: query_params

    query_params =
      if status != "", do: Map.put(query_params, "status", status), else: query_params

    base_path = Routes.path("/admin/sync/history")

    path =
      if map_size(query_params) > 0 do
        base_path <> "?" <> URI.encode_query(query_params)
      else
        base_path
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("clear_filters", _params, socket) do
    path = Routes.path("/admin/sync/history")
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("show_approval_modal", %{"uuid" => uuid}, socket) do
    transfer = Transfers.get_transfer_with_preloads(uuid, preload: [:connection])

    socket =
      socket
      |> assign(:show_approval_modal, true)
      |> assign(:selected_transfer, transfer)

    {:noreply, socket}
  end

  def handle_event("close_approval_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_approval_modal, false)
      |> assign(:selected_transfer, nil)

    {:noreply, socket}
  end

  def handle_event("approve_transfer", %{"uuid" => uuid}, socket) do
    transfer = Transfers.get_transfer!(uuid)
    actor_uuid = Actor.uuid(socket)

    case Transfers.approve_transfer(transfer, actor_uuid) do
      {:ok, _transfer} ->
        socket =
          socket
          |> put_flash(:info, gettext("Transfer approved successfully"))
          |> assign(:show_approval_modal, false)
          |> assign(:selected_transfer, nil)
          |> load_transfers()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to approve transfer"))}
    end
  end

  def handle_event(
        "deny_transfer",
        %{"transfer_uuid" => transfer_uuid, "reason" => reason},
        socket
      ) do
    transfer = Transfers.get_transfer!(transfer_uuid)
    actor_uuid = Actor.uuid(socket)
    reason = if reason == "", do: nil, else: reason

    case Transfers.deny_transfer(transfer, actor_uuid, reason) do
      {:ok, _transfer} ->
        socket =
          socket
          |> put_flash(:info, gettext("Transfer denied"))
          |> assign(:show_approval_modal, false)
          |> assign(:selected_transfer, nil)
          |> load_transfers()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to deny transfer"))}
    end
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: history_path(socket, page))}
  end

  # A transfer was written, or a connection (whose name each row shows)
  # changed: the page is read again where it stands.
  @impl true
  def handle_info({:transfer_changed, _uuid}, socket) do
    {:noreply, load_transfers(socket)}
  end

  def handle_info({event, _uuid}, socket)
      when event in [:connection_created, :connection_updated, :connection_deleted] do
    {:noreply, load_transfers(socket)}
  end

  def handle_info({:connection_status_changed, _uuid, _status}, socket) do
    {:noreply, load_transfers(socket)}
  end

  # Catch-all so a stray PubSub message or an internal monitor signal can't
  # crash the LV. Mirrors the defensive clause on ConnectionsLive.
  def handle_info(msg, socket) do
    Logger.debug("[Sync.History] unhandled message | msg=#{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin/sync", locale: @current_locale)}
            class="btn btn-ghost btn-sm -mb-12"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>

          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">
              {gettext("Transfer History")}
            </h1>
            <p class="text-lg text-base-content">
              {gettext("View and manage data transfers")}
            </p>
          </div>
        </header>

        <%= if not @config.enabled do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>{gettext("The DB Sync module is disabled.")}</span>
          </div>
        <% end %>

        <%!-- Pending Approvals Alert --%>
        <%= if @pending_approval_count > 0 do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-clock" class="w-5 h-5" />
            <span>
              {ngettext(
                "%{count} transfer pending approval",
                "%{count} transfers pending approval",
                @pending_approval_count
              )}
            </span>
            <button
              type="button"
              phx-click="filter"
              phx-value-direction=""
              phx-value-status="pending_approval"
              class="btn btn-sm btn-primary"
            >
              {gettext("View Pending")}
            </button>
          </div>
        <% end %>

        <%!-- Filters --%>
        <div class="card bg-base-100 shadow mb-6">
          <div class="card-body py-4">
            <div class="flex flex-wrap gap-4 items-end">
              <%!-- One form around both selects: a select's phx-change only
                   reaches the server from inside a form, and the event
                   carries both fields --%>
              <form id="history-filters" phx-change="filter" class="flex flex-wrap gap-4 items-end">
                <div class="fieldset">
                  <label class="label" for="history-filter-direction">
                    <span class="fieldset-legend">{gettext("Direction")}</span>
                  </label>
                  <label class="select select-sm">
                    <select id="history-filter-direction" name="direction">
                      <option value="" selected={@direction_filter == nil}>{gettext("All")}</option>
                      <option
                        :for={direction <- ~w(send receive)}
                        value={direction}
                        selected={@direction_filter == direction}
                      >
                        {direction_label(direction)}
                      </option>
                    </select>
                  </label>
                </div>

                <div class="fieldset">
                  <label class="label" for="history-filter-status">
                    <span class="fieldset-legend">{gettext("Status")}</span>
                  </label>
                  <label class="select select-sm">
                    <select id="history-filter-status" name="status">
                      <option value="" selected={@status_filter == nil}>{gettext("All")}</option>
                      <option
                        :for={status <- @statuses}
                        value={status}
                        selected={@status_filter == status}
                      >
                        {status_label(status)}
                      </option>
                    </select>
                  </label>
                </div>
              </form>

              <%= if @direction_filter || @status_filter do %>
                <button
                  type="button"
                  phx-click="clear_filters"
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Clear Filters")}
                </button>
              <% end %>

              <div class="ml-auto text-sm text-base-content/70">
                {ngettext("%{count} transfer found", "%{count} transfers found", @total_count)}
              </div>
            </div>
          </div>
        </div>

        <%!-- Transfers Table --%>
        <div class="card bg-base-100 shadow">
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>{gettext("Direction")}</th>
                  <th>{gettext("Table")}</th>
                  <th>{gettext("Records")}</th>
                  <th>{gettext("Status")}</th>
                  <th>{gettext("Connection")}</th>
                  <th>{gettext("Date")}</th>
                  <th>{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <%= if Enum.empty?(@transfers) do %>
                  <tr>
                    <td colspan="7" class="text-center text-base-content/70 py-8">
                      {gettext("No transfers found")}
                    </td>
                  </tr>
                <% else %>
                  <%= for transfer <- @transfers do %>
                    <tr>
                      <td>
                        <.direction_badge direction={transfer.direction} />
                      </td>
                      <td class="font-mono text-sm">{transfer.table_name}</td>
                      <td>
                        <.record_counts transfer={transfer} />
                      </td>
                      <td>
                        <.status_badge status={transfer.status} />
                      </td>
                      <td class="text-sm text-base-content/70">
                        <%= if transfer.connection do %>
                          {transfer.connection.name}
                        <% else %>
                          <span class="opacity-50">{gettext("Session")}</span>
                        <% end %>
                      </td>
                      <td class="text-sm text-base-content/70">
                        <.time_ago datetime={transfer.inserted_at} />
                      </td>
                      <td>
                        <%= if transfer.status == "pending_approval" do %>
                          <button
                            type="button"
                            phx-click="show_approval_modal"
                            phx-value-uuid={transfer.uuid}
                            class="btn btn-primary btn-xs tooltip tooltip-bottom"
                            data-tip={gettext("Review")}
                          >
                            <.icon
                              name="hero-clipboard-document-check"
                              class="h-4 w-4 hidden sm:inline"
                            />
                            <span class="sm:hidden whitespace-nowrap">{gettext("Review")}</span>
                          </button>
                        <% else %>
                          <button
                            type="button"
                            phx-click="show_approval_modal"
                            phx-value-uuid={transfer.uuid}
                            class="btn btn-ghost btn-xs tooltip tooltip-bottom"
                            data-tip={gettext("Details")}
                          >
                            <.icon name="hero-eye" class="h-4 w-4 hidden sm:inline" />
                            <span class="sm:hidden whitespace-nowrap">{gettext("Details")}</span>
                          </button>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Pagination --%>
        <%= if @total_pages > 1 do %>
          <div class="flex justify-center mt-6">
            <div class="join">
              <button
                type="button"
                class="join-item btn btn-sm"
                disabled={@page <= 1}
                phx-click="page"
                phx-value-page={@page - 1}
              >
                «
              </button>
              <button class="join-item btn btn-sm">
                {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
              </button>
              <button
                type="button"
                class="join-item btn btn-sm"
                disabled={@page >= @total_pages}
                phx-click="page"
                phx-value-page={@page + 1}
              >
                »
              </button>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Approval/Details Modal --%>
      <%= if @show_approval_modal && @selected_transfer do %>
        <.transfer_modal transfer={@selected_transfer} />
      <% end %>
    </div>
    """
  end

  # ===========================================
  # COMPONENTS
  # ===========================================

  defp direction_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      if(@direction == "send", do: "badge-primary", else: "badge-secondary")
    ]}>
      <%= if @direction == "send" do %>
        <.icon name="hero-arrow-up-tray" class="w-3 h-3 mr-1" /> {direction_label("send")}
      <% else %>
        <.icon name="hero-arrow-down-tray" class="w-3 h-3 mr-1" /> {direction_label("receive")}
      <% end %>
    </span>
    """
  end

  defp record_counts(assigns) do
    ~H"""
    <div class="text-sm">
      <%= if @transfer.records_transferred > 0 do %>
        <span class="font-semibold">{@transfer.records_transferred}</span>
        <span class="text-base-content/50">{gettext("transferred")}</span>
        <%= if @transfer.records_created > 0 do %>
          <span class="text-success">+{@transfer.records_created}</span>
        <% end %>
        <%= if @transfer.records_skipped > 0 do %>
          <span class="text-warning">~{@transfer.records_skipped}</span>
        <% end %>
        <%= if @transfer.records_failed > 0 do %>
          <span class="text-error">×{@transfer.records_failed}</span>
        <% end %>
      <% else %>
        <span class="text-base-content/50">
          {gettext("%{count} requested", count: @transfer.records_requested || 0)}
        </span>
      <% end %>
    </div>
    """
  end

  defp transfer_modal(assigns) do
    ~H"""
    <div class="modal modal-open" phx-window-keydown="close_approval_modal" phx-key="escape">
      <div class="modal-box max-w-2xl">
        <button
          type="button"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          phx-click="close_approval_modal"
        >
          ✕
        </button>

        <h3 class="font-bold text-lg mb-4">
          {gettext("Transfer Details")} <.status_badge status={@transfer.status} />
        </h3>

        <div class="grid gap-4">
          <%!-- Basic Info --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="text-sm text-base-content/70">{gettext("Direction")}</label>
              <p class="font-semibold">
                <.direction_badge direction={@transfer.direction} />
              </p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Table")}</label>
              <p class="font-mono">{@transfer.table_name}</p>
            </div>
          </div>

          <%!-- Records Info --%>
          <div class="grid grid-cols-3 gap-4">
            <div>
              <label class="text-sm text-base-content/70">{gettext("Requested")}</label>
              <p class="font-semibold">{@transfer.records_requested || 0}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Transferred")}</label>
              <p class="font-semibold">{@transfer.records_transferred}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Bytes")}</label>
              <p class="font-semibold">{format_bytes(@transfer.bytes_transferred)}</p>
            </div>
          </div>

          <div class="grid grid-cols-4 gap-4">
            <div>
              <label class="text-sm text-base-content/70">{gettext("Created")}</label>
              <p class="text-success font-semibold">{@transfer.records_created}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Updated")}</label>
              <p class="text-info font-semibold">{@transfer.records_updated}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Skipped")}</label>
              <p class="text-warning font-semibold">{@transfer.records_skipped}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Failed")}</label>
              <p class="text-error font-semibold">{@transfer.records_failed}</p>
            </div>
          </div>

          <%!-- Connection Info --%>
          <%= if @transfer.connection do %>
            <div class="divider my-2"></div>
            <div>
              <label class="text-sm text-base-content/70">{gettext("Connection")}</label>
              <p>{@transfer.connection.name}</p>
              <p class="text-sm text-base-content/50">{@transfer.connection.site_url}</p>
            </div>
          <% end %>

          <%!-- Request Context (for approval) --%>
          <%= if @transfer.requires_approval do %>
            <div class="divider my-2"></div>
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="text-sm text-base-content/70">{gettext("Requester IP")}</label>
                <p class="font-mono text-sm">{@transfer.requester_ip || gettext("Unknown")}</p>
              </div>
              <div>
                <label class="text-sm text-base-content/70">{gettext("Conflict Strategy")}</label>
                <p>{@transfer.conflict_strategy || gettext("default")}</p>
              </div>
            </div>
          <% end %>

          <%!-- Error Message --%>
          <%= if @transfer.error_message do %>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-circle" class="w-5 h-5" />
              <span>{Errors.transfer_error(@transfer.error_message)}</span>
            </div>
          <% end %>

          <%!-- Denial Reason --%>
          <%= if @transfer.denial_reason do %>
            <div class="alert alert-warning">
              <.icon name="hero-x-circle" class="w-5 h-5" />
              <span>{gettext("Denied: %{reason}", reason: @transfer.denial_reason)}</span>
            </div>
          <% end %>

          <%!-- Timestamps --%>
          <div class="divider my-2"></div>
          <div class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <label class="text-base-content/70">{gettext("Created")}</label>
              <p>{Calendar.strftime(@transfer.inserted_at, "%Y-%m-%d %H:%M:%S")}</p>
            </div>
            <%= if @transfer.started_at do %>
              <div>
                <label class="text-base-content/70">{gettext("Started")}</label>
                <p>{Calendar.strftime(@transfer.started_at, "%Y-%m-%d %H:%M:%S")}</p>
              </div>
            <% end %>
            <%= if @transfer.completed_at do %>
              <div>
                <label class="text-base-content/70">{gettext("Completed")}</label>
                <p>{Calendar.strftime(@transfer.completed_at, "%Y-%m-%d %H:%M:%S")}</p>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Action Buttons --%>
        <div class="modal-action">
          <%= if @transfer.status == "pending_approval" do %>
            <form phx-submit="deny_transfer" class="flex gap-2 items-end">
              <input type="hidden" name="transfer_uuid" value={@transfer.uuid} />
              <div class="fieldset">
                <input
                  type="text"
                  name="reason"
                  placeholder={gettext("Reason (optional)")}
                  class="input input-sm w-48"
                />
              </div>
              <button
                type="submit"
                class="btn btn-error btn-sm"
                phx-disable-with={gettext("Denying…")}
              >
                {gettext("Deny")}
              </button>
            </form>
            <button
              type="button"
              phx-click="approve_transfer"
              phx-value-uuid={@transfer.uuid}
              phx-disable-with={gettext("Approving…")}
              class="btn btn-success btn-sm"
            >
              {gettext("Approve")}
            </button>
          <% else %>
            <button type="button" phx-click="close_approval_modal" class="btn btn-ghost">
              {gettext("Close")}
            </button>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_approval_modal"></div>
    </div>
    """
  end

  @doc """
  The label of a transfer status, in the reader's language. Unknown values
  (a status from a newer version) show as stored.
  """
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("pending"), do: gettext("Pending")
  def status_label("pending_approval"), do: gettext("Pending Approval")
  def status_label("approved"), do: gettext("Approved")
  def status_label("denied"), do: gettext("Denied")
  def status_label("in_progress"), do: gettext("In Progress")
  def status_label("completed"), do: gettext("Completed")
  def status_label("failed"), do: gettext("Failed")
  def status_label("cancelled"), do: gettext("Cancelled")
  def status_label("expired"), do: gettext("Expired")
  def status_label(nil), do: ""
  def status_label(other) when is_binary(other), do: other

  defp direction_label("send"), do: gettext("Sent")
  defp direction_label("receive"), do: gettext("Received")
  defp direction_label(other), do: other

  defp format_bytes(bytes) when is_nil(bytes) or bytes == 0, do: "0 B"

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
