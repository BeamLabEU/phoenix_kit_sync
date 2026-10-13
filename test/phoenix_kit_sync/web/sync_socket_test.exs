defmodule PhoenixKitSync.Web.SyncSocketTest do
  use PhoenixKitSync.ChannelCase

  alias PhoenixKitSync.Web.SyncSocket

  setup do
    PhoenixKitSync.enable_system()
    :ok
  end

  describe "connect/3" do
    test "rejects when sync module is disabled" do
      PhoenixKitSync.disable_system()

      assert {:error, :module_disabled} = connect(SyncSocket, %{"code" => "ABCDEFGH"})

      PhoenixKitSync.enable_system()
    end

    test "rejects with :missing_code when no code is provided" do
      assert {:error, :missing_code} = connect(SyncSocket, %{})
    end

    test "rejects with :invalid_code for unknown code" do
      assert {:error, :invalid_code} = connect(SyncSocket, %{"code" => "NOTAREAL"})
    end

    test "refuses the code of a session that does not send" do
      {:ok, session} = PhoenixKitSync.create_session(:receive)

      assert {:error, :invalid_code} = connect(SyncSocket, %{"code" => session.code})
    end

    test "accepts a valid session code and assigns session state" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, socket} = connect(SyncSocket, %{"code" => session.code})

      assert socket.assigns.session_code == session.code
      assert socket.assigns.direction == :sender
    end
  end

  describe "id/1" do
    test "returns sync:<code> for namespacing" do
      {:ok, session} = PhoenixKitSync.create_session(:send)

      {:ok, socket} = connect(SyncSocket, %{"code" => session.code})

      assert SyncSocket.id(socket) == "sync:#{session.code}"
    end
  end
end
