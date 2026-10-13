defmodule PhoenixKitSync.Integration.ReleaseReviewRegressionsTest do
  use PhoenixKitSync.DataCase, async: false

  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.DataImporter
  alias PhoenixKitSync.Test.Repo

  defp connection(status, direction \\ "receiver") do
    {:ok, connection, _token} =
      Connections.create_connection(%{
        "name" => "Review regression",
        "site_url" => "https://review-#{System.unique_integer([:positive])}.example.com",
        "direction" => direction,
        "status" => status
      })

    connection
  end

  test "a stale active snapshot cannot suspend a locally revoked receiver" do
    active = connection("active")
    assert {:ok, revoked} = Connections.revoke_connection(active, reason: "Compromised")

    assert {:error, :status_change_not_allowed} =
             Connections.apply_remote_status(active, "suspended")

    assert {:error, :status_change_not_allowed} =
             Connections.apply_remote_status(active, "active")

    assert Connections.get_connection!(active.uuid).status == revoked.status
  end

  test "a stale remote suspension cannot lift a newer local suspension" do
    active = connection("active")
    assert {:ok, remote} = Connections.apply_remote_status(active, "suspended")
    assert Connection.remote_suspended?(remote)
    assert {:ok, local} = Connections.suspend_connection(remote, reason: "Admin decision")

    assert {:error, :status_change_not_allowed} =
             Connections.apply_remote_status(remote, "active")

    assert Connections.get_connection!(local.uuid).suspended_reason == "Admin decision"
    refute Connection.remote_suspended?(Connections.get_connection!(local.uuid))
  end

  test "stale admin actions cannot undo a revocation" do
    pending = connection("pending", "sender")
    {:ok, active} = Connections.approve_connection(pending)
    {:ok, suspended} = Connections.suspend_connection(active)
    {:ok, revoked} = Connections.revoke_connection(suspended)

    assert {:error, :status_change_not_allowed} = Connections.approve_connection(pending)
    assert {:error, :status_change_not_allowed} = Connections.suspend_connection(active)
    assert {:error, :status_change_not_allowed} = Connections.reactivate_connection(suspended)
    assert Connections.get_connection!(revoked.uuid).status == "revoked"
  end

  test "a stale settings save cannot reactivate a revoked row" do
    pending = connection("pending", "sender")
    {:ok, revoked} = Connections.revoke_connection(pending)

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Connections.update_connection(pending, %{status: "active"})

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Connections.update_connection(revoked, %{status: "active"})

    assert Connections.get_connection!(revoked.uuid).status == "revoked"
  end

  test "registration writes its activity after the explicit transaction commits" do
    handler_id = "review-registration-#{System.unique_integer([:positive])}"
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :telemetry.attach(
      handler_id,
      event,
      fn _event, _measurements, metadata, caller ->
        if String.starts_with?(metadata.query, "INSERT INTO \"phoenix_kit_activities\"") do
          send(caller, {:activity_transaction, Repo.in_transaction?()})
        end
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _connection} =
             Connections.register_incoming(
               %{
                 "name" => "Registration",
                 "site_url" => "https://registration-review.example.com",
                 "direction" => "receiver",
                 "status" => "pending"
               },
               max_pending: 50
             )

    assert_receive {:activity_transaction, false}
    refute_received {:activity_transaction, true}
  end

  test "form strings matching typed settings produce no update activity" do
    sender = connection("active", "sender")

    before =
      Repo.query!(
        "SELECT count(*) FROM phoenix_kit_activities WHERE resource_uuid = $1",
        [Ecto.UUID.dump!(sender.uuid)]
      ).rows

    assert {:ok, _} =
             Connections.update_connection(sender, %{
               "max_records_per_request" => Integer.to_string(sender.max_records_per_request),
               "auto_sync_enabled" => "false"
             })

    assert Repo.query!(
             "SELECT count(*) FROM phoenix_kit_activities WHERE resource_uuid = $1",
             [Ecto.UUID.dump!(sender.uuid)]
           ).rows == before
  end

  for strategy <- [:skip, :overwrite, :merge] do
    test "a malformed key cannot spoil valid #{strategy} conflicts in a batch" do
      Repo.query!("CREATE TABLE review_batch (id uuid PRIMARY KEY, note text)")
      uuid = UUIDv7.generate()
      Repo.query!("INSERT INTO review_batch VALUES ($1, 'local')", [Ecto.UUID.dump!(uuid)])
      invalid = %{"id" => "not-a-uuid", "note" => "invalid"}
      valid = %{"id" => uuid, "note" => "remote"}

      assert {:ok, result} =
               DataImporter.import_records("review_batch", [invalid, valid], unquote(strategy))

      assert [{_, _}] = result.errors
      assert result.skipped + result.updated == 1
      expected = if unquote(strategy) == :skip, do: "local", else: "remote"
      assert Repo.query!("SELECT note FROM review_batch").rows == [[expected]]
    end

    test "repeated keys see earlier writes under #{strategy}" do
      Repo.query!("CREATE TABLE review_duplicates (id bigint PRIMARY KEY, note text)")
      records = [%{"id" => 1, "note" => "first"}, %{"id" => 1, "note" => "second"}]

      assert {:ok, %{created: 1, errors: []} = result} =
               DataImporter.import_records("review_duplicates", records, unquote(strategy))

      assert result.skipped + result.updated == 1
      expected = if unquote(strategy) == :skip, do: "first", else: "second"
      assert Repo.query!("SELECT note FROM review_duplicates").rows == [[expected]]
    end
  end
end
