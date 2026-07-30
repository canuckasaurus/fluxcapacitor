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
end
