defmodule PhoenixKitSync.Integration.LogRedactionTest do
  use PhoenixKitSync.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitSync.Connections

  # Pinning tests for the "sensitive data in logs" failure mode
  # (memory: feedback_test_coverage_blind_spots.md). Every log site
  # that touches user-controlled params must redact sensitive fields
  # — auth_token, auth_token_hash, download_password, raw passwords —
  # before the value reaches Logger output.
  #
  # The assertion shape: drive the action that logs, capture the log
  # output, and assert the captured output does NOT contain the
  # sensitive value verbatim. These tests fail loudly the moment
  # someone writes `Logger.info("...#{inspect(params)}")` over a
  # params map that includes a token hash.

  defp create_active_sender do
    {:ok, conn, token} =
      Connections.create_connection(%{
        "name" => "Log Redaction #{System.unique_integer([:positive])}",
        "direction" => "sender",
        "site_url" => "https://logleak-#{System.unique_integer([:positive])}.example.com",
        "approval_mode" => "auto_approve"
      })

    {:ok, active} = Connections.approve_connection(conn, PhoenixKitSync.TestActor.uuid())
    {active, token}
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  setup do
    PhoenixKitSync.enable_system()
    PhoenixKitSync.set_incoming_password(nil)
    :ok
  end

  describe "POST /sync/api/get-connection-status — auth_token_hash redaction" do
    # Pre-fix this action did `Logger.info("...with params: #{inspect(params)}")`
    # which serialised the entire params map including auth_token_hash.
    # Post-fix it logs only `receiver_url` + a `has_token_hash` boolean.
    test "log output never contains the auth_token_hash", %{conn: conn} do
      {connection, token} = create_active_sender()
      hash = token_hash(token)

      log =
        capture_log([level: :info], fn ->
          post(conn, "/sync/api/get-connection-status", %{
            "receiver_url" => "https://wherever.example.com",
            "auth_token_hash" => hash
          })
        end)

      refute log =~ hash,
             "expected the auth_token_hash to be redacted from the log; got: #{inspect(log)}"

      _ = connection
    end

    test "log output never contains the raw auth_token either", %{conn: conn} do
      {_connection, token} = create_active_sender()

      log =
        capture_log([level: :info], fn ->
          post(conn, "/sync/api/get-connection-status", %{
            "receiver_url" => "https://wherever.example.com",
            "auth_token_hash" => token_hash(token)
          })
        end)

      refute log =~ token,
             "expected the raw auth token to never appear in logs; got: #{inspect(log)}"
    end

    # Pre-fix the :not_found branch logged the full hash:
    #   "...connection not found for hash: #{params[\"auth_token_hash\"]}"
    # Post-fix logs only `has_token_hash=true|false`.
    test "not-found branch never echoes the auth_token_hash", %{conn: conn} do
      bogus_hash = String.duplicate("d", 64)

      log =
        capture_log([level: :warning], fn ->
          post(conn, "/sync/api/get-connection-status", %{
            "receiver_url" => "https://nobody.example.com",
            "auth_token_hash" => bogus_hash
          })
        end)

      refute log =~ bogus_hash,
             "expected the auth_token_hash to be redacted from the not-found log; got: #{inspect(log)}"
    end
  end

  describe "POST /sync/api/register-connection — password redaction" do
    test "wrong-password rejection log doesn't echo the wrong password", %{conn: conn} do
      PhoenixKitSync.set_incoming_mode("require_password")
      PhoenixKitSync.set_incoming_password("the-real-secret")

      wrong_password = "guessed-password-123"

      log =
        capture_log([level: :info], fn ->
          post(conn, "/sync/api/register-connection", %{
            "sender_url" =>
              "https://logleak-pwd-#{System.unique_integer([:positive])}.example.com",
            "connection_name" => "PwdLogTest",
            "auth_token" => "tok-#{System.unique_integer([:positive])}",
            "password" => wrong_password
          })
        end)

      refute log =~ wrong_password,
             "expected the rejected password to be redacted from logs; got: #{inspect(log)}"

      refute log =~ "the-real-secret",
             "expected the stored password to never appear in logs; got: #{inspect(log)}"

      PhoenixKitSync.set_incoming_mode("auto_accept")
      PhoenixKitSync.set_incoming_password(nil)
    end

    test "register log never echoes the raw auth_token", %{conn: conn} do
      raw_token = "raw-token-#{System.unique_integer([:positive])}"

      log =
        capture_log([level: :info], fn ->
          post(conn, "/sync/api/register-connection", %{
            "sender_url" =>
              "https://logleak-tok-#{System.unique_integer([:positive])}.example.com",
            "connection_name" => "TokLogTest",
            "auth_token" => raw_token
          })
        end)

      refute log =~ raw_token,
             "expected the raw auth_token to never appear in logs; got: #{inspect(log)}"
    end
  end
end
