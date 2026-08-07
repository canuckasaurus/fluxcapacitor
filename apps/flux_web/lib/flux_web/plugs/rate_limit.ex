defmodule FluxWeb.Plugs.RateLimit do
  @moduledoc """
  Per-principal rate limiting. Options:

    * `:name` — bucket namespace (required)
    * `:by` — `:service` (the authenticated app/workflow, mount after
      `ServiceAuth`) or `:ip` (default)
    * `:limit` / `:scale_ms` — allowance per window (default 60 per minute)
    * `:methods` — restrict to these HTTP methods (default: all)

  Disabled when `config :flux_web, :rate_limit_enabled` is false (test env).
  """
  import Plug.Conn

  def init(opts) do
    %{
      name: Keyword.fetch!(opts, :name),
      by: Keyword.get(opts, :by, :ip),
      limit: Keyword.get(opts, :limit, 60),
      scale_ms: Keyword.get(opts, :scale_ms, 60_000),
      methods: Keyword.get(opts, :methods)
    }
  end

  def call(conn, opts) do
    if enabled?() and (opts.methods == nil or conn.method in opts.methods) do
      enforce(conn, opts)
    else
      conn
    end
  end

  defp enforce(conn, opts) do
    key = "#{opts.name}:#{principal(conn, opts.by)}"

    case FluxWeb.RateLimit.hit(key, opts.scale_ms, opts.limit) do
      {:allow, count} ->
        # Standard quota headers so API clients can pace themselves.
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(opts.limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(opts.limit - count, 0)))

      {:deny, retry_after_ms} ->
        retry_after = max(div(retry_after_ms, 1000), 1)

        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(opts.limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            code: "rate_limited",
            message: "Too many requests; retry in #{retry_after}s",
            status: 429
          })
        )
        |> halt()
    end
  end

  defp principal(conn, :service) do
    case {conn.assigns[:service_app], conn.assigns[:service_workflow]} do
      {%{id: id}, _workflow} -> "app:#{id}"
      {_app, %{id: id}} -> "flux:#{id}"
      _unauthenticated -> principal(conn, :ip)
    end
  end

  defp principal(conn, :ip), do: "ip:" <> to_string(:inet.ntoa(conn.remote_ip))

  defp enabled?, do: Application.get_env(:flux_web, :rate_limit_enabled, true)
end
