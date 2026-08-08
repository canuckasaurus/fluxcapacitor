defmodule Flux.Workflows.AlertWorker do
  @moduledoc """
  Delivers a failed-run alert to the workspace's webhook URL (Oban-backed
  so provider hiccups retry; SSRF-guarded at delivery time too). When the
  workspace has an alert secret, the exact body bytes are signed with
  HMAC-SHA256 and sent as `x-flux-signature: sha256=<hex>` so receivers
  can verify authenticity.
  """
  use Oban.Worker, queue: :default, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: %{"url" => url, "payload" => payload} = args}) do
    with :ok <- Flux.SSRF.verify_url(url) do
      body =
        case args["format"] do
          "slack" -> Jason.encode!(slack_payload(payload))
          _json -> Jason.encode!(payload)
        end

      headers =
        [{"content-type", "application/json"}] ++ signature_headers(args["secret"], body)

      result =
        Req.post(
          [url: url, body: body, headers: headers, receive_timeout: 10_000] ++
            Application.get_env(:flux, :alert_req_options, [])
        )

      # Endpoint deliveries keep a log row; run-failure alerts don't.
      case result do
        {:ok, %{status: status}} when status in 200..299 ->
          Flux.Webhooks.record_attempt(args["delivery_id"], attempt, status, nil)
          :ok

        {:ok, %{status: status}} ->
          error = "endpoint returned HTTP #{status}"
          Flux.Webhooks.record_attempt(args["delivery_id"], attempt, status, error)
          {:error, error}

        {:error, reason} ->
          Flux.Webhooks.record_attempt(args["delivery_id"], attempt, nil, inspect(reason))
          {:error, inspect(reason)}
      end
    end
  end

  # Block Kit wrapper for Slack incoming webhooks: a headline from the
  # event name plus the payload's scalar fields as a readable list.
  defp slack_payload(payload) do
    event = payload["event"] || "flux.event"

    fields =
      payload
      |> Enum.reject(fn {key, value} -> key == "event" or is_map(value) or is_list(value) end)
      |> Enum.map_join("\n", fn {key, value} -> "*#{key}:* #{value}" end)

    %{
      "text" => "FluxCapacitor: #{event}",
      "blocks" =>
        [
          %{
            "type" => "section",
            "text" => %{"type" => "mrkdwn", "text" => "*FluxCapacitor* — `#{event}`"}
          }
        ] ++
          if fields == "" do
            []
          else
            [%{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => fields}}]
          end
    }
  end

  defp signature_headers(secret, body) when is_binary(secret) and secret != "" do
    signature = Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
    [{"x-flux-signature", "sha256=" <> signature}]
  end

  defp signature_headers(_absent, _body), do: []
end
