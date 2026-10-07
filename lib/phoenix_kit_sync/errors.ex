defmodule PhoenixKitSync.Errors do
  @moduledoc """
  Single translation point for every error atom the sync module emits.

  Call sites return plain `{:error, :atom}` tuples — never free-text error
  strings — and the UI / API layer translates via `message/1` at the
  boundary. This keeps error semantics testable (you assert on the atom,
  not on a string that might get reworded) and makes translations
  consistent (every place that surfaces `:connection_expired` renders
  the exact same gettext string).

  Translation files live in core `phoenix_kit`; this module only calls
  `gettext/1` with literal strings so `mix gettext.extract` in core picks
  them up correctly. Do NOT refactor this into a lookup map — the
  extractor only sees literal arguments to `gettext/1` at the call site.

  Unknown atoms fall through to `inspect/1` so the catch-all returns a
  useful-if-ugly string rather than crashing.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

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
          | :fetch_failed
          | :import_failed
          | :incoming_denied
          | :invalid_code
          | :invalid_column_name
          | :invalid_column_type
          | :invalid_identifier
          | :invalid_json
          | :invalid_password
          | :invalid_response
          | :invalid_status
          | :invalid_table_name
          | :invalid_token
          | :ip_not_allowed
          | :join_timeout
          | :missing_fields
          | :table_not_allowed
          | :missing_code
          | :missing_connection_info
          | :module_disabled
          | :no_primary_key
          | :not_found
          | :nxdomain
          | :offline
          | :outside_allowed_hours
          | :password_required
          | :pull_failed
          | :record_limit_reached
          | :table_missing_locally
          | :table_not_found
          | :timeout
          | :unauthorized
          | :unavailable
          | :unexpected_response

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
  def message(:fetch_failed), do: gettext("Fetch failed")

  def message(:import_failed),
    do: gettext("Importing this table failed; see the server log for details")

  def message(:incoming_denied), do: gettext("Incoming connections are not allowed")
  def message(:invalid_code), do: gettext("Invalid session code")

  def message(:invalid_column_name),
    do:
      gettext("Not imported: the sender's data has a column name that is not a valid identifier")

  def message(:invalid_column_type),
    do: gettext("The sender's schema has a column type that is not a plain type name")

  def message(:invalid_identifier), do: gettext("Invalid identifier")
  def message(:invalid_json), do: gettext("Invalid JSON")
  def message(:invalid_password), do: gettext("Invalid password")
  def message(:invalid_response), do: gettext("Invalid response from remote site")
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
  def message(:password_required), do: gettext("Password required")

  def message(:pull_failed),
    do: gettext("Pulling this table failed; see the server log for details")

  def message(:record_limit_reached), do: gettext("Record limit reached")

  def message(:table_not_allowed),
    do: gettext("This connection is not authorised to access that table")

  def message(:table_missing_locally),
    do:
      gettext(
        "Not pulled: this table does not exist on this site. Create it from the Precise Transfer tab first"
      )

  def message(:table_not_found), do: gettext("Table not found")
  def message(:timeout), do: gettext("Request timed out")
  def message(:unauthorized), do: gettext("Unauthorized")
  def message(:unavailable), do: gettext("Unavailable")
  def message(:unexpected_response), do: gettext("Unexpected response from remote site")

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
end
