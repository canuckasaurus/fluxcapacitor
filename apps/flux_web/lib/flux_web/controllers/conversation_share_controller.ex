defmodule FluxWeb.ConversationShareController do
  @moduledoc """
  Read-only shared conversation transcripts: the unguessable
  `convshare_…` token in the URL is the authorization, revocable from
  the monitor. No composer, no navigation into the console.
  """
  use FluxWeb, :controller

  def show(conn, %{"token" => token}) do
    case Flux.Chat.get_shared_conversation(token) do
      {:ok, conversation, app, messages} ->
        render(conn, :show,
          conversation: conversation,
          app_name: (app && app.name) || "Conversation",
          messages: messages
        )

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> put_view(html: FluxWeb.ErrorHTML)
        |> render("404.html")
    end
  end
end
