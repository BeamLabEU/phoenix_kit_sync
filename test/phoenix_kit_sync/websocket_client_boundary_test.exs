defmodule PhoenixKitSync.WebSocketClientBoundaryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias PhoenixKitSync.WebSocketClient

  defp state(request) do
    %WebSocketClient{
      caller: self(),
      code: "PRIVATE_CODE",
      joined: true,
      pending_refs: %{"1" => request}
    }
  end

  defp frame(event, payload) do
    {:text,
     Jason.encode!([nil, nil, "transfer:PRIVATE_CODE", event, Map.put(payload, "ref", "1")])}
  end

  for url <- [
        "example.com",
        "ftp://example.com",
        "https:///path",
        "https://user:password@example.com"
      ] do
    test "refuses #{url} before constructing a credential-bearing socket URL" do
      assert {:error, :invalid_sender_url} =
               WebSocketClient.start_link(
                 url: unquote(url),
                 code: "PRIVATE_CODE",
                 caller: self()
               )
    end
  end

  for tables <- [42, [%{"name" => "a"}, 3], [%{"name" => %{}}]] do
    test "malformed table list #{inspect(tables)} fails its request" do
      assert {:ok, %{pending_refs: %{}}} =
               WebSocketClient.handle_frame(
                 frame("response:tables", %{"tables" => unquote(Macro.escape(tables))}),
                 state(:tables)
               )

      assert_received {:sync_client, {:request_error, :tables, :invalid_response}}
    end
  end

  for schema <- [
        42,
        %{"columns" => [%{"name" => "id", "type" => %{}}]},
        %{"columns" => [42]},
        %{"columns" => [], "primary_key" => %{}}
      ] do
    test "malformed schema #{inspect(schema)} fails its request" do
      assert {:ok, %{pending_refs: %{}}} =
               WebSocketClient.handle_frame(
                 frame("response:schema", %{"schema" => unquote(Macro.escape(schema))}),
                 state({:schema, "rows"})
               )

      assert_received {:sync_client, {:request_error, {:schema, "rows"}, :invalid_response}}
    end
  end

  test "a non-text peer error cannot crash its consumer" do
    assert {:ok, _} =
             WebSocketClient.handle_frame(
               frame("response:error", %{"error" => %{"message" => "private value"}}),
               state({:records, "rows"})
             )

    assert_received {:sync_client, {:request_error, {:records, "rows"}, :invalid_response}}
  end

  test "malformed JSON and peer error payloads are absent from logs" do
    secret = "private-record-and-credential-value"

    log =
      capture_log(fn ->
        WebSocketClient.handle_frame({:text, "{#{secret}"}, state(:tables))

        WebSocketClient.handle_frame(
          frame("response:error", %{"error" => secret}),
          state(:tables)
        )

        WebSocketClient.handle_frame(frame("phx_error", %{"secret" => secret}), state(:tables))
      end)

    refute log =~ secret
    refute log =~ "PRIVATE_CODE"
  end
end
