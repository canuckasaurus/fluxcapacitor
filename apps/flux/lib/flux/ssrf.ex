defmodule Flux.SSRF do
  @moduledoc """
  Guard for user-directed outbound HTTP (provider base URLs, API toolsets,
  the future http-request node): rejects URLs whose host is — or resolves
  to — a loopback, private, link-local, CGNAT, or unspecified address, on
  either IP family. Cloud metadata endpoints (169.254.0.0/16) fall under
  link-local.

  `verify_url/1` is a check-time guard: it answers "is this URL safe to
  fetch right now?" but Finch/Req resolve the host again at connect time,
  so a hostname that was public when checked can rebind to a private
  address by the time the TCP connection opens (DNS rebinding). `pin/1`
  (and `merge_pin/2`, for folding into an existing Req option list) close
  that gap: they resolve once, verify every candidate address, and return
  options that connect directly to the checked peer IP while preserving
  the original Host header and TLS SNI.

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
    with {:ok, uri} <- validate(url) do
      cond do
        not enabled?() -> :ok
        uri.host in allowlist() -> :ok
        true -> with {:ok, _address} <- pick_address(uri.host), do: :ok
      end
    end
  end

  def verify_url(_other), do: {:error, "The URL has no host."}

  @doc """
  Resolves `url`'s host once, verifies every resolved address, and picks a
  single allowed peer IP. Returns Req/Finch options that connect to that
  IP literal while preserving the original Host header and TLS SNI —
  closing the check-time/connect-time TOCTOU gap that `verify_url/1` alone
  leaves open.

  When SSRF checks are disabled or the host is allowlisted, returns
  passthrough options (unpinned `:url`, still `redirect: false`) so
  local/dev flows keep working.
  """
  @spec pin(String.t() | nil) :: {:ok, keyword()} | {:error, String.t()}
  def pin(url) when is_binary(url) do
    with {:ok, uri} <- validate(url) do
      cond do
        not enabled?() -> {:ok, [url: url, redirect: false]}
        uri.host in allowlist() -> {:ok, [url: url, redirect: false]}
        true -> with {:ok, address} <- pick_address(uri.host), do: {:ok, pinned_options(uri, address)}
      end
    end
  end

  def pin(_other), do: {:error, "The URL has no host."}

  @doc """
  Merges `pin/1`'s options into an existing Req option list: swaps in the
  pinned `:url`, folds the Host header into `:headers` (list- or
  map-shaped), merges `:connect_options` (SNI), and forces
  `redirect: false`. Returns `{:ok, options}` or `{:error, message}`.
  """
  @spec merge_pin(keyword(), String.t() | nil) :: {:ok, keyword()} | {:error, String.t()}
  def merge_pin(options, url) do
    with {:ok, pin_opts} <- pin(url) do
      {:ok, do_merge(options, pin_opts)}
    end
  end

  defp do_merge(options, pin_opts) do
    options
    |> Keyword.put(:url, pin_opts[:url])
    |> Keyword.put(:redirect, false)
    |> merge_headers(pin_opts[:headers])
    |> merge_connect_options(pin_opts[:connect_options])
  end

  defp merge_headers(options, nil), do: options

  defp merge_headers(options, extra) do
    Keyword.update(options, :headers, extra, fn
      existing when is_map(existing) -> Enum.into(extra, existing)
      existing when is_list(existing) -> existing ++ extra
    end)
  end

  defp merge_connect_options(options, nil), do: options

  defp merge_connect_options(options, extra) do
    Keyword.update(options, :connect_options, extra, fn existing ->
      Keyword.merge(existing, extra, fn
        :transport_opts, e, n -> Keyword.merge(e, n)
        _key, _e, n -> n
      end)
    end)
  end

  defp validate(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, "Only http(s) URLs are allowed."}
      uri.host in [nil, ""] -> {:error, "The URL has no host."}
      true -> {:ok, uri}
    end
  end

  defp pinned_options(uri, address) do
    ip = address |> :inet.ntoa() |> to_string()

    [
      url: URI.to_string(%{uri | host: ip}),
      headers: [{"host", uri.host}],
      connect_options: [transport_opts: [server_name_indication: String.to_charlist(uri.host)]],
      redirect: false
    ]
  end

  defp pick_address(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        if blocked?(address) do
          {:error, "Host #{host} resolves to a blocked address (#{:inet.ntoa(address)})."}
        else
          {:ok, address}
        end

      {:error, _not_literal} ->
        resolve_and_pick(charlist, host)
    end
  end

  defp resolve_and_pick(charlist, host) do
    addresses =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, v4} -> v4
        {:error, _reason} -> []
      end ++
        case :inet.getaddrs(charlist, :inet6) do
          {:ok, v6} -> v6
          {:error, _reason} -> []
        end

    cond do
      addresses == [] ->
        {:error, "Could not resolve host #{host}."}

      blocked = Enum.find(addresses, &blocked?/1) ->
        {:error, "Host #{host} resolves to a blocked address (#{:inet.ntoa(blocked)})."}

      true ->
        {:ok, hd(addresses)}
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
