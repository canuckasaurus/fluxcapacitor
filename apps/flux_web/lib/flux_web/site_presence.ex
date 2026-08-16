defmodule FluxWeb.SitePresence do
  @moduledoc """
  Live visitor tracking on public sites, on top of `FluxWeb.Presence`:
  site LiveViews track themselves per app (keyed by conversation), the
  app monitor counts them, and the away-mail check in `Flux.Chat` asks
  `visitor_present?/1` before emailing a visitor who is actually still
  looking at the tab (config `:flux, :site_presence` points here).
  """

  def topic(app_id), do: "site_presence:#{app_id}"

  @doc "Tracks the calling LiveView as a live visitor of this app."
  def track(pid, app_id, conversation_id) do
    FluxWeb.Presence.track(pid, topic(app_id), conversation_id || "browsing-#{inspect(pid)}", %{
      at: System.system_time(:second)
    })
  end

  @doc "How many visitors have the app's site open right now."
  def visitor_count(app_id) do
    app_id |> topic() |> FluxWeb.Presence.list() |> map_size()
  end

  @doc "Whether some tab currently shows this conversation (away-mail check)."
  def visitor_present?(conversation_id) do
    # The conversation's app id isn't at hand where this is asked, so
    # resolve it: one indexed read, only on human replies.
    case Flux.Repo.get(Flux.Chat.Conversation, conversation_id, skip_workspace_guard: true) do
      nil ->
        false

      conversation ->
        conversation.app_id
        |> topic()
        |> FluxWeb.Presence.list()
        |> Map.has_key?(conversation_id)
    end
  end
end
