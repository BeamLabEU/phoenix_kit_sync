defmodule PhoenixKitSync.Errors do
  @moduledoc """
  Single translation point for every error atom the sync module emits.

  Call sites return plain `{:error, :atom}` tuples — never free-text error
  strings — and the UI / API layer translates via `message/1` at the
  boundary. This keeps error semantics testable (you assert on the atom,
  not on a string that might get reworded) and makes translations
  consistent (every place that surfaces `:connection_expired` renders
  the exact same gettext string).

  Translations are in this module's own catalogue (`PhoenixKitSync.Gettext`,
  `priv/gettext`). Every clause calls `gettext/1` with a literal string so
  `mix gettext.extract` sees it. Do NOT refactor this into a lookup map —
  the extractor only sees literal arguments to `gettext/1` at the call site.

  Unknown atoms fall through to `inspect/1` so the catch-all returns a
  useful-if-ugly string rather than crashing.
  """

  use Gettext, backend: PhoenixKitSync.Gettext

  @type error_atom ::
          :already_exists
          | :already_used
          | :cannot_start
          | :connection_exists
          | :connection_expired
          | :connection_not_active
          | :connection_timeout
          | :disconnected
          | :download_limit_reached
          | :econnrefused
          | :empty_schema
          | :fetch_failed
          | :filter_needs_single_key
          | :import_failed
          | :incoming_denied
          | :invalid_code
          | :invalid_cursor
          | :invalid_registration
          | :invalid_column_name
          | :invalid_column_type
          | :invalid_filter
          | :invalid_identifier
          | :invalid_json
          | :invalid_password
          | :invalid_response
          | :invalid_sender_url
          | :invalid_status
          | :invalid_table_name
          | :invalid_token
          | :ip_not_allowed
          | :join_timeout
          | :missing_fields
          | :table_excluded
          | :table_not_allowed
          | :missing_code
          | :missing_connection_info
          | :module_disabled
          | :no_primary_key
          | :not_found
          | :nxdomain
          | :offline
          | :outside_allowed_hours
          | :paging_stalled
          | :password_required
          | :pull_failed
          | :rate_limited
          | :record_limit_reached
          | :response_too_large
          | :schema_without_primary_key
          | :sent_truncated
          | :source_without_primary_key
          | :status_change_not_allowed
          | :too_many_pending
          | :sender_ignores_filters
          | :table_missing_locally
          | :table_not_found
          | :timeout
          | :truncated
          | :unauthorized
          | :unavailable
          | :unexpected_response
          | :unsupported_key_type
          | :unsupported_column_type

  @doc false
  @spec public_message(term()) :: String.t()
  def public_message(reason) when is_atom(reason), do: message(reason)

  def public_message({:rate_limited, seconds} = reason) when is_integer(seconds),
    do: message(reason)

  def public_message(_reason), do: message(:unexpected_response)

  @doc """
  Returns a human-readable message for an error atom, changeset, or other
  value. Safe for any input — falls through to `inspect/1` for unknown
  terms.
  """
  @spec message(term()) :: String.t()

  def message(:already_exists), do: gettext("Already exists")
  def message(:already_used), do: gettext("Already used")
  def message(:cannot_start), do: gettext("Cannot start")
  def message(:connection_exists), do: gettext("A connection already exists")
  def message(:connection_expired), do: gettext("Connection has expired")
  def message(:connection_not_active), do: gettext("Connection is not active")
  def message(:connection_timeout), do: gettext("Connection timed out")
  def message(:disconnected), do: gettext("Disconnected")
  def message(:download_limit_reached), do: gettext("Download limit reached")
  def message(:econnrefused), do: gettext("Could not connect to the remote site")
  def message(:empty_schema), do: gettext("The sender's schema lists no columns")
  def message(:fetch_failed), do: gettext("Fetch failed")

  def message(:filter_needs_single_key),
    do:
      gettext(
        "The source table has no single-column primary key (a view has none), so it takes no ID filter"
      )

  def message(:import_failed),
    do: gettext("Importing this table failed; see the server log for details")

  def message(:incoming_denied), do: gettext("Incoming connections are not allowed")
  def message(:invalid_code), do: gettext("Invalid session code")

  def message(:invalid_cursor),
    do: gettext("Invalid cursor: it does not name this table's primary key values")

  def message(:invalid_registration),
    do: gettext("The connection request is not valid: check the site URL and the name")

  def message(:invalid_column_name),
    do: gettext("The sender sent a column name that is not a valid identifier")

  def message(:invalid_column_type),
    do:
      gettext(
        "The sender's schema has a column type that is not a plain type name, or an array column without its element type. If the source site runs an older sync, update it and try again"
      )

  def message(:invalid_filter),
    do:
      gettext(
        "Invalid record filter: enter at least one ID (up to 1000), or a range with at least one bound. An integer key takes only whole-number IDs, and a range needs an integer key"
      )

  def message(:invalid_identifier), do: gettext("Invalid identifier")
  def message(:invalid_json), do: gettext("Invalid JSON")
  def message(:invalid_password), do: gettext("Invalid password")
  def message(:invalid_response), do: gettext("Invalid response from remote site")
  def message(:invalid_sender_url), do: gettext("Invalid sender URL")
  def message(:invalid_status), do: gettext("Invalid status")
  def message(:invalid_table_name), do: gettext("Invalid table name")
  def message(:invalid_token), do: gettext("Invalid auth token")
  def message(:ip_not_allowed), do: gettext("IP address not in whitelist")
  def message(:missing_fields), do: gettext("Missing required fields")
  def message(:join_timeout), do: gettext("Connection timed out while joining")
  def message(:missing_code), do: gettext("Missing session code")
  def message(:missing_connection_info), do: gettext("Missing connection info")
  def message(:module_disabled), do: gettext("Sync module is disabled")

  def message(:no_primary_key),
    do:
      gettext(
        "Not pulled: the table has no primary key here, so repeat pulls would duplicate its rows"
      )

  def message(:not_found), do: gettext("Not found")
  def message(:nxdomain), do: gettext("Could not resolve the remote site's domain")
  def message(:offline), do: gettext("Remote site is offline")
  def message(:outside_allowed_hours), do: gettext("Outside allowed connection hours")

  def message(:paging_stalled),
    do: gettext("Transfer stopped: the sender kept answering the same page of the table")

  def message(:password_required), do: gettext("Password required")

  def message(:pull_failed),
    do: gettext("Pulling this table failed; see the server log for details")

  def message(:rate_limited),
    do: gettext("Too many requests to the sending site; it asked to wait and the wait ran out")

  def message(:record_limit_reached), do: gettext("Record limit reached")

  def message(:sent_truncated),
    do:
      gettext(
        "Stopped at this connection's max_records_per_request limit; the rest of the table was not sent"
      )

  def message(:source_without_primary_key),
    do:
      gettext(
        "Not pulled: the table has no primary key on the source site, so its rows have no order to page in"
      )

  def message(:status_change_not_allowed),
    do: gettext("This connection's current status does not allow that change")

  def message(:too_many_pending),
    do: gettext("Too many connection requests are awaiting approval; try again later")

  def message(:response_too_large),
    do: gettext("The remote site's answer was larger than this site accepts")

  def message(:sender_ignores_filters),
    do:
      gettext(
        "Not imported: the source site ignored the record filter. Update its sync module and try again"
      )

  def message(:table_excluded), do: gettext("This table is never synced")

  def message(:table_not_allowed),
    do: gettext("This connection is not authorised to access that table")

  def message(:schema_without_primary_key),
    do:
      gettext(
        "The sender did not report a primary key for this table. Update sync on the source site, or create the table here by hand"
      )

  def message(:table_missing_locally),
    do:
      gettext(
        "Not pulled: this table does not exist on this site. Create it from the Precise Transfer tab first"
      )

  def message(:table_not_found), do: gettext("Table not found")
  def message(:timeout), do: gettext("Request timed out")

  def message(:truncated),
    do:
      gettext(
        "Table only partly pulled: the sender stopped at its max_records_per_request limit and gave no way to continue. Update sync on the source site, or have its admin raise that limit"
      )

  # The sender is current and named the key type it has no cursor for:
  # updating it would not help, raising the limit does.
  def message({:rate_limited, seconds}) when is_integer(seconds),
    do: gettext("Too many requests; try again in %{seconds} s", seconds: seconds)

  def message({:truncated_key_type, type}) when is_binary(type),
    do:
      gettext(
        "Table only partly pulled: its key is of type %{type}, which the sender cannot continue from once it stops at its max_records_per_request limit. Have the source site's admin raise that limit for this connection",
        type: type
      )

  def message(:unauthorized), do: gettext("Unauthorized")
  def message(:unavailable), do: gettext("Unavailable")
  def message(:unexpected_response), do: gettext("Unexpected response from remote site")

  def message(:unsupported_key_type),
    do:
      gettext(
        "This table's key type does not take an ID filter (it takes integer, uuid or text keys)"
      )

  def message(:unsupported_column_type),
    do: gettext("The table has a column type that cannot be created automatically")

  def message({:error, reason}), do: message(reason)

  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} ->
      "#{field}: #{Enum.join(msgs, ", ")}"
    end)
  end

  def message(reason) when is_binary(reason), do: reason
  def message(reason), do: inspect(reason)

  @doc """
  The text for a transfer's stored `error_message`.

  A reason this module classified is stored as its error atom's name and
  translated here, so History shows it in the reader's language; any other
  text (an older row, a remote site's own message) is shown as stored.
  """
  @spec transfer_error(String.t() | nil) :: String.t() | nil
  @stored_errors ~w(sent_truncated truncated unauthorized table_not_found unexpected_response
    offline invalid_response pull_failed sender_ignores_filters invalid_column_name
    table_missing_locally no_primary_key import_failed response_too_large invalid_filter
    unsupported_key_type filter_needs_single_key download_limit_reached record_limit_reached
    connection_expired connection_not_active ip_not_allowed outside_allowed_hours invalid_password)a

  def transfer_error("truncated_key_type:" <> type), do: message({:truncated_key_type, type})

  def transfer_error(error_message) when is_binary(error_message) do
    case Enum.find(@stored_errors, &(Atom.to_string(&1) == error_message)) do
      nil -> error_message
      reason -> message(reason)
    end
  end

  def transfer_error(error_message), do: error_message
end
