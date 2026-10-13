defmodule PhoenixKitSync.ConnectionSSRFTest do
  @moduledoc """
  Pins the SSRF guard on `Connection.changeset/2`'s `site_url` field.
  Without these tests an admin could create a sender connection
  pointing at `http://127.0.0.1:6379`, `http://169.254.169.254/...`,
  or `http://internal-admin.local`, and the notifier flow would issue
  the outbound HTTP request to that target.

  All tests run `async: false` and toggle
  `:phoenix_kit_sync, :allow_internal_urls` back to `false` in setup
  (test config defaults it to `true` so the existing localhost
  integration tests work). On exit the original setting is restored.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitSync.Connection

  @valid_attrs %{
    name: "SSRF Test",
    direction: "sender",
    site_url: "https://staging.example.com"
  }

  setup do
    # Tests in this file want the strict default behaviour; the test
    # config flips bypass on for general suite use, so undo it here.
    prior = Application.get_env(:phoenix_kit_sync, :allow_internal_urls)
    Application.put_env(:phoenix_kit_sync, :allow_internal_urls, false)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:phoenix_kit_sync, :allow_internal_urls)
        value -> Application.put_env(:phoenix_kit_sync, :allow_internal_urls, value)
      end
    end)

    :ok
  end

  defp changeset_for(url) do
    Connection.changeset(%Connection{}, %{@valid_attrs | site_url: url})
  end

  defp site_url_error(url) do
    cs = changeset_for(url)
    {message, _opts} = Keyword.fetch!(cs.errors, :site_url)
    message
  end

  describe "scheme rejection" do
    test "rejects file:// scheme" do
      assert site_url_error("file:///etc/passwd") == "must use http or https scheme"
    end

    test "rejects gopher:// scheme" do
      assert site_url_error("gopher://example.com:70/") == "must use http or https scheme"
    end

    test "rejects javascript: scheme" do
      assert site_url_error("javascript:alert(1)") == "must use http or https scheme"
    end

    test "accepts http:// scheme on a public host" do
      assert changeset_for("http://staging.example.com").valid?
    end

    test "accepts https:// scheme on a public host" do
      assert changeset_for("https://staging.example.com").valid?
    end
  end

  describe "missing host" do
    test "rejects scheme-only URL with no host" do
      assert site_url_error("https://") == "must include a hostname"
    end
  end

  describe "RFC1918 / loopback / link-local rejection" do
    test "rejects 10.0.0.0/8 IPv4 literal" do
      assert site_url_error("https://10.20.30.40/api") =~ "private/loopback/link-local"
    end

    test "rejects 172.16.0.0/12 IPv4 literal" do
      assert site_url_error("https://172.16.5.5/api") =~ "private/loopback/link-local"
    end

    test "rejects 192.168.0.0/16 IPv4 literal" do
      assert site_url_error("https://192.168.1.1/api") =~ "private/loopback/link-local"
    end

    test "rejects 127.0.0.0/8 loopback IPv4 literal" do
      assert site_url_error("http://127.0.0.1:6379") =~ "private/loopback/link-local"
    end

    test "rejects 169.254.0.0/16 link-local IPv4 (cloud metadata)" do
      assert site_url_error("http://169.254.169.254/latest/meta-data/") =~
               "private/loopback/link-local"
    end

    test "rejects ::1 IPv6 loopback" do
      assert site_url_error("http://[::1]:80") =~ "private/loopback/link-local"
    end

    test "rejects fe80::/10 IPv6 link-local" do
      assert site_url_error("http://[fe80::1]:80") =~ "private/loopback/link-local"
    end

    test "rejects fc00::/7 IPv6 unique-local" do
      assert site_url_error("http://[fc00::1]:80") =~ "private/loopback/link-local"
    end
  end

  describe "literal localhost / .local rejection" do
    test "rejects http://localhost" do
      assert site_url_error("http://localhost:4000") =~ "cannot point at localhost"
    end

    test "rejects .local mDNS hostnames" do
      assert site_url_error("http://printer.local") =~ ".local mDNS"
    end

    # A hostname compares without case and may end in the root dot; an IP
    # literal has more than one spelling. Each row is a host and whether it
    # may be a connection's site.
    @hosts [
      # localhost in every spelling
      {"localhost", :refused},
      {"LOCALHOST", :refused},
      {"LocalHost", :refused},
      {"localhost.", :refused},
      {"LOCALHOST.", :refused},
      {"app.localhost", :refused},
      {"APP.LOCALHOST.", :refused},
      # mDNS
      {"printer.local", :refused},
      {"PRINTER.LOCAL", :refused},
      {"X.LOCAL", :refused},
      {"printer.local.", :refused},
      {"local", :refused},
      # IPv4 literals
      {"127.0.0.1", :refused},
      {"127.1", :refused},
      {"10.1.2.3", :refused},
      {"192.168.0.1", :refused},
      {"169.254.169.254", :refused},
      {"0.0.0.0", :refused},
      # IPv6 literals, IPv4-mapped included
      {"[::1]", :refused},
      {"[::]", :refused},
      {"[fe80::1]", :refused},
      {"[fd00::1]", :refused},
      {"[::ffff:127.0.0.1]", :refused},
      {"[::ffff:10.0.0.1]", :refused},
      {"[::ffff:169.254.169.254]", :refused},
      {"[::FFFF:192.168.1.1]", :refused},
      {"[::ffff:7f00:1]", :refused},
      # public hosts, including names that merely contain the words
      {"example.com", :allowed},
      {"EXAMPLE.COM.", :allowed},
      {"localhost.example.com", :allowed},
      {"mylocal.example.com", :allowed},
      {"local.example.com", :allowed},
      {"notlocalhost.com", :allowed},
      {"8.8.8.8", :allowed},
      {"[2001:4860:4860::8888]", :allowed},
      {"[::ffff:8.8.8.8]", :allowed}
    ]

    for {host, expected} <- @hosts, scheme <- ["http", "https"], port <- ["", ":4000"] do
      url = "#{scheme}://#{host}#{port}"

      test "#{url} is #{expected}" do
        changeset = changeset_for(unquote(url))

        case unquote(expected) do
          :refused -> assert site_url_error(unquote(url)) =~ "cannot point at"
          :allowed -> assert changeset.valid?, inspect(changeset.errors)
        end
      end
    end
  end

  describe "allow_internal_urls bypass" do
    test "bypass=true accepts localhost" do
      Application.put_env(:phoenix_kit_sync, :allow_internal_urls, true)
      assert changeset_for("http://localhost:4000").valid?
    end

    test "bypass=true accepts RFC1918" do
      Application.put_env(:phoenix_kit_sync, :allow_internal_urls, true)
      assert changeset_for("http://10.0.0.5/api").valid?
    end

    test "bypass=true accepts ::1" do
      Application.put_env(:phoenix_kit_sync, :allow_internal_urls, true)
      assert changeset_for("http://[::1]/api").valid?
    end

    test "bypass=true does NOT bypass scheme check" do
      Application.put_env(:phoenix_kit_sync, :allow_internal_urls, true)
      assert site_url_error("file:///etc/passwd") == "must use http or https scheme"
    end
  end
end
