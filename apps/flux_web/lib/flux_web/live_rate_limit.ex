defmodule FluxWeb.LiveRateLimit do
  @moduledoc """
  Per-IP rate limiting for LiveView events that kick off privileged work
  but never traverse the HTTP plug pipeline, so the `:auth_rate_limit`
  plug can't see them. The magic-link (`submit_magic`) and registration
  (`save`) events send email over the websocket; without a throttle an
  attacker can drive them to inbox-bomb accounts and burn mail spend.

  Disabled (always allows) when `config :flux_web, :rate_limit_enabled`
  is false, matching the plug and the test environment.
  """

  @doc "True when the socket's connect IP is under `limit` hits this window."
  def allow?(socket, bucket, limit, scale_ms \\ 60_000) do
    if Application.get_env(:flux_web, :rate_limit_enabled, true) do
      case FluxWeb.RateLimit.hit("#{bucket}:#{connect_ip(socket)}", scale_ms, limit) do
        {:allow, _count} -> true
        {:deny, _retry_ms} -> false
      end
    else
      true
    end
  end

  defp connect_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _unavailable -> "unknown"
    end
  end
end
