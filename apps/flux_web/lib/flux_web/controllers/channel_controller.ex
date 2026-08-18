defmodule FluxWeb.ChannelController do
  @moduledoc """
  Inbound chat channels. `/channels/email/:token` receives a mail
  provider's inbound webhook (Mailgun routes, SES, Postmark — same
  field names the email *trigger* accepts): sender + body become a chat
  turn keyed to the sender's address, and the finished reply is mailed
  back. The `emch_` token in the path is the authorization.
  """
  use FluxWeb, :controller

  alias Flux.Chat

  def email(conn, %{"token" => token} = params) do
    from = sender_field(params)
    body = body_field(params)

    with {:ok, app} <- Chat.get_app_by_email_channel_token(token),
         true <- (is_binary(from) and from =~ "@") || {:error, :no_sender},
         true <- String.trim(body) != "" || {:error, :empty},
         {:ok, conversation_id} <-
           Chat.email_inbound(app, from, params["subject"] || params["Subject"], body) do
      conn |> put_status(202) |> json(%{conversation_id: conversation_id, status: "replying"})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{code: "not_found", message: "Unknown channel token"})

      {:error, :no_sender} ->
        conn |> put_status(400) |> json(%{code: "invalid_param", message: "No sender address"})

      {:error, :empty} ->
        conn |> put_status(400) |> json(%{code: "invalid_param", message: "Empty message body"})

      {:error, :guardrail} ->
        conn |> put_status(403) |> json(%{code: "guardrail", message: "Message not allowed"})

      {:error, :quota_exceeded} ->
        conn |> put_status(429) |> json(%{code: "quota_exceeded", message: "App limit spent"})
    end
  end

  # Slack Events API: answer the URL-verification handshake, turn
  # message events into chat turns, and 202 fast (Slack retries slow
  # webhooks). Bot and edited messages are ignored to avoid loops.
  def slack(conn, %{"type" => "url_verification", "challenge" => challenge}) do
    json(conn, %{"challenge" => challenge})
  end

  def slack(conn, %{"token" => token} = params) do
    with {:ok, app} <- Chat.get_app_by_slack_channel_token(token),
         {:ok, channel, user, text, thread_ts} <- slack_message(params),
         {:ok, conversation_id} <- Chat.slack_inbound(app, channel, user, text, thread_ts) do
      conn |> put_status(202) |> json(%{conversation_id: conversation_id, status: "replying"})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{code: "not_found", message: "Unknown channel token"})

      {:error, :guardrail} ->
        conn |> put_status(202) |> json(%{status: "refused"})

      {:error, :quota_exceeded} ->
        conn |> put_status(429) |> json(%{code: "quota_exceeded", message: "App limit spent"})

      :ignore ->
        conn |> put_status(202) |> json(%{status: "ignored"})
    end
  end

  defp slack_message(%{
         "event" =>
           %{"type" => "message", "channel" => channel, "user" => user, "text" => text} = event
       })
       when is_binary(text) and text != "" do
    if Map.has_key?(event, "bot_id") or Map.has_key?(event, "subtype") do
      :ignore
    else
      {:ok, channel, user, text, event["thread_ts"] || event["ts"]}
    end
  end

  defp slack_message(_params), do: :ignore

  defp sender_field(params) do
    params["from"] || params["sender"] || params["From"] ||
      get_in(params, ["envelope", "from"])
  end

  defp body_field(params) do
    params["body-plain"] || params["stripped-text"] || params["text"] ||
      params["TextBody"] || ""
  end
end
