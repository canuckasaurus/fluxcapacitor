defmodule FluxWeb.ConversationShareHTML do
  @moduledoc false
  use FluxWeb, :html

  def show(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6 space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-bolt-solid" class="size-6 flux-bolt" />
        <span class="text-xl flux-wordmark">FluxCapacitor</span>
        <span class="badge badge-ghost badge-sm">shared conversation · read-only</span>
      </div>

      <div class="card border border-base-200 p-4 space-y-1">
        <h1 class="font-semibold">{@conversation.title || "Conversation"}</h1>
        <p class="text-sm opacity-70">
          with {@app_name} · {Calendar.strftime(@conversation.inserted_at, "%Y-%m-%d %H:%M")} UTC
        </p>
      </div>

      <div class="card border border-base-200 p-4 space-y-3">
        <div :for={message <- @messages} class="flex items-start gap-2 text-sm">
          <span class={[
            "badge badge-sm shrink-0",
            (message.role == :user && "badge-primary") || "badge-ghost"
          ]}>
            {(message.role == :user && "visitor") || "reply"}
          </span>
          <p class="whitespace-pre-wrap break-words min-w-0 flex-1">
            {if message.status == :error, do: message.error, else: message.content}
          </p>
        </div>
      </div>

      <p class="text-xs opacity-50">
        Shared from the conversation owner's console — the link works until they revoke it.
      </p>
    </div>
    """
  end
end
