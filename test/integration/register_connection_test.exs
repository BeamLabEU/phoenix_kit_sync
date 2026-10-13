defmodule PhoenixKitSync.Integration.RegisterConnectionTest do
  use PhoenixKitSync.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitSync.Connection
  alias PhoenixKitSync.Connections
  alias PhoenixKitSync.Test.Repo, as: TestRepo

  # One sender site is one receiver connection, however its URL is spelled,
  # and registrations waiting for approval stop at the cap, however many
  # arrive at once.

  describe "Connection.normalize_site_url/1" do
    # {spelling, its normal form}
    @spellings [
      {"https://example.com", "https://example.com"},
      {"https://example.com/", "https://example.com"},
      {"https://Example.com", "https://example.com"},
      {"HTTPS://EXAMPLE.COM/", "https://example.com"},
      {"https://example.com:443", "https://example.com"},
      {"https://example.com:443/", "https://example.com"},
      {"https://example.com.", "https://example.com"},
      {"  https://example.com/  ", "https://example.com"},
      {"https://example.com#top", "https://example.com"},
      # another port, scheme, host or path is another site
      {"https://example.com:8443/", "https://example.com:8443"},
      {"http://example.com", "http://example.com"},
      {"http://example.com:80/", "http://example.com"},
      {"http://example.com:443", "http://example.com:443"},
      {"https://www.example.com", "https://www.example.com"},
      {"https://example.com/shop/", "https://example.com/shop"},
      {"https://example.com/Shop", "https://example.com/Shop"},
      {"https://example.com/shop//", "https://example.com/shop"},
      {"https://example.com/?a=B", "https://example.com?a=B"},
      {"https://[::1]:4000/", "https://[::1]:4000"},
      {"https://[2001:DB8::1]/", "https://[2001:db8::1]"},
      # not a URL: returned trimmed, never raised on
      {"example.com", "example.com"},
      {" not a url ", "not a url"},
      {"", ""}
    ]

    for {{spelling, normal}, index} <- Enum.with_index(@spellings) do
      test "#{inspect(spelling)} is #{inspect(normal)} (case #{index})" do
        assert Connection.normalize_site_url(unquote(spelling)) == unquote(normal)
      end
    end

    test "the normal form is its own normal form" do
      for {_spelling, normal} <- @spellings do
        assert Connection.normalize_site_url(normal) == normal
      end
    end
  end

  describe "one site, many spellings" do
    setup do
      PhoenixKitSync.enable_system()
      PhoenixKitSync.set_incoming_password(nil)
      :ok
    end

    defp register(sender_url) do
      post(build_conn(), "/sync/api/register-connection", %{
        "sender_url" => sender_url,
        "connection_name" => "Spelled",
        "auth_token" => "tok-#{System.unique_integer([:positive])}"
      })
    end

    defp receiver_rows(host) do
      PhoenixKit.RepoHelper.repo().all(
        from(c in Connection,
          where: c.direction == "receiver" and ilike(c.site_url, ^"%#{host}%"),
          select: c.site_url
        )
      )
    end

    @same_site [
      "https://Spelled.Example.com",
      "https://spelled.example.com/",
      "HTTPS://SPELLED.EXAMPLE.COM",
      "https://spelled.example.com:443",
      "https://spelled.example.com."
    ]

    for {first, index} <- Enum.with_index(@same_site) do
      test "a site registered as #{first} is already there under every other spelling (case #{index})" do
        assert %{"success" => true} = unquote(first) |> register() |> json_response(200)

        for other <- @same_site do
          assert %{"success" => false} = other |> register() |> json_response(409)
        end

        # Stored as it was given, once.
        assert receiver_rows("spelled.example.com") == [unquote(first)]
      end
    end

    test "another port, scheme or path is another site" do
      for url <- [
            "https://spelled.example.com",
            "http://spelled.example.com",
            "https://spelled.example.com:8443",
            "https://spelled.example.com/shop",
            "https://sub.spelled.example.com"
          ] do
        assert %{"success" => true} = url |> register() |> json_response(200)
      end

      assert length(receiver_rows("spelled.example.com")) == 5
    end

    test "a host that is part of another's name is not that site" do
      assert %{"success" => true} =
               "https://notspelled.example.com" |> register() |> json_response(200)

      assert %{"success" => true} =
               "https://spelled.example.com" |> register() |> json_response(200)
    end

    test "a LIKE wildcard in the host matches only itself" do
      assert %{"success" => true} = "https://a-b.example.com" |> register() |> json_response(200)
      assert Connections.find_by_site_url("https://a_b.example.com", "receiver") == nil
      assert Connections.find_by_site_url("https://a%b.example.com", "receiver") == nil
    end
  end

  describe "lookups of rows stored under any spelling" do
    # Rows from before the comparison was normalised hold whatever was
    # sent; the sender's later requests must still find them.
    defp stored!(site_url, direction \\ "receiver") do
      {:ok, connection, token} =
        Connections.create_connection(%{
          "name" => "Stored #{System.unique_integer([:positive])}",
          "direction" => direction,
          "site_url" => site_url,
          "status" => "active"
        })

      {connection, :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
    end

    @stored_and_asked [
      {"https://Old.Example.com/", "https://old.example.com"},
      {"https://old.example.com", "https://OLD.example.com/"},
      {"https://old.example.com:443", "https://old.example.com"},
      {"https://old.example.com", "https://old.example.com"}
    ]

    for {{stored, asked}, index} <- Enum.with_index(@stored_and_asked) do
      test "stored #{stored}, asked #{asked} (case #{index})" do
        {connection, hash} = stored!(unquote(stored))

        assert Connections.find_by_site_url(unquote(asked), "receiver").uuid == connection.uuid
        assert Connections.find_by_site_url(unquote(asked), "sender") == nil

        assert Connections.find_by_site_url_and_hash(unquote(asked), hash).uuid == connection.uuid

        assert Connections.find_by_site_url_and_hash(unquote(asked), hash, "receiver").uuid ==
                 connection.uuid

        assert Connections.find_by_site_url_and_hash(unquote(asked), hash, "sender") == nil
        assert Connections.find_by_site_url_and_hash(unquote(asked), "0" <> hash) == nil
      end
    end

    test "of two stored spellings of one site, the one asked for wins, then the older" do
      {slash, _hash} = stored!("https://twice.example.com/")
      {plain, _hash} = stored!("https://twice.example.com")

      # Written in the same second, the two have no order of their own.
      PhoenixKit.RepoHelper.repo().query!(
        "UPDATE phoenix_kit_sync_connections SET inserted_at = inserted_at - interval '1 hour' " <>
          "WHERE uuid = $1::text::uuid",
        [slash.uuid]
      )

      assert Connections.find_by_site_url("https://twice.example.com", "receiver").uuid ==
               plain.uuid

      assert Connections.find_by_site_url("https://twice.example.com/", "receiver").uuid ==
               slash.uuid

      assert Connections.find_by_site_url("https://TWICE.example.com", "receiver").uuid ==
               slash.uuid
    end

    test "a status report under another spelling reaches the receiver row", %{conn: conn} do
      PhoenixKitSync.enable_system()
      {connection, hash} = stored!("https://Reported.Example.com/")

      assert %{"success" => true} =
               conn
               |> post("/sync/api/update-status", %{
                 "sender_url" => "https://reported.example.com",
                 "auth_token_hash" => hash,
                 "status" => "suspended"
               })
               |> json_response(200)

      assert Connections.get_connection!(connection.uuid).status == "suspended"
    end
  end

  describe "the pending cap" do
    setup do
      PhoenixKitSync.enable_system()
      PhoenixKitSync.set_incoming_password(nil)
      Application.put_env(:phoenix_kit_sync, :max_pending_incoming, 2)
      on_exit(fn -> Application.delete_env(:phoenix_kit_sync, :max_pending_incoming) end)
      :ok
    end

    test "holds for registrations one after another" do
      urls =
        for n <- 1..4, do: "https://capped-#{n}-#{System.unique_integer([:positive])}.example.com"

      assert Enum.map(urls, &register(&1).status) == [200, 200, 429, 429]
    end
  end

  describe "registrations arriving together" do
    # A race needs connections that do not share a transaction, so these
    # run outside the sandbox and remove what they wrote.
    @marker "race-#{System.unique_integer([:positive])}"

    setup do
      on_exit(fn ->
        Sandbox.unboxed_run(TestRepo, fn ->
          TestRepo.query!(
            "DELETE FROM phoenix_kit_activities WHERE resource_uuid IN " <>
              "(SELECT uuid FROM phoenix_kit_sync_connections WHERE site_url ILIKE $1)",
            ["%#{@marker}%"]
          )

          TestRepo.query!("DELETE FROM phoenix_kit_sync_connections WHERE site_url ILIKE $1", [
            "%#{@marker}%"
          ])
        end)
      end)

      :ok
    end

    defp attrs(site_url) do
      %{
        "name" => "Racer",
        "direction" => "receiver",
        "site_url" => site_url,
        "auth_token" => "tok-#{System.unique_integer([:positive])}",
        "status" => "pending"
      }
    end

    defp race(site_urls, opts) do
      site_urls
      |> Enum.map(&Task.async(fn -> register_unboxed(&1, opts) end))
      |> Task.await_many(30_000)
    end

    defp register_unboxed(site_url, opts) do
      Sandbox.unboxed_run(TestRepo, fn ->
        Connections.register_incoming(attrs(site_url), opts)
      end)
    end

    defp committed(pattern) do
      Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query!(
          "SELECT count(*) FROM phoenix_kit_sync_connections WHERE site_url ILIKE $1",
          [pattern]
        ).rows
        |> hd()
        |> hd()
      end)
    end

    test "twelve at once for twelve sites stop at the cap" do
      # The cap counts every pending receiver row; none is committed outside
      # this test.
      assert committed("%") == 0

      urls = for n <- 1..12, do: "https://#{@marker}-cap-#{n}.example.com"
      results = race(urls, max_pending: 3)

      assert Enum.count(results, &match?({:ok, %Connection{}}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :too_many_pending})) == 9
      assert committed("%#{@marker}-cap-%") == 3
    end

    test "twelve at once for one site, spelled six ways, make one row" do
      spellings =
        for _round <- 1..2,
            url <- [
              "https://#{@marker}-one.example.com",
              "https://#{@marker}-one.example.com/",
              "HTTPS://#{String.upcase(@marker)}-ONE.EXAMPLE.COM",
              "https://#{@marker}-one.example.com:443",
              "https://#{@marker}-one.example.com.",
              "https://#{@marker}-One.Example.com/"
            ],
            do: url

      results = race(spellings, max_pending: 50)

      assert Enum.count(results, &match?({:ok, %Connection{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :connection_exists})) == 11
      assert committed("%#{@marker}-one%") == 1
    end
  end
end
