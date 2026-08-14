defmodule PhoenixKitSync.ConnectionsActivityTest do
  @moduledoc """
  Pins the Batch 3 activity-logging deltas:
  - `update_connection/3` logs on BOTH `:ok` and `:error` branches
    (was unlogged on either before this batch).
  - `:error`-branch logging on the five status mutations
    (`delete_connection`, `approve_connection`, `suspend_connection`,
    `revoke_connection`, `reactivate_connection`). These branches are
    rarely reachable via the public API path (changesets use `change/2`
    with put_change, and DB-side failures surface as `Ecto.StaleEntryError`
    raises rather than `{:error, _}` tuples) so the runtime pins target
    `update_connection/3` and the others get structural source pins.

  Activity rows on `:error` carry `"db_pending": true` so the audit
  trail still records the user-initiated intent even though the DB
  write failed — analytics queries that filter on `action` see the
  attempt, not just successes.
  """

  use PhoenixKitSync.LiveCase

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  describe "update_connection/3 — :ok branch logs" do
    test "writes a sync.connection.updated row with changed_fields metadata" do
      connection = create_active_sender_connection()
      actor_uuid = PhoenixKitSync.TestActor.uuid()

      {:ok, _updated} =
        Connections.update_connection(
          connection,
          %{"max_records_per_request" => 5000},
          actor_uuid: actor_uuid
        )

      assert_activity_logged("sync.connection.updated",
        resource_uuid: connection.uuid,
        actor_uuid: actor_uuid
      )

      # Metadata captures which fields changed (names only; never values
      # — `download_password` and free-text fields stay out).
      activity = latest_activity_for(connection.uuid)
      assert "max_records_per_request" in activity.metadata["changed_fields"]
      refute Map.has_key?(activity.metadata, "db_pending")
    end

    test "actor_uuid: nil is recorded for system-initiated updates" do
      connection = create_active_sender_connection()

      {:ok, _updated} =
        Connections.update_connection(connection, %{"max_records_per_request" => 7000})

      assert_activity_logged("sync.connection.updated",
        resource_uuid: connection.uuid
      )

      activity = latest_activity_for(connection.uuid)
      assert is_nil(activity.actor_uuid)
    end
  end

  describe "update_connection/3 — :error branch logs" do
    test "writes a sync.connection.updated row with db_pending: true on validation failure" do
      connection = create_active_sender_connection()
      actor_uuid = PhoenixKitSync.TestActor.uuid()

      # `validate_number(:max_records_per_request, greater_than: 0)` rejects
      # this — the changeset returns `{:error, %Ecto.Changeset{}}` and the
      # error-branch logger fires.
      assert {:error, %Ecto.Changeset{}} =
               Connections.update_connection(
                 connection,
                 %{"max_records_per_request" => -1},
                 actor_uuid: actor_uuid
               )

      assert_activity_logged("sync.connection.updated",
        resource_uuid: connection.uuid,
        actor_uuid: actor_uuid
      )

      activity = latest_activity_for(connection.uuid)
      assert activity.metadata["db_pending"] == true
      assert "max_records_per_request" in activity.metadata["changed_fields"]
    end
  end

  # F3 follow-up: a no-op `update_connection/3` (form submit with every
  # value matching the current row) was producing an `"updated"` activity
  # row with `changed_fields = []`. Pure noise in the audit feed.
  describe "update_connection/3 — empty-change branch (F3)" do
    test "no-op update writes no activity row" do
      connection = create_active_sender_connection()
      actor_uuid = PhoenixKitSync.TestActor.uuid()

      before_count = activity_count_for(connection.uuid, "sync.connection.updated")

      # Same-value update: every attr matches the current struct.
      {:ok, _updated} =
        Connections.update_connection(
          connection,
          %{
            "name" => connection.name,
            "max_records_per_request" => connection.max_records_per_request
          },
          actor_uuid: actor_uuid
        )

      after_count = activity_count_for(connection.uuid, "sync.connection.updated")
      assert after_count == before_count
    end

    test "real change still writes the row (regression guard)" do
      # Confirms the empty-changes guard didn't accidentally swallow the
      # legitimate path. Without this, a future bug that always classifies
      # changes as `[]` would silently kill audit logging.
      connection = create_active_sender_connection()

      before_count = activity_count_for(connection.uuid, "sync.connection.updated")

      {:ok, _updated} =
        Connections.update_connection(
          connection,
          %{"max_records_per_request" => (connection.max_records_per_request || 10_000) + 1},
          actor_uuid: UUIDv7.generate()
        )

      after_count = activity_count_for(connection.uuid, "sync.connection.updated")
      assert after_count == before_count + 1
    end
  end

  # F2 follow-up: structural source pin. The rescue branch on the activity
  # log used to be `_ -> :ok` — silent. A broken `PhoenixKit.Activity.log/1`
  # in production wiped the audit trail with no breadcrumb. Force-raising
  # in tests would require dropping the activities table (sandbox-unsafe)
  # or mocking; since the codebase doesn't use mocks, we pin the source
  # shape to ensure future edits don't regress it back to silent.
  describe "log_sync_activity/4 — rescue branch logs (F2)" do
    test "rescue clause calls Logger.warning with action + connection_uuid + error" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      assert source =~
               ~r/rescue\s+#[^\n]*\n(?:\s*#[^\n]*\n)*\s+e ->\s+Logger\.warning\([\s\S]+?action=sync\.connection\.#\{action\}[\s\S]+?connection_uuid=#\{connection\.uuid\}[\s\S]+?error=#\{Exception\.message\(e\)\}/,
             "log_sync_activity rescue must Logger.warning with action, connection_uuid, and error message"
    end
  end

  describe "structural pins on the five status-mutation :error branches" do
    test "delete_connection logs on :error" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      assert source =~
               ~r/case repo\.delete\(connection\) do[\s\S]+?error ->\s+log_sync_activity\("deleted", connection, opts, %\{"db_pending" => true\}\)/,
             "delete_connection :error branch must call log_sync_activity with db_pending: true"
    end

    test "approve_connection logs on :error" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      assert source =~
               ~r/Connection\.approve_changeset[\s\S]+?error ->\s+log_sync_activity\("approved", connection, \[actor_uuid: admin_user_uuid\], %\{\s+"db_pending" => true\s+\}\)/,
             "approve_connection :error branch must call log_sync_activity with db_pending: true"
    end

    test "suspend_connection logs on :error with reason + db_pending" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      assert source =~
               ~r/Connection\.suspend_changeset[\s\S]+?error ->\s+log_sync_activity\("suspended", connection, \[actor_uuid: admin_user_uuid\], %\{\s+"reason" => reason,\s+"db_pending" => true\s+\}\)/,
             "suspend_connection :error branch must call log_sync_activity with db_pending: true"
    end

    test "revoke_connection logs on :error with reason + db_pending" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      assert source =~
               ~r/Connection\.revoke_changeset[\s\S]+?error ->\s+log_sync_activity\("revoked", connection, \[actor_uuid: admin_user_uuid\], %\{\s+"reason" => reason,\s+"db_pending" => true\s+\}\)/,
             "revoke_connection :error branch must call log_sync_activity with db_pending: true"
    end

    test "reactivate_connection logs on :error" do
      source = File.read!("lib/phoenix_kit_sync/connections.ex")

      assert source =~
               ~r/Connection\.reactivate_changeset[\s\S]+?error ->\s+log_sync_activity\("reactivated", connection, opts, %\{"db_pending" => true\}\)/,
             "reactivate_connection :error branch must call log_sync_activity with db_pending: true"
    end
  end

  # ---------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------

  defp create_active_sender_connection do
    {:ok, conn, _token} =
      Connections.create_connection(%{
        "name" => "Activity Test #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://activity-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    active
  end

  # Count rows matching (resource_uuid, action) for empty-change pinning.
  # Used by the F3 follow-up tests to assert that a no-op update writes
  # zero rows while a real change writes exactly one.
  defp activity_count_for(uuid, action) do
    raw =
      TestRepo.query!(
        """
        SELECT COUNT(*)
        FROM phoenix_kit_activities
        WHERE resource_uuid = $1 AND action = $2
        """,
        [Ecto.UUID.dump!(uuid), action]
      )

    [[count]] = raw.rows
    count
  end

  # Filter by action explicitly: `inserted_at` is second-precision and
  # the test inserts > 1 activity per second, so ORDER BY ties are
  # non-deterministic. The action filter pins the row we mean.
  defp latest_activity_for(uuid, action \\ "sync.connection.updated") do
    raw =
      TestRepo.query!(
        """
        SELECT action, actor_uuid, metadata
        FROM phoenix_kit_activities
        WHERE resource_uuid = $1 AND action = $2
        ORDER BY inserted_at DESC
        LIMIT 1
        """,
        [Ecto.UUID.dump!(uuid), action]
      )

    [[returned_action, actor_uuid_bytes, metadata]] = raw.rows

    %{
      action: returned_action,
      actor_uuid: actor_uuid_bytes && Ecto.UUID.load!(actor_uuid_bytes),
      metadata: metadata
    }
  end
end
