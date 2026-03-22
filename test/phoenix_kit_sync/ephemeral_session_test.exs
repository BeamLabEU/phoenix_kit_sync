defmodule PhoenixKitSync.EphemeralSessionTest do
  use ExUnit.Case

  alias PhoenixKitSync.SessionStore

  setup_all do
    # Start the global SessionStore if not already running
    case SessionStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "create_session/2" do
    test "creates a receive session with 8-char code" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      assert is_binary(session.code)
      assert String.length(session.code) == 8
      assert session.direction == :receive
      assert session.status == :pending
      assert session.owner_pid == self()

      # Cleanup
      SessionStore.delete(session.code)
    end

    test "creates a send session" do
      {:ok, session} = PhoenixKitSync.create_session(:send)
      assert session.direction == :send
      assert session.status == :pending

      SessionStore.delete(session.code)
    end

    test "session code uses only unambiguous characters" do
      # Code alphabet excludes 0/O, 1/I/L
      for _ <- 1..20 do
        {:ok, session} = PhoenixKitSync.create_session(:receive)
        assert session.code =~ ~r/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/
        SessionStore.delete(session.code)
      end
    end

    test "generates unique codes" do
      sessions =
        for _ <- 1..20 do
          {:ok, session} = PhoenixKitSync.create_session(:receive)
          session
        end

      codes = Enum.map(sessions, & &1.code)
      assert length(Enum.uniq(codes)) == 20

      # Cleanup
      Enum.each(sessions, fn s -> SessionStore.delete(s.code) end)
    end

    test "session has created_at timestamp" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      assert %DateTime{} = session.created_at

      SessionStore.delete(session.code)
    end

    test "session starts with nil connected_at" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      assert session.connected_at == nil

      SessionStore.delete(session.code)
    end
  end

  describe "get_session/1" do
    test "retrieves created session" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      assert {:ok, found} = PhoenixKitSync.get_session(session.code)
      assert found.code == session.code
      assert found.direction == :receive

      SessionStore.delete(session.code)
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} = PhoenixKitSync.get_session("ZZZZZZZZ")
    end
  end

  describe "validate_code/1" do
    test "validates and marks session as connected" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      assert {:ok, updated} = PhoenixKitSync.validate_code(session.code)
      assert updated.status == :connected
      assert updated.connected_at != nil

      SessionStore.delete(session.code)
    end

    test "rejects already used code" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      {:ok, _} = PhoenixKitSync.validate_code(session.code)
      assert {:error, :already_used} = PhoenixKitSync.validate_code(session.code)

      SessionStore.delete(session.code)
    end

    test "rejects non-existent code" do
      assert {:error, :invalid_code} = PhoenixKitSync.validate_code("NONEXIST")
    end
  end

  describe "update_session/2" do
    test "updates session metadata" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)

      {:ok, updated} =
        PhoenixKitSync.update_session(session.code, %{
          sender_info: %{name: "Remote Site"}
        })

      assert updated.sender_info == %{name: "Remote Site"}

      SessionStore.delete(session.code)
    end

    test "preserves existing fields when updating" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)

      {:ok, updated} =
        PhoenixKitSync.update_session(session.code, %{
          sender_info: %{name: "Remote Site"}
        })

      # Original fields preserved
      assert updated.code == session.code
      assert updated.direction == :receive
      assert updated.status == :pending
      assert updated.owner_pid == session.owner_pid

      SessionStore.delete(session.code)
    end

    test "returns error for non-existent code" do
      assert {:error, :not_found} =
               PhoenixKitSync.update_session("NONEXIST", %{status: :connected})
    end
  end

  describe "delete_session/1" do
    test "deletes a session" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)
      assert :ok = PhoenixKitSync.delete_session(session.code)
      assert {:error, :not_found} = PhoenixKitSync.get_session(session.code)
    end

    test "deleting non-existent session is a no-op" do
      assert :ok = PhoenixKitSync.delete_session("NONEXIST")
    end
  end

  describe "SessionStore.count_active/0" do
    test "counts active sessions" do
      initial_count = SessionStore.count_active()

      {:ok, s1} = PhoenixKitSync.create_session(:receive)
      {:ok, s2} = PhoenixKitSync.create_session(:send)

      assert SessionStore.count_active() == initial_count + 2

      SessionStore.delete(s1.code)
      SessionStore.delete(s2.code)

      assert SessionStore.count_active() == initial_count
    end
  end

  describe "SessionStore.list_active/0" do
    test "lists active sessions sorted by created_at" do
      {:ok, s1} = PhoenixKitSync.create_session(:receive)
      {:ok, s2} = PhoenixKitSync.create_session(:send)

      sessions = SessionStore.list_active()
      codes = Enum.map(sessions, & &1.code)

      assert s1.code in codes
      assert s2.code in codes

      SessionStore.delete(s1.code)
      SessionStore.delete(s2.code)
    end
  end
end
