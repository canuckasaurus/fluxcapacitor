defmodule Flux.Doctor do
  @moduledoc """
  Environment self-check for self-hosters: is everything this install
  is configured to use actually reachable? Optional services that are
  simply not configured report `skipped`, never failure.
  """

  @doc "Runs every check; returns `[{name, :ok | :skipped | {:error, detail}}]`."
  def checks do
    [
      {"database", check_database()},
      {"storage", check_storage()},
      {"oban", check_oban()},
      {"tika (office extraction)", check_tika()},
      {"gotenberg (PDF output)", check_gotenberg()},
      {"coderunner (code nodes)", check_coderunner()},
      {"vector backend", check_vector_backend()},
      {"metrics endpoint", check_metrics()}
    ]
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Flux.Repo, "SELECT 1", []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp check_storage do
    key = "health/doctor-#{System.unique_integer([:positive])}"

    with :ok <- Flux.Storage.put(key, "ok"),
         {:ok, _binary} <- Flux.Storage.get(key) do
      Flux.Storage.delete(key)
      :ok
    else
      error -> {:error, inspect(error)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp check_oban do
    case Oban.check_queue(queue: :ingest) do
      %{paused: false} -> :ok
      %{paused: true} -> {:error, "ingest queue is paused"}
      _other -> {:error, "ingest queue not running"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp check_tika do
    if Flux.Tika.configured?() do
      case Flux.Tika.extract("plain text probe", "text/plain") do
        {:ok, _text} -> :ok
        {:error, message} -> {:error, message}
      end
    else
      :skipped
    end
  end

  defp check_gotenberg do
    if Flux.Pdf.configured?() do
      probe_http(Application.get_env(:flux, Flux.Pdf, [])[:url])
    else
      :skipped
    end
  end

  defp check_coderunner do
    case Application.get_env(:flux, Flux.CodeRunner.Sandbox, [])[:url] do
      nil -> :skipped
      url -> probe_http(to_string(url) <> "/health")
    end
  end

  defp check_vector_backend do
    case Application.get_env(:flux, :vector_store) do
      nil ->
        :skipped

      module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :available?, 0) do
          if module.available?(), do: :ok, else: {:error, "#{inspect(module)} not available"}
        else
          :ok
        end
    end
  end

  defp check_metrics do
    if Application.get_env(:flux_web, :metrics_enabled, false), do: :ok, else: :skipped
  end

  # Any HTTP answer at all counts as reachable (404 on a health path is
  # still a listening service).
  defp probe_http(url) do
    case Req.get(url: to_string(url), retry: false, receive_timeout: 5_000) do
      {:ok, %{status: status}} when status < 500 -> :ok
      {:ok, %{status: status}} -> {:error, "answered HTTP #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
