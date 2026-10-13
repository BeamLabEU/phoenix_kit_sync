defmodule PhoenixKitSync.Integration.AuditTrailTest do
  use PhoenixKitSync.DataCase, async: false

  import PhoenixKitSync.ActivityLogAssertions

  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.SchemaInspector
  alias PhoenixKitSync.Transfers

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp activities(action) do
    %{rows: rows} =
      repo().query!(
        "SELECT actor_uuid, resource_uuid, metadata, mode FROM phoenix_kit_activities WHERE action = $1",
        [action]
      )

    Enum.map(rows, fn [actor, resource, metadata, mode] ->
      %{
        actor_uuid: actor && Ecto.UUID.load!(actor),
        resource_uuid: resource && Ecto.UUID.load!(resource),
        metadata: metadata,
        mode: mode
      }
    end)
  end

  @schema %{
    "columns" => [
      %{"name" => "id", "type" => "bigint", "nullable" => false, "primary_key" => true},
      %{"name" => "label", "type" => "text", "nullable" => true}
    ],
    "primary_key" => ["id"]
  }

  describe "SchemaInspector.create_table/3" do
    test "logs the table it created, with the admin who asked for it" do
      actor = PhoenixKitSync.TestActor.uuid()

      assert :ok = SchemaInspector.create_table("at_created", @schema, actor_uuid: actor)

      assert [%{actor_uuid: ^actor, mode: "manual", metadata: metadata}] =
               activities("sync.table.created")

      assert %{"table_name" => "at_created", "columns" => 2} = metadata
      refute Map.has_key?(metadata, "db_pending")
    end

    test "logs a creation nobody asked for as automatic" do
      assert :ok = SchemaInspector.create_table("at_auto", @schema)

      assert [%{actor_uuid: nil, mode: "auto", metadata: %{"table_name" => "at_auto"}}] =
               activities("sync.table.created")
    end

    test "logs the attempt when the DDL fails" do
      assert :ok = SchemaInspector.create_table("at_twice", @schema)
      assert {:error, _reason} = SchemaInspector.create_table("at_twice", @schema)

      assert [_created, %{metadata: %{"table_name" => "at_twice", "db_pending" => true}}] =
               Enum.sort_by(
                 activities("sync.table.created"),
                 &Map.has_key?(&1.metadata, "db_pending")
               )
    end

    test "logs nothing for a schema it refuses before any DDL" do
      assert {:error, :invalid_table_name} = SchemaInspector.create_table("bad name", @schema)
      assert activities("sync.table.created") == []
    end
  end

  describe "Transfers" do
    test "a transfer that could not be written is still logged, as pending" do
      actor = PhoenixKitSync.TestActor.uuid()

      assert {:error, %Ecto.Changeset{}} =
               Transfers.create_transfer(
                 %{direction: "receive", table_name: "users", conflict_strategy: "bogus"},
                 actor_uuid: actor
               )

      assert [%{actor_uuid: ^actor, resource_uuid: nil, metadata: metadata}] =
               activities("sync.transfer.created")

      assert %{"table_name" => "users", "direction" => "receive", "db_pending" => true} = metadata
    end

    test "record_finished/3 writes the final state in one row and one activity" do
      assert {:ok, transfer} =
               Transfers.record_finished(
                 %{direction: "send", table_name: "users", records_transferred: 7},
                 {:failed, :sent_truncated}
               )

      assert %{status: "failed", error_message: "sent_truncated", records_transferred: 7} =
               transfer

      assert transfer.started_at
      assert transfer.completed_at
      assert_activity_logged("sync.transfer.failed", resource_uuid: transfer.uuid)
      assert activities("sync.transfer.created") == []

      assert {:error, %Ecto.Changeset{}} =
               Transfers.record_finished(%{direction: "send"}, :completed)

      assert [%{metadata: %{"db_pending" => true}}] = activities("sync.transfer.completed")
    end
  end

  describe "connection status changes" do
    setup do
      {:ok, connection, _token} =
        Connections.create_connection(%{
          "name" => "Audit #{System.unique_integer([:positive])}",
          "direction" => "sender",
          "site_url" => "https://audit-#{System.unique_integer([:positive])}.example.com"
        })

      {:ok, connection: connection, actor: PhoenixKitSync.TestActor.uuid()}
    end

    test "approve, suspend and revoke take the actor and the reason as options", %{
      connection: connection,
      actor: actor
    } do
      assert {:ok, approved} = Connections.approve_connection(connection, actor_uuid: actor)
      assert approved.approved_by_uuid == actor

      assert {:ok, suspended} =
               Connections.suspend_connection(approved, actor_uuid: actor, reason: "audit")

      assert %{suspended_by_uuid: ^actor, suspended_reason: "audit"} = suspended

      assert {:ok, revoked} =
               Connections.revoke_connection(suspended, actor_uuid: actor, reason: "leaked")

      assert %{revoked_by_uuid: ^actor, revoked_reason: "leaked"} = revoked

      for {verb, extra} <- [
            {"approved", %{}},
            {"suspended", %{"reason" => "audit"}},
            {"revoked", %{"reason" => "leaked"}}
          ] do
        assert_activity_logged("sync.connection.#{verb}",
          resource_uuid: connection.uuid,
          actor_uuid: actor,
          metadata_has: extra
        )
      end
    end

    test "the actor as a bare argument still works", %{connection: connection, actor: actor} do
      assert {:ok, approved} = Connections.approve_connection(connection, actor)
      assert approved.approved_by_uuid == actor

      assert {:ok, %{suspended_reason: "why"} = suspended} =
               Connections.suspend_connection(approved, actor, "why")

      assert {:ok, %{revoked_reason: "gone", revoked_by_uuid: ^actor}} =
               Connections.revoke_connection(suspended, actor, "gone")
    end
  end
end
