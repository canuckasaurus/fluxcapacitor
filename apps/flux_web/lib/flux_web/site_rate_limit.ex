defmodule FluxWeb.SiteRateLimit do
  @moduledoc """
  Rate limiting for public-site LiveView events (messages/runs), which never
  pass through the HTTP plug pipeline. Two buckets per event: a per-site cap
  protecting the workspace owner's provider bill, and a tighter per-visitor
  cap keyed by connect IP.
  """

  @per_site_per_minute 120
  @per_visitor_per_minute 15

  def allow?(site_token, visitor_ip) do
    with {:allow, _count} <-
           FluxWeb.RateLimit.hit("site:#{site_token}", 60_000, @per_site_per_minute),
         {:allow, _count} <-
           FluxWeb.RateLimit.hit(
             "site:#{site_token}:#{visitor_ip}",
             60_000,
             @per_visitor_per_minute
           ) do
      true
    else
      {:deny, _limit} -> false
    end
  end

  @doc "The visitor's IP as a string, from LiveView connect info (nil on static render)."
  def visitor_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _unavailable -> "unknown"
    end
  end
end
