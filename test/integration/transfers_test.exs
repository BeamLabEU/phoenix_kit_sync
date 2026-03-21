defmodule PhoenixKitSync.Integration.TransfersTest do
  use PhoenixKitSync.DataCase, async: true

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Transfers

  defp create_connection do
    {:ok, conn, _token} =
      Connections.create_connection(%{
        "name" => "Transfer Test",
        "direction" => "sender",
        "site_url" => "https://transfer-#{System.unique_integer([:positive])}.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, active} = Connections.approve_connection(conn, UUIDv7.generate())
    active
  end

  defp create_transfer(attrs \\ %{}) do
    conn = create_connection()

    merged =
      Map.merge(
        %{
          "direction" => "receive",
          "table_name" => "users",
          "connection_uuid" => conn.uuid,
          "records_requested" => 100,
          "conflict_strategy" => "skip"
        },
        attrs
      )

    {:ok, transfer} = Transfers.create_transfer(merged)
    {conn, transfer}
  end

  # ===========================================
  # CREATE
  # ===========================================

  describe "create_transfer/1" do
    test "creates a transfer with valid attrs" do
      conn = create_connection()

      assert {:ok, transfer} =
               Transfers.create_transfer(%{
                 "direction" => "receive",
                 "table_name" => "users",
                 "connection_uuid" => conn.uuid,
                 "records_requested" => 100,
                 "conflict_strategy" => "skip"
               })

      assert transfer.direction == "receive"
      assert transfer.table_name == "users"
      assert transfer.status == "pending"
    end

    test "fails without required fields" do
      assert {:error, changeset} = Transfers.create_transfer(%{})
      errors = errors_on(changeset)
      assert errors[:direction] != nil
      assert errors[:table_name] != nil
    end
  end

  # ===========================================
  # STATUS TRANSITIONS
  # ===========================================

  describe "transfer lifecycle" do
    test "full happy path: pending -> in_progress -> completed" do
      {_conn, transfer} = create_transfer()
      assert transfer.status == "pending"

      assert {:ok, started} = Transfers.start_transfer(transfer)
      assert started.status == "in_progress"
      assert started.started_at != nil

      assert {:ok, completed} =
               Transfers.complete_transfer(started, %{
                 records_transferred: 100,
                 records_created: 95,
                 records_skipped: 5
               })

      assert completed.status == "completed"
      assert completed.completed_at != nil
      assert completed.records_created == 95
    end

    test "failure path: pending -> in_progress -> failed" do
      {_conn, transfer} = create_transfer()
      {:ok, started} = Transfers.start_transfer(transfer)

      assert {:ok, failed} = Transfers.fail_transfer(started, "Connection reset")
      assert failed.status == "failed"
      assert failed.error_message == "Connection reset"
    end

    test "cancellation path" do
      {_conn, transfer} = create_transfer()

      assert {:ok, cancelled} = Transfers.cancel_transfer(transfer)
      assert cancelled.status == "cancelled"
    end
  end

  describe "approval workflow" do
    test "pending -> pending_approval -> approved -> in_progress -> completed" do
      {_conn, transfer} = create_transfer()

      assert {:ok, pending} = Transfers.request_approval(transfer)
      assert pending.status == "pending_approval"
      assert pending.requires_approval == true

      assert {:ok, approved} = Transfers.approve_transfer(pending, UUIDv7.generate())
      assert approved.status == "approved"

      assert {:ok, started} = Transfers.start_transfer(approved)
      assert started.status == "in_progress"

      assert {:ok, completed} = Transfers.complete_transfer(started)
      assert completed.status == "completed"
    end

    test "denial path" do
      {_conn, transfer} = create_transfer()
      {:ok, pending} = Transfers.request_approval(transfer)

      assert {:ok, denied} = Transfers.deny_transfer(pending, UUIDv7.generate(), "Not authorized")
      assert denied.status == "denied"
      assert denied.denial_reason == "Not authorized"
    end
  end

  # ===========================================
  # QUERIES
  # ===========================================

  describe "list_transfers/1" do
    test "returns transfers" do
      {_conn, _transfer} = create_transfer()
      transfers = Transfers.list_transfers()
      assert transfers != []
    end

    test "filters by direction" do
      {_conn, _transfer} = create_transfer(%{"direction" => "receive"})
      receives = Transfers.list_transfers(direction: "receive")
      assert Enum.all?(receives, &(&1.direction == "receive"))
    end

    test "filters by status" do
      {_conn, transfer} = create_transfer()
      Transfers.start_transfer(transfer)

      in_progress = Transfers.list_transfers(status: "in_progress")
      assert Enum.all?(in_progress, &(&1.status == "in_progress"))
    end
  end

  describe "connection_stats/1" do
    test "returns stats for a connection" do
      conn = create_connection()

      {:ok, t1} =
        Transfers.create_transfer(%{
          "direction" => "receive",
          "table_name" => "users",
          "connection_uuid" => conn.uuid
        })

      {:ok, started} = Transfers.start_transfer(t1)

      Transfers.complete_transfer(started, %{
        records_transferred: 50,
        bytes_transferred: 10_000
      })

      stats = Transfers.connection_stats(conn.uuid)
      assert is_map(stats)
    end
  end
end
