defmodule Flux.SSRF do
  @moduledoc """
  Guard for user-directed outbound HTTP (provider base URLs, API toolsets,
  the future http-request node): rejects URLs whose host is — or resolves
  to — a loopback, private, link-local, CGNAT, or unspecified address, on
  either IP family. Cloud metadata endpoints (169.254.0.0/16) fall under
  link-local.

  Configuration (`config :flux, Flux.SSRF`):

    * `enabled: boolean` — `false` skips address checks (test env only)
    * `allow: [hostname]` — hosts exempted from address checks
      (`FLUX_SSRF_ALLOW` comma-list in releases)

  Scheme/host structure is validated even when disabled.
  """

  import Bitwise

  @doc "Returns `:ok` or `{:error, message}` for an outbound URL."
  @spec verify_url(String.t() | nil) :: :ok | {:error, String.t()}
  def verify_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "Only http(s) URLs are allowed."}

      uri.host in [nil, ""] ->
        {:error, "The URL has no host."}

      not enabled?() ->
        :ok

      uri.host in allowlist() ->
        :ok

      true ->
        verify_host(uri.host)
    end
  end

  def verify_url(_other), do: {:error, "The URL has no host."}

  defp verify_host(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        check_address(address, host)

      {:error, _not_literal} ->
        resolve_and_check(charlist, host)
    end
  end

  defp resolve_and_check(charlist, host) do
    addresses =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, v4} -> v4
        {:error, _reason} -> []
      end ++
        case :inet.getaddrs(charlist, :inet6) do
          {:ok, v6} -> v6
          {:error, _reason} -> []
        end

    if addresses == [] do
      {:error, "Could not resolve host #{host}."}
    else
      Enum.find_value(addresses, :ok, fn address ->
        case check_address(address, host) do
          :ok -> nil
          {:error, _message} = error -> error
        end
      end)
    end
  end

  defp check_address(address, host) do
    if blocked?(address) do
      {:error, "Host #{host} resolves to a blocked address (#{:inet.ntoa(address)})."}
    else
      :ok
    end
  end

  # IPv4
  defp blocked?({0, _b, _c, _d}), do: true
  defp blocked?({127, _b, _c, _d}), do: true
  defp blocked?({10, _b, _c, _d}), do: true
  defp blocked?({172, b, _c, _d}) when b in 16..31, do: true
  defp blocked?({192, 168, _c, _d}), do: true
  defp blocked?({169, 254, _c, _d}), do: true
  defp blocked?({100, b, _c, _d}) when b in 64..127, do: true
  defp blocked?({192, 0, 0, _d}), do: true
  defp blocked?({_a, _b, _c, _d}), do: false

  # IPv6: unspecified, loopback, v4-mapped, unique-local fc00::/7, link-local fe80::/10
  defp blocked?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp blocked?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: blocked?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})

  defp blocked?({a, _b, _c, _d, _e, _f, _g, _h}) when band(a, 0xFE00) == 0xFC00, do: true
  defp blocked?({a, _b, _c, _d, _e, _f, _g, _h}) when band(a, 0xFFC0) == 0xFE80, do: true

  defp blocked?(_address), do: false

  defp enabled? do
    Keyword.get(config(), :enabled, true)
  end

  defp allowlist do
    Keyword.get(config(), :allow, [])
  end

  defp config, do: Application.get_env(:flux, __MODULE__, [])
end
