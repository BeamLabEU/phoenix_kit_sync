defmodule PhoenixKitSync.ErrorsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Errors

  # Every atom clause must return a specific non-empty string. A single
  # `is_binary(html) > 0` check is exactly the test smell the playbook
  # rejects at agents.md:270 — it passes for any output. These tests pin
  # the *content* of the returned string for every atom.

  describe "message/1 for known atoms" do
    @atom_expectations [
      {:already_exists, "Already exists"},
      {:already_used, "Already used"},
      {:cannot_start, "Cannot start"},
      {:connection_exists, "A connection already exists"},
      {:connection_expired, "Connection has expired"},
      {:connection_not_active, "Connection is not active"},
      {:connection_timeout, "Connection timed out"},
      {:disconnected, "Disconnected"},
      {:download_limit_reached, "Download limit reached"},
      {:econnrefused, "Could not connect to the remote site"},
      {:empty_schema, "The sender's schema lists no columns"},
      {:fetch_failed, "Fetch failed"},
      {:filter_needs_single_key,
       "The source table has no single-column primary key (a view has none), so it takes no ID filter"},
      {:import_failed, "Importing this table failed; see the server log for details"},
      {:incoming_denied, "Incoming connections are not allowed"},
      {:invalid_code, "Invalid session code"},
      {:invalid_column_name, "The sender sent a column name that is not a valid identifier"},
      {:invalid_column_type,
       "The sender's schema has a column type that is not a plain type name"},
      {:invalid_filter,
       "Invalid record filter: enter at least one ID (up to 1000), or a range with at least one bound. An integer key takes only whole-number IDs, and a range needs an integer key"},
      {:invalid_identifier, "Invalid identifier"},
      {:invalid_json, "Invalid JSON"},
      {:invalid_password, "Invalid password"},
      {:invalid_response, "Invalid response from remote site"},
      {:invalid_status, "Invalid status"},
      {:invalid_table_name, "Invalid table name"},
      {:invalid_token, "Invalid auth token"},
      {:ip_not_allowed, "IP address not in whitelist"},
      {:join_timeout, "Connection timed out while joining"},
      {:missing_fields, "Missing required fields"},
      {:missing_code, "Missing session code"},
      {:missing_connection_info, "Missing connection info"},
      {:module_disabled, "Sync module is disabled"},
      {:no_primary_key,
       "Not pulled: the table has no primary key here, so repeat pulls would duplicate its rows"},
      {:not_found, "Not found"},
      {:nxdomain, "Could not resolve the remote site's domain"},
      {:offline, "Remote site is offline"},
      {:outside_allowed_hours, "Outside allowed connection hours"},
      {:password_required, "Password required"},
      {:pull_failed, "Pulling this table failed; see the server log for details"},
      {:record_limit_reached, "Record limit reached"},
      {:sender_ignores_filters,
       "Not imported: the source site ignored the record filter. Update its sync module and try again"},
      {:table_not_allowed, "This connection is not authorised to access that table"},
      {:schema_without_primary_key,
       "The sender did not report a primary key for this table. Update sync on the source site, or create the table here by hand"},
      {:table_missing_locally,
       "Not pulled: this table does not exist on this site. Create it from the Precise Transfer tab first"},
      {:table_not_found, "Table not found"},
      {:timeout, "Request timed out"},
      {:truncated,
       "Table only partly pulled: the sender hit max_records_per_request. Its admin can raise it for this connection (not in the form), or pull the rest by ID range in Precise Transfer (single integer key)"},
      {:unauthorized, "Unauthorized"},
      {:unavailable, "Unavailable"},
      {:unsupported_key_type,
       "This table's key type does not take an ID filter (it takes integer, uuid or text keys)"},
      {:unexpected_response, "Unexpected response from remote site"}
    ]

    for {atom, expected} <- @atom_expectations do
      test "#{inspect(atom)} maps to #{inspect(expected)}" do
        assert Errors.message(unquote(atom)) == unquote(expected)
      end
    end
  end

  describe "message/1 unwrapping {:error, reason} tuples" do
    test "unwraps and translates the inner atom" do
      assert Errors.message({:error, :not_found}) == "Not found"
      assert Errors.message({:error, :invalid_token}) == "Invalid auth token"
    end
  end

  describe "message/1 for changesets" do
    test "flattens changeset errors into a semicolon-separated string" do
      changeset =
        %Ecto.Changeset{}
        |> Map.put(:errors,
          name: {"can't be blank", [validation: :required]},
          age: {"must be greater than %{number}", [validation: :number, number: 0]}
        )
        |> Map.put(:types, %{name: :string, age: :integer})

      msg = Errors.message(changeset)

      assert msg =~ "name: can't be blank"
      assert msg =~ "age: must be greater than 0"
      assert msg =~ "; "
    end
  end

  describe "message/1 fallbacks" do
    test "string pass-through" do
      assert Errors.message("custom error message") == "custom error message"
    end

    test "unknown atom falls back to inspect/1 rather than crashing" do
      assert Errors.message(:something_never_defined) == ":something_never_defined"
    end

    test "arbitrary term falls back to inspect/1" do
      assert Errors.message({:weird, :tuple, 42}) == "{:weird, :tuple, 42}"
    end
  end
end
