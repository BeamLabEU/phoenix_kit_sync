defmodule PhoenixKitSync.Web.SyncWebsock do
  @moduledoc """
  WebSock handler for DB Sync module.

  Uses WebSock directly (not Phoenix.Socket/Channel) to avoid
  cross-OTP-app channel supervision issues.

  ## Authentication Types

  Supports two authentication methods:

  1. **Session-based** (`:session`) - Ephemeral sessions for manual transfers
     - Uses 8-character session codes
     - Tied to sender's LiveView process

  2. **Connection-based** (`:connection`) - Permanent connections
     - Uses auth tokens stored in database
     - Subject to access controls (allowed tables, limits, etc.)

  ## Message Protocol

  All messages are JSON arrays in Phoenix channel format:
  `[join_ref, ref, topic, event, payload]`

  Supported events:
  - `phx_join` - Join the transfer session
  - `request:capabilities` - Get server capabilities
  - `request:tables` - List available tables
  - `request:schema` - Get table schema
  - `request:count` - Get record count
  - `request:records` - Fetch records with pagination: `table`, `limit`
    and `offset`, or `after` (the `next_after` of the reply before) to
    continue from that key instead of the offset. The reply carries
    `records`, `offset`, `has_more` and, when the table's key has a cursor
    (`PhoenixKitSync.PullCursor`), `next_after`
  """

  @behaviour WebSock
  require Logger

  alias PhoenixKitSync
  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataExporter
  alias PhoenixKitSync.Errors
  alias PhoenixKitSync.Params
  alias PhoenixKitSync.PullCursor
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.SessionStore
  alias PhoenixKitSync.Transfers

  defstruct [
    :auth_type,
    :code,
    :session,
    :db_connection,
    :password,
    :refused,
    :joined,
    :receiver_info,
    :connection_info,
    # Where each table's next page continues, as this socket answered it:
    # `%{table => %{after: next_after | nil, offset: next_offset, at: ms}}`.
    pages: %{}
  ]

  # ===========================================
  # WEBSOCK CALLBACKS
  # ===========================================

  @impl WebSock
  def init(opts) do
    auth_type = Keyword.get(opts, :auth_type, :session)
    connection_info = Keyword.get(opts, :connection_info, %{})

    state =
      case auth_type do
        :session ->
          code = Keyword.get(opts, :code)
          session = Keyword.get(opts, :session)

          Logger.info("Sync.Websock: Session connection initialized")

          %__MODULE__{
            auth_type: :session,
            code: code,
            session: session,
            db_connection: nil,
            joined: false,
            connection_info: connection_info
          }

        :connection ->
          db_connection = Keyword.get(opts, :connection)

          Logger.info("Sync.Websock: Token connection initialized for #{db_connection.name}")

          %__MODULE__{
            auth_type: :connection,
            code: "conn:#{db_connection.uuid}",
            session: nil,
            db_connection: db_connection,
            password: Keyword.get(opts, :password),
            joined: false,
            connection_info: connection_info
          }
      end

    {:ok, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, [join_ref, ref, topic, event, payload]} when is_binary(topic) and is_binary(event) ->
        state = authorize(state, continuation?(event, payload, state), request?(event))
        handle_message(join_ref, ref, topic, event, payload, state)

      # Valid JSON that is not a `[join_ref, ref, topic, event, payload]`
      # frame: the peer's to get wrong, not this process's to crash on.
      {:ok, _not_a_frame} ->
        Logger.warning("Sync.Websock: Ignoring a message that is not a channel frame")
        {:ok, state}

      {:error, _reason} ->
        Logger.warning("Sync.Websock: Failed to decode message")
        {:ok, state}
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    # Ignore binary messages
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:sync, message}, state) do
    # Handle messages from LiveView or other processes
    Logger.debug("Sync.Websock: Received internal message: #{inspect(message)}")
    {:ok, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Sync.Websock: Unknown info message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, state) do
    Logger.info("Sync.Websock: Terminated (#{state.auth_type}), reason: #{inspect(reason)}")

    # Notify sender's LiveView that receiver disconnected
    if state.session && state.session[:owner_pid] do
      send(state.session.owner_pid, {:sync, :receiver_disconnected})
    end

    :ok
  end

  # ===========================================
  # MESSAGE HANDLERS
  # ===========================================

  # Handle join message
  defp handle_message(_join_ref, ref, topic, "phx_join", _payload, %{refused: reason} = state)
       when not is_nil(reason) do
    reply =
      encode_reply(ref, topic, "phx_reply", %{
        "status" => "error",
        "response" => %{"reason" => reason_code(reason)}
      })

    {:push, {:text, reply}, state}
  end

  defp handle_message(_join_ref, ref, "transfer:" <> code, "phx_join", payload, state) do
    if code == state.code do
      Logger.info("Sync.Websock: Receiver joined")

      # Extract receiver info from join payload
      receiver_info =
        case payload do
          %{"receiver_info" => %{} = info} -> info
          _ -> %{}
        end

      # Merge connection_info (from HTTP upgrade) with receiver_info (from join payload)
      full_connection_info = %{
        receiver_info: receiver_info,
        connection_info: state.connection_info
      }

      # Update session with connection info
      PhoenixKitSync.update_session(code, %{
        channel_pid: self(),
        receiver_info: receiver_info,
        connection_info: state.connection_info
      })

      # Notify sender's LiveView with full connection details
      if state.session && state.session[:owner_pid] do
        send(
          state.session.owner_pid,
          {:sync, {:receiver_joined, self(), full_connection_info}}
        )
      end

      state = %{state | joined: true, receiver_info: receiver_info}

      reply =
        encode_reply(ref, "transfer:#{code}", "phx_reply", %{"status" => "ok", "response" => %{}})

      {:push, {:text, reply}, state}
    else
      Logger.warning("Sync.Websock: Join refused - topic does not match this socket")

      reply =
        encode_reply(ref, "transfer:#{code}", "phx_reply", %{
          "status" => "error",
          "response" => %{"reason" => "code_mismatch"}
        })

      {:push, {:text, reply}, state}
    end
  end

  # Handle heartbeat
  defp handle_message(_join_ref, ref, "phoenix", "heartbeat", _payload, state) do
    reply = encode_reply(ref, "phoenix", "phx_reply", %{"status" => "ok", "response" => %{}})
    {:push, {:text, reply}, state}
  end

  # Handle capabilities request
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:capabilities",
         %{"ref" => client_ref},
         state
       ) do
    if state.joined do
      Logger.debug("Sync.Websock: Capabilities requested")

      capabilities = %{
        "version" => "1.0.0",
        "phoenix_kit_version" => Application.spec(:phoenix_kit_sync, :vsn) |> to_string(),
        "features" => ["list_tables", "get_schema", "fetch_records"]
      }

      response =
        encode_push("transfer:#{state.code}", "response:capabilities", %{
          "capabilities" => capabilities,
          "ref" => client_ref
        })

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # A permanent connection is authorized again for every request, against
  # the row as it is now (see authorize/1): a refused one gets the reason
  # and no data.
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:" <> _ = _event,
         payload,
         %{joined: true, refused: reason} = state
       )
       when not is_nil(reason) do
    response =
      encode_push(
        "transfer:#{state.code}",
        "response:error",
        refusal_payload(reason, if(is_map(payload), do: payload["ref"]))
      )

    {:push, {:text, response}, state}
  end

  # Handle tables request
  defp handle_message(_join_ref, _ref, _topic, "request:tables", %{"ref" => client_ref}, state) do
    if state.joined do
      Logger.debug("Sync.Websock: Tables requested")

      response =
        case SchemaInspector.list_tables() do
          {:ok, tables} ->
            # Filter tables based on connection settings for permanent connections
            filtered_tables = filter_allowed_tables(tables, state)

            encode_push("transfer:#{state.code}", "response:tables", %{
              "tables" => filtered_tables,
              "ref" => client_ref
            })

          {:error, reason} ->
            encode_push("transfer:#{state.code}", "response:error", %{
              "error" => Errors.public_message(reason),
              "ref" => client_ref
            })
        end

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle schema request
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:schema",
         %{"table" => table, "ref" => client_ref},
         state
       )
       when is_binary(table) do
    if state.joined do
      Logger.debug("Sync.Websock: Schema requested for #{table}")

      # Check table access for permanent connections
      response = fetch_and_respond_schema(table, client_ref, state)

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle count request
  defp handle_message(
         _join_ref,
         _ref,
         _topic,
         "request:count",
         %{"table" => table, "ref" => client_ref},
         state
       )
       when is_binary(table) do
    if state.joined do
      Logger.debug("Sync.Websock: Count requested for #{table}")

      response = fetch_and_respond_count(table, client_ref, state)

      {:push, {:text, response}, state}
    else
      {:ok, state}
    end
  end

  # Handle records request. The payload comes from the (potentially
  # malicious) WebSocket peer, so we Map.fetch/2 instead of Map.fetch!/2 —
  # a missing "table" or "ref" key returns a structured error response
  # rather than crashing the WebSock process.
  defp handle_message(_join_ref, _ref, _topic, "request:records", payload, state) do
    cond do
      not state.joined ->
        {:ok, state}

      not is_map(payload) or not is_binary(payload["table"]) or not is_binary(payload["ref"]) ->
        Logger.warning("Sync.Websock: request:records missing/invalid required fields")

        {:ok, state}

      true ->
        table = payload["table"]
        client_ref = payload["ref"]
        # The peer's numbers: anything but a whole number in range falls
        # back, so a bad value cannot reach the query.
        offset = Params.bounded_int(payload["offset"], 0, 0, Params.max_offset())
        limit = Params.bounded_int(payload["limit"], 100, 1, DataExporter.max_limit())

        # Apply connection's max_records_per_request limit
        effective_limit = get_effective_limit(limit, state)

        Logger.debug(
          "Sync.Websock: Records requested for #{table} (offset: #{offset}, limit: #{effective_limit})"
        )

        # A receiver that pages by key sends the position the page before
        # answered; one that does not sends an offset alone.
        page = [
          offset: offset,
          limit: effective_limit,
          after: PullCursor.from_params(payload),
          continuation: continuation?("request:records", payload, state)
        ]

        {response, state} = fetch_and_respond_records(table, page, client_ref, state)

        {:push, {:text, response}, state}
    end
  end

  # Catch-all for unknown messages
  # The topic is "transfer:" and the session code, so it is not logged.
  defp handle_message(_join_ref, _ref, _topic, event, _payload, state) do
    Logger.warning("Sync.Websock: Unknown message - event: #{inspect(event)}")

    {:ok, state}
  end

  # ===========================================
  # SCHEMA FETCHING HELPER
  # ===========================================

  defp fetch_and_respond_schema(table, client_ref, state) do
    if table_allowed?(table, state) do
      case SchemaInspector.get_schema(table) do
        {:ok, schema} ->
          encode_push("transfer:#{state.code}", "response:schema", %{
            "schema" => schema,
            "ref" => client_ref
          })

        {:error, :not_found} ->
          encode_push("transfer:#{state.code}", "response:error", %{
            "error" => "Table not found: #{table}",
            "ref" => client_ref
          })

        {:error, reason} ->
          encode_push("transfer:#{state.code}", "response:error", %{
            "error" => Errors.public_message(reason),
            "ref" => client_ref
          })
      end
    else
      encode_push("transfer:#{state.code}", "response:error", %{
        "error" => "Access denied to table: #{table}",
        "ref" => client_ref
      })
    end
  end

  # COUNT FETCHING HELPER
  # ===========================================

  defp fetch_and_respond_count(table, client_ref, state) do
    if table_allowed?(table, state) do
      case DataExporter.get_count(table) do
        {:ok, count} ->
          encode_push("transfer:#{state.code}", "response:count", %{
            "count" => count,
            "ref" => client_ref
          })

        {:error, reason} ->
          encode_push("transfer:#{state.code}", "response:error", %{
            "error" => Errors.public_message(reason),
            "ref" => client_ref
          })
      end
    else
      encode_push("transfer:#{state.code}", "response:error", %{
        "error" => "Access denied to table: #{table}",
        "ref" => client_ref
      })
    end
  end

  # RECORDS FETCHING HELPER
  # ===========================================

  defp fetch_and_respond_records(table, page, client_ref, state) do
    if table_allowed?(table, state) do
      fetch_records_for_table(table, page, client_ref, state)
    else
      {encode_push("transfer:#{state.code}", "response:error", %{
         "error" => "Access denied to table: #{table}",
         "ref" => client_ref
       }), state}
    end
  end

  # A permanent connection's page is read under a reservation
  # (Connections.reserve_transfer/2), which is what holds max_downloads and
  # max_records_total: the page is cut to what was granted, and a page that
  # sent nothing gives the reservation back.
  defp fetch_records_for_table(table, page, client_ref, state) do
    with {:ok, position} <- page[:after],
         {:ok, reservation} <- reserve(state, page),
         page = Keyword.put(page, :limit, granted(reservation, page)),
         {:ok, %{records: records, next_after: next_after}} <-
           reserved(
             reservation,
             DataExporter.fetch_page(table, Keyword.put(page, :after, position))
           ) do
      records_count = Enum.count(records)

      settle(reservation, records_count, table, state)

      response =
        encode_push(
          "transfer:#{state.code}",
          "response:records",
          records_reply(records, records_count, next_after, page, client_ref)
        )

      {response, remember_page(state, table, records_count, next_after, page)}
    else
      {:error, reason} when reason in [:download_limit_reached, :record_limit_reached] ->
        {encode_push("transfer:#{state.code}", "response:error", %{
           "error" => Errors.public_message(reason),
           "ref" => client_ref
         }), state}

      {:error, reason} ->
        {encode_push("transfer:#{state.code}", "response:error", %{
           "error" => Errors.public_message(reason),
           "ref" => client_ref
         }), state}
    end
  end

  defp reserve(%{auth_type: :connection, db_connection: connection}, page) do
    Connections.reserve_transfer(connection, %{
      downloads: if(page[:continuation], do: 0, else: 1),
      records: page[:limit]
    })
  end

  defp reserve(_session_state, _page), do: {:ok, nil}

  defp granted(nil, page), do: page[:limit]
  defp granted(reservation, _page), do: reservation.records

  defp reserved(nil, result), do: result
  defp reserved(_reservation, {:ok, _} = result), do: result

  defp reserved(reservation, error) do
    Connections.cancel_transfer(reservation)
    error
  end

  defp settle(nil, _records_count, _table, _state), do: :ok
  defp settle(reservation, 0, _table, _state), do: Connections.cancel_transfer(reservation)

  defp settle(reservation, records_count, table, state) do
    Connections.settle_transfer(reservation, records_count)
    track_transfer(state.db_connection, table, records_count, state.connection_info)
  end

  # A paged read of a table is one download however many requests it
  # takes. Which request continues one is decided from what this socket
  # itself answered, never from what the peer says about its request: the
  # page for a table is a continuation when it asks for exactly the
  # position (or, from a peer that pages by offset, the offset) the page
  # before ended on, within the time a REST cursor is good for. Its records
  # count like any page's.
  @continuation_ms 600_000

  defp continuation?("request:records", %{"table" => table} = payload, %{pages: pages})
       when is_map_key(pages, table) do
    expected = pages[table]

    fresh? = System.monotonic_time(:millisecond) - expected.at <= @continuation_ms

    case PullCursor.from_params(payload) do
      {:ok, nil} ->
        fresh? and
          Params.bounded_int(payload["offset"], 0, 0, Params.max_offset()) == expected.offset

      {:ok, position} ->
        fresh? and position == expected.after

      {:error, _reason} ->
        false
    end
  end

  defp continuation?(_event, _payload, _state), do: false

  # A page with rows may be followed by another, and a receiver reads on
  # until an empty one, so the position is kept whether or not the page was
  # full. The empty page ends the read: what comes after it is a new one.
  defp remember_page(state, table, 0, _next_after, _page),
    do: %{state | pages: Map.delete(state.pages, table)}

  defp remember_page(state, table, records_count, next_after, page) do
    next = %{
      after: next_after,
      offset: page[:offset] + records_count,
      at: System.monotonic_time(:millisecond)
    }

    %{state | pages: Map.put(state.pages, table, next)}
  end

  # "next_after" is only added, never nil: a receiver from before it reads
  # "records" and "offset" and pages by offset as it always did.
  defp records_reply(records, records_count, next_after, page, client_ref) do
    reply = %{
      "records" => records,
      "offset" => page[:offset],
      "has_more" => records_count == page[:limit],
      "ref" => client_ref
    }

    if next_after, do: Map.put(reply, "next_after", next_after), else: reply
  end

  # ===========================================
  # ENCODING HELPERS
  # ===========================================

  defp encode_reply(ref, topic, event, payload) do
    Jason.encode!([nil, ref, topic, event, payload])
  end

  defp encode_push(topic, event, payload) do
    Jason.encode!([nil, nil, topic, event, payload])
  end

  # ===========================================
  # ACCESS CONTROL HELPERS
  # ===========================================

  # Filter tables based on connection settings for permanent connections
  defp filter_allowed_tables(tables, %{auth_type: :session}), do: tables

  defp filter_allowed_tables(tables, %{auth_type: :connection, db_connection: conn}) do
    Enum.filter(tables, fn table ->
      table_name = if is_map(table), do: table["name"] || table[:name], else: table
      Connection.table_allowed?(conn, table_name)
    end)
  end

  # Check if a specific table is allowed for this connection
  defp table_allowed?(_table, %{auth_type: :session}), do: true

  defp table_allowed?(table, %{auth_type: :connection, db_connection: conn}) do
    Connection.table_allowed?(conn, table)
  end

  # Get the effective limit considering connection's max_records_per_request
  # and what is left of its max_records_total
  defp get_effective_limit(requested_limit, %{auth_type: :session}), do: requested_limit

  defp get_effective_limit(requested_limit, %{auth_type: :connection, db_connection: conn}) do
    max_per_request =
      Params.bounded_int(conn.max_records_per_request, 10_000, 1, DataExporter.max_limit())

    case Connections.remaining_records(conn) do
      :unlimited -> min(requested_limit, max_per_request)
      remaining -> Enum.min([requested_limit, max_per_request, max(remaining, 1)])
    end
  end

  # The socket outlives the moment it was authorized: the admin may revoke
  # or narrow the connection, a limit may be reached, the allowed hours may
  # end. So a permanent connection is loaded again and passed through
  # Connections.authorize_request/3 (what the upgrade and the REST actions
  # use) before every message; the state carries the fresh row, or the
  # reason it is refused.
  #
  # Only a `request:*` frame counts against the connection's requests per
  # minute; the join and heartbeats are the socket keeping itself open.
  defp authorize(
         %__MODULE__{auth_type: :connection, db_connection: snapshot} = state,
         continuation,
         request?
       ) do
    with %Connection{} = connection <- Connections.get_connection(snapshot.uuid),
         :ok <-
           Connections.authorize_request(
             connection,
             Map.get(state.connection_info || %{}, :remote_ip),
             password: state.password,
             continuation: continuation,
             rate_limit: request?
           ) do
      %{state | db_connection: connection, refused: nil}
    else
      nil -> %{state | refused: :connection_not_active}
      {:error, reason} -> %{state | refused: reason}
    end
  end

  defp authorize(%__MODULE__{auth_type: :session, code: code} = state, _continuation, _request?) do
    case SessionStore.get(code) do
      {:ok, %{direction: :send, owner_pid: owner} = session} ->
        if Process.alive?(owner),
          do: %{state | session: session, refused: nil},
          else: %{state | refused: :invalid_code}

      _ ->
        %{state | refused: :invalid_code}
    end
  end

  defp request?("request:" <> _), do: true
  defp request?(_event), do: false

  defp reason_code({:rate_limited, _seconds}), do: "rate_limited"
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  # A refused request gets the reason as text; one over the requests per
  # minute also gets "error_code" and the seconds to wait, so a receiver
  # can wait and ask again rather than fail.
  defp refusal_payload({:rate_limited, seconds} = reason, ref) do
    %{
      "error" => Errors.public_message(reason),
      "error_code" => "rate_limited",
      "retry_after" => seconds,
      "ref" => ref
    }
  end

  defp refusal_payload(reason, ref),
    do: %{"error" => Errors.public_message(reason), "ref" => ref}

  # Track transfer for permanent connections
  defp track_transfer(db_connection, table_name, records_count, connection_info) do
    attrs = %{
      direction: "send",
      connection_uuid: db_connection.uuid,
      table_name: table_name,
      records_requested: records_count,
      records_transferred: records_count,
      records_created: records_count,
      requester_ip: Map.get(connection_info, :remote_ip),
      requester_user_agent: truncate(Map.get(connection_info, :user_agent))
    }

    case Transfers.record_finished(attrs, :completed) do
      {:ok, _transfer} ->
        :ok

      {:error, _changeset} ->
        Logger.warning("Sync.Websock: Failed to track transfer for #{table_name}")
    end
  end

  # The user agent is the client's to choose; the column holds 255 characters.
  defp truncate(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp truncate(_value), do: nil
end
