defmodule PhoenixKitSync.WebSocketClient do
  @moduledoc """
  WebSocket client for Sync receiver connections.

  Uses WebSockex to connect from the receiver site to the sender's
  WebSocket endpoint. Sends requests and receives responses.

  ## Architecture

  The receiver uses this client to:
  1. Connect to the sender's hosted channel
  2. Send requests for data (tables, schema, records)
  3. Receive responses and notify the caller (LiveView)

  ## Usage

      {:ok, pid} = WebSocketClient.start_link(
        url: "https://sender-site.com",
        code: "ABC12345",
        caller: self()
      )

      # Request available tables
      WebSocketClient.request_tables(pid)
      # Receive: {:sync_client, {:tables, tables}}

      # Request records
      WebSocketClient.request_records(pid, "users", offset: 0, limit: 100)
      # Receive: {:sync_client, {:records, "users", result}}

  ## Rate limiting

  A sender that refuses a request with `"error_code": "rate_limited"` (the
  connection is over its requests per minute) gets the same request again
  after its `"retry_after"`, clamped and within a total budget
  (`PhoenixKitSync.RateLimit`). Before each wait the caller receives
  `{:sync_client, {:rate_limited, request_type, seconds}}`; past the budget
  the request ends as `{:request_error, request_type, :rate_limited}`.
  """

  use WebSockex
  require Logger

  alias PhoenixKitSync.PeerData
  alias PhoenixKitSync.PullCursor
  alias PhoenixKitSync.RateLimit

  @heartbeat_interval 30_000
  @join_timeout 10_000

  defstruct [
    :url,
    :code,
    :caller,
    :receiver_info,
    :ref_counter,
    :pending_refs,
    :joined,
    :heartbeat_ref,
    # The frame each pending request was sent as and the seconds it has
    # waited on a rate-limited sender: `%{ref => %{msg: text, waited: s}}`.
    requests: %{}
  ]

  # ===========================================
  # PUBLIC API
  # ===========================================

  @doc """
  Starts the WebSocket client and connects to the sender.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    code = Keyword.fetch!(opts, :code)
    caller = Keyword.fetch!(opts, :caller)
    receiver_info = Keyword.get(opts, :receiver_info, %{})

    with {:ok, ws_url} <- build_websocket_url(url, code) do
      state = %__MODULE__{
        url: url,
        code: code,
        caller: caller,
        receiver_info: receiver_info,
        ref_counter: 0,
        pending_refs: %{},
        joined: false,
        heartbeat_ref: nil
      }

      case WebSockex.start_link(ws_url, __MODULE__, state, []) do
        {:ok, pid} -> {:ok, pid}
        {:error, _reason} -> {:error, :offline}
      end
    end
  end

  @doc """
  Disconnects the WebSocket client.
  """
  @spec disconnect(pid()) :: :ok
  def disconnect(pid) do
    WebSockex.cast(pid, :disconnect)
  end

  @doc """
  Request server capabilities.
  """
  @spec request_capabilities(pid()) :: :ok
  def request_capabilities(pid) do
    WebSockex.cast(pid, :request_capabilities)
  end

  @doc """
  Request list of available tables from sender.
  """
  @spec request_tables(pid()) :: :ok
  def request_tables(pid) do
    WebSockex.cast(pid, :request_tables)
  end

  @doc """
  Request schema for a specific table.
  """
  @spec request_schema(pid(), String.t()) :: :ok
  def request_schema(pid, table) do
    WebSockex.cast(pid, {:request_schema, table})
  end

  @doc """
  Request record count for a table.
  """
  @spec request_count(pid(), String.t()) :: :ok
  def request_count(pid, table) do
    WebSockex.cast(pid, {:request_count, table})
  end

  @doc """
  Request records from a table with pagination.

  ## Options

  - `:offset` - Number of records to skip (default: 0)
  - `:limit` - Maximum records to return (default: 100)
  - `:after` - The `next_after` of the page before, when the sender
    answered one: the sender then continues from that key and ignores the
    offset. A sender that does not know it pages by the offset, so both are
    sent.
  """
  @spec request_records(pid(), String.t(), keyword()) :: :ok
  def request_records(pid, table, opts \\ []) do
    WebSockex.cast(pid, {:request_records, table, opts})
  end

  # ===========================================
  # WEBSOCKEX CALLBACKS
  # ===========================================

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Sync.WebSocketClient: Connected to sender")

    # Join the transfer channel with receiver info
    join_payload = %{receiver_info: state.receiver_info}
    join_msg = encode_message("transfer:#{state.code}", "phx_join", join_payload, make_ref(state))
    WebSockex.cast(self(), {:send_raw, join_msg})

    # Start join timeout
    Process.send_after(self(), :join_timeout, @join_timeout)

    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, [_join_ref, ref, topic, event, payload]} when is_binary(topic) and is_binary(event) ->
        handle_phoenix_message(topic, event, payload, ref, state)

      # Valid JSON that is not a `[join_ref, ref, topic, event, payload]`
      # frame: the sender's to get wrong, not this process's to crash on.
      {:ok, _not_a_frame} ->
        Logger.warning("Sync.WebSocketClient: Ignoring a message that is not a channel frame")
        {:ok, state}

      {:error, _reason} ->
        Logger.warning("Sync.WebSocketClient: Failed to decode message")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_raw, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  def handle_cast(:disconnect, state) do
    notify_caller(state, :disconnected)
    {:close, state}
  end

  def handle_cast(:request_capabilities, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      msg = encode_message("transfer:#{state.code}", "request:capabilities", %{ref: ref}, ref)
      state = track_request(state, ref, :capabilities, msg)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast(:request_tables, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      msg = encode_message("transfer:#{state.code}", "request:tables", %{ref: ref}, ref)
      state = track_request(state, ref, :tables, msg)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast({:request_schema, table}, state) do
    if state.joined do
      {ref, state} = next_ref(state)

      msg =
        encode_message("transfer:#{state.code}", "request:schema", %{table: table, ref: ref}, ref)

      state = track_request(state, ref, {:schema, table}, msg)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast({:request_count, table}, state) do
    if state.joined do
      {ref, state} = next_ref(state)

      msg =
        encode_message("transfer:#{state.code}", "request:count", %{table: table, ref: ref}, ref)

      state = track_request(state, ref, {:count, table}, msg)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  def handle_cast({:request_records, table, opts}, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      offset = Keyword.get(opts, :offset, 0)
      limit = Keyword.get(opts, :limit, 100)

      payload = %{table: table, offset: offset, limit: limit, ref: ref}

      payload =
        case Keyword.get(opts, :after) do
          %{} = position -> Map.put(payload, :after, position)
          _none -> payload
        end

      msg = encode_message("transfer:#{state.code}", "request:records", payload, ref)

      state = track_request(state, ref, {:records, table}, msg)
      {:reply, {:text, msg}, state}
    else
      Logger.warning("Sync.WebSocketClient: Cannot send request - not joined")
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    if state.joined do
      {ref, state} = next_ref(state)
      msg = encode_message("phoenix", "heartbeat", %{}, ref)
      state = %{state | heartbeat_ref: ref}
      schedule_heartbeat()
      {:reply, {:text, msg}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(:join_timeout, state) do
    if state.joined do
      {:ok, state}
    else
      Logger.warning("Sync.WebSocketClient: Join timeout")
      notify_caller(state, {:error, :join_timeout})
      {:close, state}
    end
  end

  # A rate-limited request whose wait is over goes out again as it was
  # sent, under the same ref.
  def handle_info({:retry_request, ref}, state) do
    case state.requests do
      %{^ref => %{msg: msg}} -> {:reply, {:text, msg}, state}
      _gone -> {:ok, state}
    end
  end

  def handle_info(_msg, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("Sync.WebSocketClient: Disconnected")
    notify_caller(state, {:disconnected, safe_reason(reason)})
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Sync.WebSocketClient: Terminating")
    notify_caller(state, {:terminated, safe_reason(reason)})
    :ok
  end

  # ===========================================
  # PHOENIX MESSAGE HANDLERS
  # ===========================================

  defp handle_phoenix_message(_topic, "phx_reply", %{"status" => "ok"} = payload, ref, state) do
    cond do
      # Join reply
      not state.joined and Map.get(payload, "response") == %{} ->
        Logger.info("Sync.WebSocketClient: Joined channel")
        state = %{state | joined: true}
        notify_caller(state, :connected)
        schedule_heartbeat()
        {:ok, state}

      # Heartbeat reply
      state.heartbeat_ref == ref ->
        {:ok, %{state | heartbeat_ref: nil}}

      true ->
        {:ok, state}
    end
  end

  defp handle_phoenix_message(_topic, "phx_reply", %{"status" => "error"}, _ref, state) do
    Logger.warning("Sync.WebSocketClient: Join refused by sender")
    notify_caller(state, {:error, :invalid_response})
    {:ok, state}
  end

  defp handle_phoenix_message(_topic, "phx_error", _payload, _ref, state) do
    Logger.error("Sync.WebSocketClient: Channel error")
    notify_caller(state, {:error, :invalid_response})
    {:ok, state}
  end

  defp handle_phoenix_message(_topic, "phx_close", _payload, _ref, state) do
    Logger.info("Sync.WebSocketClient: Channel closed by server")
    notify_caller(state, :channel_closed)
    {:close, state}
  end

  # Handle response messages from sender
  defp handle_phoenix_message(
         _topic,
         "response:capabilities",
         %{"capabilities" => caps, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.debug("Sync.WebSocketClient: Received capabilities")
    {request_type, state} = pop_request(state, ref)

    if request_type == :capabilities do
      notify_caller(state, {:capabilities, caps})
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:tables",
         %{"tables" => tables, "ref" => ref},
         _msg_ref,
         state
       ) do
    {request_type, state} = pop_request(state, ref)

    if request_type == :tables do
      case PeerData.tables(tables) do
        {:ok, tables} -> notify_caller(state, {:tables, tables})
        {:error, reason} -> notify_caller(state, {:request_error, :tables, reason})
      end
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:schema",
         %{"schema" => schema, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.info("Sync.WebSocketClient: Received schema response, ref: #{inspect(ref)}")
    {request_type, state} = pop_request(state, ref)

    Logger.info(
      "Sync.WebSocketClient: Request type for ref #{inspect(ref)}: #{inspect(request_type)}"
    )

    case request_type do
      {:schema, table} ->
        if PeerData.valid_schema?(schema),
          do: notify_caller(state, {:schema, table, schema}),
          else: notify_caller(state, {:request_error, {:schema, table}, :invalid_response})

      other ->
        Logger.warning("Sync.WebSocketClient: Unexpected request type: #{inspect(other)}")
    end

    {:ok, state}
  end

  defp handle_phoenix_message(
         _topic,
         "response:count",
         %{"count" => count, "ref" => ref},
         _msg_ref,
         state
       )
       when is_integer(count) do
    Logger.debug("Sync.WebSocketClient: Received count: #{count}")
    {request_type, state} = pop_request(state, ref)

    case request_type do
      {:count, table} -> notify_caller(state, {:count, table, count})
      _ -> :ok
    end

    {:ok, state}
  end

  # Records are what the import writes, so a page is taken only as a list
  # of maps. A page with anything else in it is a malformed answer and
  # fails the request: dropping the element would shift every offset after
  # it (a row repeated or skipped) and turn a page of nothing but such
  # elements into the end of the table.
  defp handle_phoenix_message(
         _topic,
         "response:records",
         %{"records" => records} = payload,
         _msg_ref,
         state
       ) do
    ref = Map.get(payload, "ref")
    {request_type, state} = pop_request(state, ref)

    case {request_type, well_formed_records?(records)} do
      {{:records, table}, true} ->
        Logger.debug("Sync.WebSocketClient: Received #{length(records)} records")

        result = %{
          records: records,
          offset: Map.get(payload, "offset", 0),
          has_more: Map.get(payload, "has_more", false),
          next_after: next_after(payload)
        }

        notify_caller(state, {:records, table, result})

      {{:records, table}, false} ->
        Logger.warning("Sync.WebSocketClient: Malformed page of records for #{table}")
        notify_caller(state, {:request_error, {:records, table}, :invalid_response})

      _ ->
        :ok
    end

    {:ok, state}
  end

  # Over the connection's requests per minute: the request is sent again
  # once the sender's wait is over, unless its waits would pass the budget.
  defp handle_phoenix_message(
         _topic,
         "response:error",
         %{"error_code" => "rate_limited", "ref" => ref} = payload,
         _msg_ref,
         %{requests: %{} = requests} = state
       )
       when is_map_key(requests, ref) do
    request = Map.fetch!(requests, ref)

    case RateLimit.next_wait(payload["retry_after"], request.waited) do
      {:wait, seconds} ->
        Logger.info("Sync.WebSocketClient: The sender is rate limiting; waiting #{seconds} s")
        notify_caller(state, {:rate_limited, state.pending_refs[ref], seconds})
        Process.send_after(self(), {:retry_request, ref}, seconds * 1000)
        requests = Map.put(state.requests, ref, %{request | waited: request.waited + seconds})
        {:ok, %{state | requests: requests}}

      :give_up ->
        {request_type, state} = pop_request(state, ref)
        notify_caller(state, {:request_error, request_type, :rate_limited})
        {:ok, state}
    end
  end

  defp handle_phoenix_message(
         _topic,
         "response:error",
         %{"error" => error, "ref" => ref},
         _msg_ref,
         state
       ) do
    Logger.warning("Sync.WebSocketClient: Error response from sender")
    {request_type, state} = pop_request(state, ref)
    notify_caller(state, {:request_error, request_type, error_text(error)})
    {:ok, state}
  end

  # The topic is "transfer:" and the session code, so it is not logged.
  defp handle_phoenix_message(_topic, event, payload, _ref, state) do
    Logger.debug("Sync.WebSocketClient: Received an unknown event")

    notify_caller(state, {:message, event, payload})
    {:ok, state}
  end

  # The sender's `error` is any JSON term, and the callers print it: only
  # text goes on, anything else is a malformed answer.
  defp error_text(error) when is_binary(error), do: error
  defp error_text(_error), do: :invalid_response

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp build_websocket_url(base_url, code) when is_binary(base_url) and is_binary(code) do
    with {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri} <- URI.new(base_url),
         true <- scheme in ["http", "https", "ws", "wss"] and is_binary(host) and host != "" do
      query = URI.decode_query(uri.query || "") |> Map.merge(%{"code" => code, "vsn" => "2.0.0"})

      {:ok,
       URI.to_string(%{
         uri
         | scheme: to_ws_scheme(scheme),
           path: to_sync_path(uri.path),
           query: URI.encode_query(query),
           fragment: nil
       })}
    else
      _ -> {:error, :invalid_sender_url}
    end
  rescue
    _ -> {:error, :invalid_sender_url}
  end

  defp build_websocket_url(_base_url, _code), do: {:error, :invalid_sender_url}

  defp safe_reason(reason) when reason in [:normal, :timeout, :nxdomain, :econnrefused],
    do: reason

  defp safe_reason(_reason), do: :offline

  defp to_ws_scheme("https"), do: "wss"
  defp to_ws_scheme("http"), do: "ws"
  defp to_ws_scheme("wss"), do: "wss"
  defp to_ws_scheme("ws"), do: "ws"

  defp to_sync_path(nil), do: "/sync/websocket"
  defp to_sync_path(""), do: "/sync/websocket"

  defp to_sync_path(p) do
    if String.ends_with?(p, "/sync/websocket") do
      p
    else
      "#{String.trim_trailing(p, "/")}/sync/websocket"
    end
  end

  defp encode_message(topic, event, payload, ref) do
    Jason.encode!([nil, ref, topic, event, payload])
  end

  defp next_ref(state) do
    ref = to_string(state.ref_counter + 1)
    {ref, %{state | ref_counter: state.ref_counter + 1}}
  end

  defp make_ref(%{ref_counter: counter}) do
    to_string(counter + 1)
  end

  defp track_request(state, ref, request_type, msg) do
    pending = Map.put(state.pending_refs, ref, request_type)
    requests = Map.put(state.requests || %{}, ref, %{msg: msg, waited: 0})
    %{state | pending_refs: pending, requests: requests}
  end

  defp pop_request(state, ref) do
    {request_type, pending} = Map.pop(state.pending_refs, ref)

    {request_type,
     %{state | pending_refs: pending, requests: Map.delete(state.requests || %{}, ref)}}
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp notify_caller(%{caller: caller}, message) when is_pid(caller) do
    if Process.alive?(caller) do
      send(caller, {:sync_client, message})
    end
  end

  defp notify_caller(_, _), do: :ok

  defp well_formed_records?(records), do: is_list(records) and Enum.all?(records, &is_map/1)

  # The position the sender says the next page continues from, or nil from
  # a sender that pages by offset. It is the peer's data: only the shape a
  # request may carry is kept.
  defp next_after(payload) do
    case PullCursor.from_params(%{"after" => payload["next_after"]}) do
      {:ok, position} -> position
      {:error, :invalid_cursor} -> nil
    end
  end
end
