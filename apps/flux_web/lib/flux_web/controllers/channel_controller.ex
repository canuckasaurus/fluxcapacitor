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

  defp sender_field(params) do
    params["from"] || params["sender"] || params["From"] ||
      get_in(params, ["envelope", "from"])
  end

  defp body_field(params) do
    params["body-plain"] || params["stripped-text"] || params["text"] ||
      params["TextBody"] || ""
  end
end
