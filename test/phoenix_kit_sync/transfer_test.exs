defmodule PhoenixKitSync.TransferTest do
  use ExUnit.Case, async: true

  alias PhoenixKitSync.Transfer
  import PhoenixKitSync.ChangesetHelpers

  @valid_attrs %{
    direction: "receive",
    table_name: "users"
  }

  # ===========================================
  # CHANGESET TESTS
  # ===========================================

  describe "changeset/2 with valid data" do
    test "accepts minimal required fields" do
      changeset = Transfer.changeset(%Transfer{}, @valid_attrs)
      assert changeset.valid?
    end

    test "accepts all optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          session_code: "A7X9K2M4",
          remote_site_url: "https://example.com",
          records_requested: 100,
          conflict_strategy: "skip",
          status: "pending",
          requires_approval: false,
          requester_ip: "192.168.1.1",
          requester_user_agent: "PhoenixKitSync/0.1.0",
          metadata: %{"batch" => 1}
        })

      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert changeset.valid?
    end

    test "accepts send direction" do
      attrs = %{@valid_attrs | direction: "send"}
      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert changeset.valid?
    end

    test "accepts all valid conflict strategies" do
      for strategy <- ~w(skip overwrite merge append) do
        attrs = Map.put(@valid_attrs, :conflict_strategy, strategy)
        changeset = Transfer.changeset(%Transfer{}, attrs)
        assert changeset.valid?, "Expected strategy '#{strategy}' to be valid"
      end
    end

    test "accepts all valid statuses" do
      statuses =
        ~w(pending pending_approval approved denied in_progress completed failed cancelled expired)

      for status <- statuses do
        attrs = Map.put(@valid_attrs, :status, status)
        changeset = Transfer.changeset(%Transfer{}, attrs)
        assert changeset.valid?, "Expected status '#{status}' to be valid"
      end
    end
  end

  describe "changeset/2 with invalid data" do
    test "requires direction" do
      attrs = Map.delete(@valid_attrs, :direction)
      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert "can't be blank" in errors_on(changeset).direction
    end

    test "requires table_name" do
      attrs = Map.delete(@valid_attrs, :table_name)
      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert "can't be blank" in errors_on(changeset).table_name
    end

    test "rejects invalid direction" do
      attrs = %{@valid_attrs | direction: "upload"}
      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert "is invalid" in errors_on(changeset).direction
    end

    test "rejects invalid conflict strategy" do
      attrs = Map.put(@valid_attrs, :conflict_strategy, "destroy")
      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert "is invalid" in errors_on(changeset).conflict_strategy
    end

    test "rejects invalid status" do
      attrs = Map.put(@valid_attrs, :status, "unknown")
      changeset = Transfer.changeset(%Transfer{}, attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "allows nil conflict strategy" do
      changeset = Transfer.changeset(%Transfer{}, @valid_attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :conflict_strategy) == nil
    end
  end

  # ===========================================
  # STATUS CHANGESETS
  # ===========================================

  describe "start_changeset/1" do
    test "sets status to in_progress with started_at" do
      transfer = %Transfer{status: "pending"}
      changeset = Transfer.start_changeset(transfer)
      assert Ecto.Changeset.get_change(changeset, :status) == "in_progress"
      assert Ecto.Changeset.get_change(changeset, :started_at) != nil
    end
  end

  describe "progress_changeset/2" do
    test "accepts progress updates" do
      transfer = %Transfer{status: "in_progress"}

      changeset =
        Transfer.progress_changeset(transfer, %{
          records_transferred: 50,
          records_created: 40,
          records_updated: 5,
          records_skipped: 3,
          records_failed: 2,
          bytes_transferred: 15_000
        })

      assert changeset.valid?
    end

    test "rejects negative values" do
      transfer = %Transfer{status: "in_progress"}
      changeset = Transfer.progress_changeset(transfer, %{records_transferred: -1})
      assert errors_on(changeset).records_transferred != []
    end
  end

  describe "complete_changeset/2" do
    test "sets completed status with final stats" do
      transfer = %Transfer{status: "in_progress"}

      changeset =
        Transfer.complete_changeset(transfer, %{
          records_transferred: 100,
          records_created: 95,
          records_skipped: 5
        })

      assert Ecto.Changeset.get_change(changeset, :status) == "completed"
      assert Ecto.Changeset.get_change(changeset, :completed_at) != nil
    end
  end

  describe "fail_changeset/2" do
    test "sets failed status with error message" do
      transfer = %Transfer{status: "in_progress"}
      changeset = Transfer.fail_changeset(transfer, "Connection timeout")
      assert Ecto.Changeset.get_change(changeset, :status) == "failed"
      assert Ecto.Changeset.get_change(changeset, :error_message) == "Connection timeout"
      assert Ecto.Changeset.get_change(changeset, :completed_at) != nil
    end
  end

  describe "cancel_changeset/1" do
    test "sets cancelled status" do
      transfer = %Transfer{status: "in_progress"}
      changeset = Transfer.cancel_changeset(transfer)
      assert Ecto.Changeset.get_change(changeset, :status) == "cancelled"
      assert Ecto.Changeset.get_change(changeset, :completed_at) != nil
    end
  end

  describe "request_approval_changeset/2" do
    test "sets pending_approval with expiry" do
      transfer = %Transfer{status: "pending"}
      changeset = Transfer.request_approval_changeset(transfer)
      assert Ecto.Changeset.get_change(changeset, :status) == "pending_approval"
      assert Ecto.Changeset.get_change(changeset, :requires_approval) == true
      expires_at = Ecto.Changeset.get_change(changeset, :approval_expires_at)
      assert expires_at != nil
      # Should be ~24 hours from now
      diff = DateTime.diff(expires_at, DateTime.utc_now(), :second)
      assert diff > 23 * 3600 and diff <= 24 * 3600
    end

    test "accepts custom expiry hours" do
      transfer = %Transfer{status: "pending"}
      changeset = Transfer.request_approval_changeset(transfer, 48)
      expires_at = Ecto.Changeset.get_change(changeset, :approval_expires_at)
      diff = DateTime.diff(expires_at, DateTime.utc_now(), :second)
      assert diff > 47 * 3600 and diff <= 48 * 3600
    end
  end

  describe "approve_changeset/2" do
    test "sets approved status" do
      transfer = %Transfer{status: "pending_approval"}
      changeset = Transfer.approve_changeset(transfer, "admin-uuid")
      assert Ecto.Changeset.get_change(changeset, :status) == "approved"
      assert Ecto.Changeset.get_change(changeset, :approved_by_uuid) == "admin-uuid"
      assert Ecto.Changeset.get_change(changeset, :approved_at) != nil
    end
  end

  describe "deny_changeset/3" do
    test "sets denied status with reason" do
      transfer = %Transfer{status: "pending_approval"}
      changeset = Transfer.deny_changeset(transfer, "admin-uuid", "Not authorized")
      assert Ecto.Changeset.get_change(changeset, :status) == "denied"
      assert Ecto.Changeset.get_change(changeset, :denied_by_uuid) == "admin-uuid"
      assert Ecto.Changeset.get_change(changeset, :denial_reason) == "Not authorized"
    end
  end

  # ===========================================
  # STATUS QUERY HELPERS
  # ===========================================

  describe "pending_approval?/1" do
    test "true for pending_approval status" do
      assert Transfer.pending_approval?(%Transfer{status: "pending_approval"})
    end

    test "false for other statuses" do
      refute Transfer.pending_approval?(%Transfer{status: "pending"})
      refute Transfer.pending_approval?(%Transfer{status: "approved"})
    end
  end

  describe "can_start?/1" do
    test "true for pending without approval required" do
      assert Transfer.can_start?(%Transfer{status: "pending", requires_approval: false})
    end

    test "true for approved transfers" do
      assert Transfer.can_start?(%Transfer{status: "approved"})
    end

    test "false for pending with approval required" do
      refute Transfer.can_start?(%Transfer{status: "pending", requires_approval: true})
    end

    test "false for in_progress" do
      refute Transfer.can_start?(%Transfer{status: "in_progress"})
    end
  end

  describe "terminal?/1" do
    test "true for terminal statuses" do
      for status <- ~w(completed failed cancelled denied expired) do
        assert Transfer.terminal?(%Transfer{status: status}),
               "Expected '#{status}' to be terminal"
      end
    end

    test "false for non-terminal statuses" do
      for status <- ~w(pending pending_approval approved in_progress) do
        refute Transfer.terminal?(%Transfer{status: status}),
               "Expected '#{status}' to not be terminal"
      end
    end
  end

  describe "active?/1" do
    test "true only for in_progress" do
      assert Transfer.active?(%Transfer{status: "in_progress"})
    end

    test "false for other statuses" do
      refute Transfer.active?(%Transfer{status: "pending"})
      refute Transfer.active?(%Transfer{status: "completed"})
    end
  end

  # ===========================================
  # COMPUTED FIELDS
  # ===========================================

  describe "success_rate/1" do
    test "returns 0.0 when no records transferred" do
      assert Transfer.success_rate(%Transfer{records_transferred: 0}) == 0.0
    end

    test "calculates rate from created + updated / transferred" do
      transfer = %Transfer{
        records_created: 80,
        records_updated: 10,
        records_transferred: 100
      }

      assert Transfer.success_rate(transfer) == 0.9
    end
  end

  describe "duration_seconds/1" do
    test "returns nil when not started" do
      assert Transfer.duration_seconds(%Transfer{started_at: nil}) == nil
    end

    test "returns nil when not completed" do
      assert Transfer.duration_seconds(%Transfer{
               started_at: DateTime.utc_now(),
               completed_at: nil
             }) == nil
    end

    test "calculates duration" do
      started = ~U[2026-01-01 12:00:00Z]
      completed = ~U[2026-01-01 12:05:30Z]

      transfer = %Transfer{started_at: started, completed_at: completed}
      assert Transfer.duration_seconds(transfer) == 330
    end
  end

  # ===========================================
  # APPROVAL_EXPIRED? TESTS
  # ===========================================

  describe "approval_expired?/1" do
    test "returns false when approval_expires_at is nil" do
      refute Transfer.approval_expired?(%Transfer{approval_expires_at: nil})
    end

    test "returns true when past expiration" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      assert Transfer.approval_expired?(%Transfer{approval_expires_at: past})
    end

    test "returns false when before expiration" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second)
      refute Transfer.approval_expired?(%Transfer{approval_expires_at: future})
    end
  end

  # ===========================================
  # SUCCESS_RATE EDGE CASES
  # ===========================================

  describe "success_rate/1 edge cases" do
    test "when created + updated > transferred (data anomaly)" do
      transfer = %Transfer{
        records_created: 60,
        records_updated: 50,
        records_transferred: 100
      }

      # (60 + 50) / 100 = 1.1 — the function doesn't clamp
      assert Transfer.success_rate(transfer) == 1.1
    end

    test "when only created, no updated" do
      transfer = %Transfer{
        records_created: 75,
        records_updated: 0,
        records_transferred: 100
      }

      assert Transfer.success_rate(transfer) == 0.75
    end

    test "when only updated, no created" do
      transfer = %Transfer{
        records_created: 0,
        records_updated: 30,
        records_transferred: 100
      }

      assert Transfer.success_rate(transfer) == 0.3
    end

    test "returns 0.0 when records_transferred is nil (defaults to 0)" do
      transfer = %Transfer{records_transferred: 0, records_created: 0, records_updated: 0}
      assert Transfer.success_rate(transfer) == 0.0
    end
  end

  # ===========================================
  # PROGRESS_CHANGESET PARTIAL UPDATES
  # ===========================================

  describe "progress_changeset/2 partial updates" do
    test "updating only records_transferred leaves other fields unchanged" do
      transfer = %Transfer{
        status: "in_progress",
        records_transferred: 10,
        records_created: 8,
        records_updated: 2,
        records_skipped: 0,
        records_failed: 0,
        bytes_transferred: 5000
      }

      changeset = Transfer.progress_changeset(transfer, %{records_transferred: 50})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :records_transferred) == 50
      # Other fields should not have changes
      assert Ecto.Changeset.get_change(changeset, :records_created) == nil
      assert Ecto.Changeset.get_change(changeset, :records_updated) == nil
      assert Ecto.Changeset.get_change(changeset, :records_skipped) == nil
      assert Ecto.Changeset.get_change(changeset, :records_failed) == nil
      assert Ecto.Changeset.get_change(changeset, :bytes_transferred) == nil
    end

    test "updating only bytes_transferred" do
      transfer = %Transfer{status: "in_progress", bytes_transferred: 0}
      changeset = Transfer.progress_changeset(transfer, %{bytes_transferred: 100_000})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :bytes_transferred) == 100_000
      assert Ecto.Changeset.get_change(changeset, :records_transferred) == nil
    end

    test "updating multiple fields at once" do
      transfer = %Transfer{status: "in_progress"}

      changeset =
        Transfer.progress_changeset(transfer, %{
          records_created: 10,
          records_failed: 2
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :records_created) == 10
      assert Ecto.Changeset.get_change(changeset, :records_failed) == 2
    end
  end
end
