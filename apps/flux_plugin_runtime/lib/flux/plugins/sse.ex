defmodule Flux.Plugins.SSE do
  @moduledoc """
  Shared server-sent-events streaming for provider plugins: POSTs via Req,
  splits the response into `data:` payloads, and folds them through the
  plugin's handler.

  State is carried in the process dictionary — safe because every plugin
  invocation runs in its own supervised task process, and Req's `into:`
  fun executes in the calling process.
  """

  @acc_key :flux_sse_acc
  @buf_key :flux_sse_buf

  @doc """
  Makes a streaming POST. `handle_data` is called with each `data:` payload
  (prefix stripped, `[DONE]` filtered) and the accumulator. Returns
  `{:ok, final_acc}` or `{:error, reason}`.
  """
  def stream_request(req_opts, acc, handle_data) do
    Process.put(@acc_key, acc)
    Process.put(@buf_key, "")

    result =
      Req.post(
        req_opts ++
          [
            receive_timeout: :timer.minutes(5),
            retry: false,
            into: fn {:data, data}, {req, resp} ->
              if resp.status == 200 do
                consume(data, handle_data)
                {:cont, {req, resp}}
              else
                # Non-200: let the body accumulate normally for the error tuple.
                {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
              end
            end
          ]
      )

    case result do
      {:ok, %{status: 200}} -> {:ok, Process.get(@acc_key)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  after
    Process.delete(@acc_key)
    Process.delete(@buf_key)
  end

  defp consume(data, handle_data) do
    {events, buffer} = split_events(Process.get(@buf_key) <> data)
    Process.put(@buf_key, buffer)

    acc =
      Enum.reduce(events, Process.get(@acc_key), fn event, acc ->
        case data_payload(event) do
          nil -> acc
          "[DONE]" -> acc
          payload -> handle_data.(payload, acc)
        end
      end)

    Process.put(@acc_key, acc)
  end

  defp split_events(buffer) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/)

    case Enum.split(parts, -1) do
      {events, [rest]} -> {events, rest}
      {[], []} -> {[], ""}
    end
  end

  defp data_payload(event) do
    event
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(fn
      "data: " <> payload -> payload
      "data:" <> payload -> String.trim_leading(payload)
      _ -> nil
    end)
  end
end
