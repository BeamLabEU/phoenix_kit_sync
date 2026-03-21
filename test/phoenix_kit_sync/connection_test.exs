defmodule PhoenixKitSync.ConnectionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Connection
  import PhoenixKitSync.ChangesetHelpers

  @valid_attrs %{
    name: "Test Connection",
    direction: "sender",
    site_url: "https://example.com"
  }

  # ===========================================
  # CHANGESET TESTS
  # ===========================================

  describe "changeset/2 with valid data" do
    test "accepts minimal required fields" do
      changeset = Connection.changeset(%Connection{}, @valid_attrs)
      assert changeset.valid?
    end

    test "accepts all optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          approval_mode: "require_approval",
          allowed_tables: ["users", "posts"],
          excluded_tables: ["sessions"],
          auto_approve_tables: ["posts"],
          max_downloads: 100,
          max_records_total: 50_000,
          max_records_per_request: 5_000,
          rate_limit_requests_per_minute: 30,
          ip_whitelist: ["192.168.1.1"],
          allowed_hours_start: 2,
          allowed_hours_end: 6,
          default_conflict_strategy: "skip",
          auto_sync_enabled: true,
          auto_sync_tables: ["users"],
          auto_sync_interval_minutes: 30,
          metadata: %{"note" => "test"}
        })

      changeset = Connection.changeset(%Connection{}, attrs)
      assert changeset.valid?
    end

    test "accepts receiver direction" do
      attrs = %{@valid_attrs | direction: "receiver"}
      changeset = Connection.changeset(%Connection{}, attrs)
      assert changeset.valid?
    end

    test "accepts all valid approval modes" do
      for mode <- ~w(auto_approve require_approval per_table) do
        attrs = Map.put(@valid_attrs, :approval_mode, mode)
        changeset = Connection.changeset(%Connection{}, attrs)
        assert changeset.valid?, "Expected approval_mode '#{mode}' to be valid"
      end
    end

    test "accepts all valid conflict strategies" do
      for strategy <- ~w(skip overwrite merge append) do
        attrs = Map.put(@valid_attrs, :default_conflict_strategy, strategy)
        changeset = Connection.changeset(%Connection{}, attrs)
        assert changeset.valid?, "Expected strategy '#{strategy}' to be valid"
      end
    end
  end

  describe "changeset/2 with invalid data" do
    test "requires name" do
      attrs = Map.delete(@valid_attrs, :name)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "can't be blank" in errors_on(changeset).name
    end

    test "requires direction" do
      attrs = Map.delete(@valid_attrs, :direction)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "can't be blank" in errors_on(changeset).direction
    end

    test "requires site_url" do
      attrs = Map.delete(@valid_attrs, :site_url)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "can't be blank" in errors_on(changeset).site_url
    end

    test "rejects invalid direction" do
      attrs = %{@valid_attrs | direction: "bidirectional"}
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "is invalid" in errors_on(changeset).direction
    end

    test "rejects invalid approval mode" do
      attrs = Map.put(@valid_attrs, :approval_mode, "yolo")
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "is invalid" in errors_on(changeset).approval_mode
    end

    test "rejects invalid conflict strategy" do
      attrs = Map.put(@valid_attrs, :default_conflict_strategy, "nuke")
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "is invalid" in errors_on(changeset).default_conflict_strategy
    end

    test "rejects invalid status" do
      attrs = Map.put(@valid_attrs, :status, "invalid_status")
      changeset = Connection.changeset(%Connection{}, attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects zero max_records_per_request" do
      attrs = Map.put(@valid_attrs, :max_records_per_request, 0)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert errors_on(changeset).max_records_per_request != []
    end

    test "rejects negative rate limit" do
      attrs = Map.put(@valid_attrs, :rate_limit_requests_per_minute, -1)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert errors_on(changeset).rate_limit_requests_per_minute != []
    end

    test "rejects invalid allowed_hours_start" do
      attrs = Map.put(@valid_attrs, :allowed_hours_start, 24)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert errors_on(changeset).allowed_hours_start != []
    end

    test "rejects invalid allowed_hours_end" do
      attrs = Map.put(@valid_attrs, :allowed_hours_end, -1)
      changeset = Connection.changeset(%Connection{}, attrs)
      assert errors_on(changeset).allowed_hours_end != []
    end
  end

  describe "changeset/2 token hashing" do
    test "hashes auth_token when provided" do
      attrs = Map.put(@valid_attrs, :auth_token, "my-secret-token")
      changeset = Connection.changeset(%Connection{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :auth_token_hash) != nil
    end

    test "does not set hash when auth_token is nil" do
      changeset = Connection.changeset(%Connection{}, @valid_attrs)
      assert Ecto.Changeset.get_change(changeset, :auth_token_hash) == nil
    end

    test "hashes download_password when provided" do
      attrs = Map.put(@valid_attrs, :download_password, "secret123")
      changeset = Connection.changeset(%Connection{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :download_password_hash) != nil
    end

    test "clears download_password_hash when empty string" do
      attrs = Map.put(@valid_attrs, :download_password, "")
      changeset = Connection.changeset(%Connection{}, attrs)
      assert Ecto.Changeset.get_change(changeset, :download_password_hash) == nil
    end
  end

  # ===========================================
  # STATUS CHANGESETS
  # ===========================================

  describe "approve_changeset/2" do
    test "sets status to active with approval metadata" do
      conn = %Connection{status: "pending"}
      changeset = Connection.approve_changeset(conn, "admin-uuid-123")
      assert Ecto.Changeset.get_change(changeset, :status) == "active"
      assert Ecto.Changeset.get_change(changeset, :approved_by_uuid) == "admin-uuid-123"
      assert Ecto.Changeset.get_change(changeset, :approved_at) != nil
    end
  end

  describe "suspend_changeset/3" do
    test "sets status to suspended with reason" do
      conn = %Connection{status: "active"}
      changeset = Connection.suspend_changeset(conn, "admin-uuid", "Security audit")
      assert Ecto.Changeset.get_change(changeset, :status) == "suspended"
      assert Ecto.Changeset.get_change(changeset, :suspended_reason) == "Security audit"
      assert Ecto.Changeset.get_change(changeset, :suspended_by_uuid) == "admin-uuid"
    end
  end

  describe "revoke_changeset/3" do
    test "sets status to revoked with reason" do
      conn = %Connection{status: "active"}
      changeset = Connection.revoke_changeset(conn, "admin-uuid", "No longer needed")
      assert Ecto.Changeset.get_change(changeset, :status) == "revoked"
      assert Ecto.Changeset.get_change(changeset, :revoked_reason) == "No longer needed"
    end
  end

  describe "reactivate_changeset/1" do
    test "clears suspended state and sets active" do
      conn = %Connection{status: "suspended", suspended_at: DateTime.utc_now()}
      changeset = Connection.reactivate_changeset(conn)
      assert Ecto.Changeset.get_change(changeset, :status) == "active"
      assert Ecto.Changeset.get_change(changeset, :suspended_at) == nil
      assert Ecto.Changeset.get_change(changeset, :suspended_by_uuid) == nil
      assert Ecto.Changeset.get_change(changeset, :suspended_reason) == nil
    end
  end

  # ===========================================
  # TOKEN VERIFICATION
  # ===========================================

  describe "verify_auth_token/2" do
    test "returns true for matching token" do
      token = "test-token-123"
      hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      conn = %Connection{auth_token_hash: hash}
      assert Connection.verify_auth_token(conn, token)
    end

    test "returns false for non-matching token" do
      hash = :crypto.hash(:sha256, "correct") |> Base.encode16(case: :lower)
      conn = %Connection{auth_token_hash: hash}
      refute Connection.verify_auth_token(conn, "wrong")
    end

    test "returns false for nil connection" do
      refute Connection.verify_auth_token(nil, "token")
    end
  end

  describe "verify_download_password/2" do
    test "returns true when no password set (nil)" do
      conn = %Connection{download_password_hash: nil}
      assert Connection.verify_download_password(conn, "anything")
    end

    test "returns true when no password set (empty)" do
      conn = %Connection{download_password_hash: ""}
      assert Connection.verify_download_password(conn, "anything")
    end

    test "returns true for matching password" do
      password = "secret"
      hash = :crypto.hash(:sha256, password) |> Base.encode16(case: :lower)
      conn = %Connection{download_password_hash: hash}
      assert Connection.verify_download_password(conn, password)
    end

    test "returns false for wrong password" do
      hash = :crypto.hash(:sha256, "correct") |> Base.encode16(case: :lower)
      conn = %Connection{download_password_hash: hash}
      refute Connection.verify_download_password(conn, "wrong")
    end
  end

  describe "generate_auth_token/0" do
    test "returns a non-empty binary" do
      token = Connection.generate_auth_token()
      assert is_binary(token)
      assert byte_size(token) > 0
    end

    test "generates unique tokens" do
      tokens = for _ <- 1..10, do: Connection.generate_auth_token()
      assert length(Enum.uniq(tokens)) == 10
    end
  end

  # ===========================================
  # ACCESS CONTROL CHECKS
  # ===========================================

  describe "active?/1" do
    test "true for active connection within limits" do
      conn = %Connection{
        status: "active",
        expires_at: nil,
        max_downloads: nil,
        downloads_used: 0,
        max_records_total: nil,
        records_downloaded: 0
      }

      assert Connection.active?(conn)
    end

    test "false for non-active status" do
      for status <- ~w(pending suspended revoked expired) do
        conn = %Connection{status: status}
        refute Connection.active?(conn), "Expected status '#{status}' to not be active"
      end
    end

    test "false when download limit exceeded" do
      conn = %Connection{
        status: "active",
        expires_at: nil,
        max_downloads: 5,
        downloads_used: 5,
        max_records_total: nil,
        records_downloaded: 0
      }

      refute Connection.active?(conn)
    end

    test "false when record limit exceeded" do
      conn = %Connection{
        status: "active",
        expires_at: nil,
        max_downloads: nil,
        downloads_used: 0,
        max_records_total: 100,
        records_downloaded: 100
      }

      refute Connection.active?(conn)
    end
  end

  describe "expired?/1" do
    test "false when no expiration" do
      refute Connection.expired?(%Connection{expires_at: nil})
    end

    test "true when past expiration" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      assert Connection.expired?(%Connection{expires_at: past})
    end

    test "false when before expiration" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second)
      refute Connection.expired?(%Connection{expires_at: future})
    end
  end

  describe "within_download_limits?/1" do
    test "true when no limit set" do
      assert Connection.within_download_limits?(%Connection{max_downloads: nil})
    end

    test "true when under limit" do
      assert Connection.within_download_limits?(%Connection{max_downloads: 10, downloads_used: 5})
    end

    test "false when at limit" do
      refute Connection.within_download_limits?(%Connection{
               max_downloads: 10,
               downloads_used: 10
             })
    end
  end

  describe "within_record_limits?/1" do
    test "true when no limit set" do
      assert Connection.within_record_limits?(%Connection{max_records_total: nil})
    end

    test "true when under limit" do
      assert Connection.within_record_limits?(%Connection{
               max_records_total: 1000,
               records_downloaded: 500
             })
    end

    test "false when at limit" do
      refute Connection.within_record_limits?(%Connection{
               max_records_total: 1000,
               records_downloaded: 1000
             })
    end
  end

  describe "ip_allowed?/2" do
    test "true when whitelist is empty" do
      assert Connection.ip_allowed?(%Connection{ip_whitelist: []})
    end

    test "true when whitelist is nil" do
      assert Connection.ip_allowed?(%Connection{ip_whitelist: nil})
    end

    test "true when IP is in whitelist" do
      conn = %Connection{ip_whitelist: ["192.168.1.1", "10.0.0.1"]}
      assert Connection.ip_allowed?(conn, "192.168.1.1")
    end

    test "false when IP is not in whitelist" do
      conn = %Connection{ip_whitelist: ["192.168.1.1"]}
      refute Connection.ip_allowed?(conn, "10.0.0.99")
    end
  end

  describe "table_allowed?/2" do
    test "true when both lists empty (all tables allowed)" do
      conn = %Connection{allowed_tables: [], excluded_tables: []}
      assert Connection.table_allowed?(conn, "users")
    end

    test "true when table is in allowed list" do
      conn = %Connection{allowed_tables: ["users", "posts"], excluded_tables: []}
      assert Connection.table_allowed?(conn, "users")
    end

    test "false when table is not in allowed list" do
      conn = %Connection{allowed_tables: ["users"], excluded_tables: []}
      refute Connection.table_allowed?(conn, "secrets")
    end

    test "false when table is in excluded list" do
      conn = %Connection{allowed_tables: [], excluded_tables: ["secrets"]}
      refute Connection.table_allowed?(conn, "secrets")
    end

    test "false when table is in both allowed and excluded" do
      conn = %Connection{allowed_tables: ["users"], excluded_tables: ["users"]}
      refute Connection.table_allowed?(conn, "users")
    end
  end

  describe "requires_approval?/2" do
    test "false for auto_approve mode" do
      conn = %Connection{approval_mode: "auto_approve"}
      refute Connection.requires_approval?(conn, "users")
    end

    test "true for require_approval mode" do
      conn = %Connection{approval_mode: "require_approval"}
      assert Connection.requires_approval?(conn, "users")
    end

    test "false for per_table mode when table is auto-approved" do
      conn = %Connection{approval_mode: "per_table", auto_approve_tables: ["users"]}
      refute Connection.requires_approval?(conn, "users")
    end

    test "true for per_table mode when table is not auto-approved" do
      conn = %Connection{approval_mode: "per_table", auto_approve_tables: ["users"]}
      assert Connection.requires_approval?(conn, "secrets")
    end
  end

  # ===========================================
  # WITHIN_ALLOWED_HOURS? TESTS
  # ===========================================

  describe "within_allowed_hours?/1" do
    test "returns true when allowed_hours_start is nil" do
      conn = %Connection{allowed_hours_start: nil, allowed_hours_end: 17}
      assert Connection.within_allowed_hours?(conn)
    end

    test "returns true when allowed_hours_end is nil" do
      conn = %Connection{allowed_hours_start: 9, allowed_hours_end: nil}
      assert Connection.within_allowed_hours?(conn)
    end

    test "normal range (start=9, end=17) — result depends on current hour" do
      # We can't control the current hour, but we can verify the function
      # doesn't crash and returns a boolean for a normal daytime range
      conn = %Connection{allowed_hours_start: 9, allowed_hours_end: 17}
      result = Connection.within_allowed_hours?(conn)
      assert is_boolean(result)
    end

    test "overnight range (start=22, end=6) — result depends on current hour" do
      # Overnight range is the tricky branch: current_hour >= 22 OR current_hour <= 6
      conn = %Connection{allowed_hours_start: 22, allowed_hours_end: 6}
      result = Connection.within_allowed_hours?(conn)
      assert is_boolean(result)
    end

    test "when start equals end, only that exact hour matches" do
      # When start == end, the normal branch fires: current_hour >= h and current_hour <= h
      # So only the exact matching hour returns true
      current_hour = DateTime.utc_now().hour
      conn_match = %Connection{allowed_hours_start: current_hour, allowed_hours_end: current_hour}
      assert Connection.within_allowed_hours?(conn_match)

      # An hour that is definitely not the current hour
      other_hour = rem(current_hour + 12, 24)

      conn_no_match = %Connection{
        allowed_hours_start: other_hour,
        allowed_hours_end: other_hour
      }

      refute Connection.within_allowed_hours?(conn_no_match)
    end

    test "full day range (start=0, end=23) always returns true" do
      conn = %Connection{allowed_hours_start: 0, allowed_hours_end: 23}
      assert Connection.within_allowed_hours?(conn)
    end
  end

  # ===========================================
  # SETTINGS_CHANGESET TESTS
  # ===========================================

  describe "settings_changeset/2" do
    test "accepts valid settings updates" do
      conn = %Connection{name: "Old Name", approval_mode: "auto_approve"}

      changeset =
        Connection.settings_changeset(conn, %{
          name: "New Name",
          approval_mode: "require_approval",
          max_records_per_request: 5000,
          rate_limit_requests_per_minute: 30
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "New Name"
      assert Ecto.Changeset.get_change(changeset, :approval_mode) == "require_approval"
    end

    test "validates approval_mode inclusion" do
      conn = %Connection{}
      changeset = Connection.settings_changeset(conn, %{approval_mode: "yolo"})
      assert "is invalid" in errors_on(changeset).approval_mode
    end

    test "validates conflict_strategy inclusion" do
      conn = %Connection{}
      changeset = Connection.settings_changeset(conn, %{default_conflict_strategy: "nuke"})
      assert "is invalid" in errors_on(changeset).default_conflict_strategy
    end

    test "validates max_records_per_request must be greater than 0" do
      conn = %Connection{}
      changeset = Connection.settings_changeset(conn, %{max_records_per_request: 0})
      assert errors_on(changeset).max_records_per_request != []
    end

    test "validates rate_limit must be greater than 0" do
      conn = %Connection{}
      changeset = Connection.settings_changeset(conn, %{rate_limit_requests_per_minute: 0})
      assert errors_on(changeset).rate_limit_requests_per_minute != []
    end

    test "validates allowed_hours_start between 0 and 23" do
      conn = %Connection{}

      changeset_low = Connection.settings_changeset(conn, %{allowed_hours_start: -1})
      assert errors_on(changeset_low).allowed_hours_start != []

      changeset_high = Connection.settings_changeset(conn, %{allowed_hours_start: 24})
      assert errors_on(changeset_high).allowed_hours_start != []

      changeset_ok = Connection.settings_changeset(conn, %{allowed_hours_start: 0})
      assert changeset_ok.valid?
    end

    test "validates allowed_hours_end between 0 and 23" do
      conn = %Connection{}

      changeset_low = Connection.settings_changeset(conn, %{allowed_hours_end: -1})
      assert errors_on(changeset_low).allowed_hours_end != []

      changeset_high = Connection.settings_changeset(conn, %{allowed_hours_end: 24})
      assert errors_on(changeset_high).allowed_hours_end != []

      changeset_ok = Connection.settings_changeset(conn, %{allowed_hours_end: 23})
      assert changeset_ok.valid?
    end

    test "hashes download_password when provided" do
      conn = %Connection{}
      changeset = Connection.settings_changeset(conn, %{download_password: "newsecret"})
      assert Ecto.Changeset.get_change(changeset, :download_password_hash) != nil
    end

    test "clears download_password_hash when empty string" do
      conn = %Connection{download_password_hash: "oldhash"}
      changeset = Connection.settings_changeset(conn, %{download_password: ""})
      assert Ecto.Changeset.get_change(changeset, :download_password_hash) == nil
    end
  end

  # ===========================================
  # STATS_CHANGESET TESTS
  # ===========================================

  describe "stats_changeset/2" do
    test "accepts stat updates" do
      conn = %Connection{downloads_used: 0, records_downloaded: 0}

      changeset =
        Connection.stats_changeset(conn, %{
          downloads_used: 5,
          records_downloaded: 500,
          total_transfers: 10,
          total_records_transferred: 5000,
          total_bytes_transferred: 1_000_000
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :downloads_used) == 5
      assert Ecto.Changeset.get_change(changeset, :records_downloaded) == 500
      assert Ecto.Changeset.get_change(changeset, :total_transfers) == 10
    end

    test "accepts timestamp updates" do
      conn = %Connection{}
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Connection.stats_changeset(conn, %{
          last_connected_at: now,
          last_transfer_at: now
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :last_connected_at) == now
      assert Ecto.Changeset.get_change(changeset, :last_transfer_at) == now
    end
  end

  # ===========================================
  # TOKEN HASHING DETERMINISM
  # ===========================================

  describe "token hashing determinism" do
    test "same input produces same hash" do
      attrs1 = Map.put(@valid_attrs, :auth_token, "deterministic-token")
      attrs2 = Map.put(@valid_attrs, :auth_token, "deterministic-token")

      changeset1 = Connection.changeset(%Connection{}, attrs1)
      changeset2 = Connection.changeset(%Connection{}, attrs2)

      hash1 = Ecto.Changeset.get_change(changeset1, :auth_token_hash)
      hash2 = Ecto.Changeset.get_change(changeset2, :auth_token_hash)

      assert hash1 == hash2
    end

    test "different inputs produce different hashes" do
      attrs1 = Map.put(@valid_attrs, :auth_token, "token-alpha")
      attrs2 = Map.put(@valid_attrs, :auth_token, "token-beta")

      changeset1 = Connection.changeset(%Connection{}, attrs1)
      changeset2 = Connection.changeset(%Connection{}, attrs2)

      hash1 = Ecto.Changeset.get_change(changeset1, :auth_token_hash)
      hash2 = Ecto.Changeset.get_change(changeset2, :auth_token_hash)

      assert hash1 != hash2
    end
  end

  # ===========================================
  # EDGE CASES
  # ===========================================

  describe "edge cases" do
    test "empty string name still passes (no length validation)" do
      attrs = %{@valid_attrs | name: ""}
      changeset = Connection.changeset(%Connection{}, attrs)
      # validate_required treats empty string as blank
      assert "can't be blank" in errors_on(changeset).name
    end

    test "very long site_url is accepted" do
      long_url = "https://example.com/" <> String.duplicate("a", 2000)
      attrs = %{@valid_attrs | site_url: long_url}
      changeset = Connection.changeset(%Connection{}, attrs)
      assert changeset.valid?
    end

    test "non-empty name passes" do
      attrs = %{@valid_attrs | name: "x"}
      changeset = Connection.changeset(%Connection{}, attrs)
      assert changeset.valid?
    end
  end
end
