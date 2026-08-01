defmodule Flux.Workflows.AlertWorker do
  @moduledoc """
  Delivers a failed-run alert to the workspace's webhook URL (Oban-backed
  so provider hiccups retry; SSRF-guarded at delivery time too).
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "payload" => payload}}) do
    with :ok <- Flux.SSRF.verify_url(url) do
      case Req.post(
             [url: url, json: payload, receive_timeout: 10_000] ++
               Application.get_env(:flux, :alert_req_options, [])
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, "alert endpoint returned HTTP #{status}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end
end
