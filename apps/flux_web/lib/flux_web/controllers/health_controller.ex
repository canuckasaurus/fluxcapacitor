defmodule FluxWeb.HealthController do
  @moduledoc """
  Load-balancer probes. `GET /health` is liveness (the VM answers);
  `GET /health/ready` is readiness — database reachable and storage
  writable — answering 503 with per-check detail when not.
  """
  use FluxWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def ready(conn, _params) do
    checks = %{database: check_database(), storage: check_storage()}
    healthy? = Enum.all?(checks, fn {_name, status} -> status == "ok" end)

    conn
    |> put_status((healthy? && 200) || 503)
    |> json(%{status: (healthy? && "ok") || "degraded", checks: checks})
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Flux.Repo, "SELECT 1", []) do
      {:ok, _result} -> "ok"
      {:error, _reason} -> "unreachable"
    end
  rescue
    _exception -> "unreachable"
  end

  defp check_storage do
    key = "health/probe-#{System.unique_integer([:positive])}"

    with :ok <- Flux.Storage.put(key, "ok"),
         {:ok, _binary} <- Flux.Storage.get(key) do
      Flux.Storage.delete(key)
      "ok"
    else
      _error -> "unreachable"
    end
  rescue
    _exception -> "unreachable"
  end
end
