defmodule Flux.SSRFTest do
  use ExUnit.Case, async: false

  alias Flux.SSRF

  setup do
    original = Application.get_env(:flux, Flux.SSRF)
    Application.put_env(:flux, Flux.SSRF, enabled: true, allow: ["allowed.internal"])
    on_exit(fn -> Application.put_env(:flux, Flux.SSRF, original) end)
  end

  test "rejects non-http schemes and missing hosts" do
    assert {:error, _} = SSRF.verify_url("ftp://example.com/x")
    assert {:error, _} = SSRF.verify_url("file:///etc/passwd")
    assert {:error, _} = SSRF.verify_url("not a url")
    assert {:error, _} = SSRF.verify_url(nil)
  end

  test "blocks private, loopback, link-local, CGNAT, and metadata literals" do
    for host <- ~w(127.0.0.1 10.0.0.5 172.16.1.1 172.31.255.255 192.168.1.1
                   169.254.169.254 100.64.0.1 0.0.0.0) do
      assert {:error, message} = SSRF.verify_url("http://#{host}/path"),
             "expected #{host} to be blocked"

      assert message =~ "blocked"
    end
  end

  test "blocks IPv6 loopback, unique-local, link-local, and v4-mapped literals" do
    for host <- ~w([::1] [fc00::1] [fd12::1] [fe80::1] [::ffff:10.0.0.1]) do
      assert {:error, _message} = SSRF.verify_url("http://#{host}/"),
             "expected #{host} to be blocked"
    end
  end

  test "allows public literals and allowlisted hosts" do
    assert :ok = SSRF.verify_url("https://8.8.8.8/dns")
    assert :ok = SSRF.verify_url("https://allowed.internal/anything")
  end

  test "public v4-mapped IPv6 passes" do
    assert :ok = SSRF.verify_url("http://[::ffff:8.8.8.8]/")
  end

  test "disabled mode still validates structure but skips address checks" do
    Application.put_env(:flux, Flux.SSRF, enabled: false)
    assert :ok = SSRF.verify_url("http://127.0.0.1/x")
    assert {:error, _} = SSRF.verify_url("gopher://127.0.0.1/x")
  end

  # pin/1 and merge_pin/2 close the check-time/connect-time gap: Finch/Req
  # re-resolve the host at connect time, so a hostname that was public when
  # verify_url/1 checked it could rebind to a private address by then. pin
  # resolves once, verifies every candidate address (same blocked?/1 rules
  # as verify_url), and returns options that connect to a checked IP
  # literal directly — no second resolution happens.
  describe "pin/1" do
    test "rejects the same blocked literals and private resolutions verify_url rejects" do
      for host <- ~w(127.0.0.1 10.0.0.5 172.16.1.1 192.168.1.1 169.254.169.254) do
        assert {:error, message} = SSRF.pin("http://#{host}/path"),
               "expected #{host} to be blocked"

        assert message =~ "blocked"
      end
    end

    test "rejects non-http schemes and missing hosts" do
      assert {:error, _} = SSRF.pin("ftp://example.com/x")
      assert {:error, _} = SSRF.pin(nil)
    end

    test "a public IP literal pins cleanly: unchanged URL, redirect: false" do
      assert {:ok, opts} = SSRF.pin("https://8.8.8.8:8443/dns?x=1")

      # Already an IP literal, so the pinned URL is byte-identical to the
      # input — pinning is a no-op rewrite here, just a verified pass-through.
      assert opts[:url] == "https://8.8.8.8:8443/dns?x=1"
      assert opts[:redirect] == false
    end

    test "a public hostname is pinned to a resolved peer IP with Host header and SNI preserved" do
      assert {:ok, opts} = SSRF.pin("https://example.com/path?q=1")

      assert opts[:redirect] == false
      assert [{"host", "example.com"}] = opts[:headers]

      assert [transport_opts: [server_name_indication: ~c"example.com"]] =
               opts[:connect_options]

      pinned_uri = URI.parse(opts[:url])
      assert pinned_uri.scheme == "https"
      assert pinned_uri.path == "/path"
      assert pinned_uri.query == "q=1"
      assert {:ok, _address} = :inet.parse_address(String.to_charlist(pinned_uri.host))
    end

    test "an allowlisted host pins through unchanged (still redirect: false)" do
      assert {:ok, opts} = SSRF.pin("https://allowed.internal/anything")
      assert opts[:url] == "https://allowed.internal/anything"
      assert opts[:redirect] == false
      refute Keyword.has_key?(opts, :headers)
    end

    test "disabled mode passes the URL through unchanged" do
      Application.put_env(:flux, Flux.SSRF, enabled: false)
      assert {:ok, opts} = SSRF.pin("http://127.0.0.1/x")
      assert opts[:url] == "http://127.0.0.1/x"
      assert opts[:redirect] == false
    end
  end

  describe "merge_pin/2" do
    test "folds the pinned url/headers/connect_options into an existing option list" do
      base = [url: "https://example.com/x", headers: [{"authorization", "Bearer t"}]]

      assert {:ok, options} = SSRF.merge_pin(base, "https://example.com/x")

      assert options[:redirect] == false
      assert {"authorization", "Bearer t"} in options[:headers]
      assert {"host", "example.com"} in options[:headers]
      assert [transport_opts: [server_name_indication: ~c"example.com"]] =
               options[:connect_options]

      refute options[:url] == "https://example.com/x"
      assert {:ok, _address} = :inet.parse_address(String.to_charlist(URI.parse(options[:url]).host))
    end

    test "folds into a map-shaped headers option too" do
      base = [url: "https://example.com/x", headers: %{"authorization" => "Bearer t"}]

      assert {:ok, options} = SSRF.merge_pin(base, "https://example.com/x")

      assert options[:headers]["authorization"] == "Bearer t"
      assert options[:headers]["host"] == "example.com"
    end

    test "propagates a pin rejection instead of returning options" do
      assert {:error, message} =
               SSRF.merge_pin([url: "http://127.0.0.1/x"], "http://127.0.0.1/x")

      assert message =~ "blocked"
    end

    # Redirect defense vs. TOCTOU defense are two different guards: every
    # sink also sets `redirect: false` (unconditionally, via merge_pin) so
    # a verified host can't 302 to an internal address; pin/merge_pin
    # separately closes the gap where Finch would otherwise re-resolve the
    # (still-followed) request's own host at connect time. Exercising an
    # actual redirect-to-internal or rebind-at-connect end-to-end would
    # require a live DNS server or a Bypass endpoint that changes its own
    # resolved address mid-test, which isn't practical to fake here — the
    # two properties above (redirect: false is always present; the
    # connected address is always the one verified) are what's tested.
    test "always forces redirect: false even when the caller passed something else" do
      assert {:ok, options} =
               SSRF.merge_pin([url: "https://8.8.8.8/x", redirect: true], "https://8.8.8.8/x")

      assert options[:redirect] == false
    end
  end
end
