defmodule FluxWeb.StatusHTML do
  @moduledoc false
  use FluxWeb, :html

  def show(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl p-6 space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-bolt-solid" class="size-6 flux-bolt" />
        <span class="text-xl flux-wordmark">FluxCapacitor</span>
        <span class="ml-auto badge badge-sm" id="overall-status">
          {(@operational? && "All systems go") || "Degraded"}
        </span>
      </div>

      <div :if={@note} class="alert alert-warning text-sm" id="incident-note">
        <.icon name="hero-exclamation-triangle" class="size-4" />
        <span class="whitespace-pre-wrap">{@note}</span>
      </div>

      <div class="card border border-base-200 divide-y divide-base-200">
        <div
          :for={component <- @components}
          class="flex items-center justify-between px-4 py-2 text-sm"
        >
          <span>{component.name}</span>
          <span class={[
            "badge badge-sm",
            component.state == "ok" && "badge-success",
            component.state == "down" && "badge-error",
            component.state == "not configured" && "badge-ghost"
          ]}>
            {component.state}
          </span>
        </div>
      </div>

      <p class="text-xs opacity-50">
        Checked live on request. Probes: <span class="font-mono">/health</span>
        · <span class="font-mono">/health/ready</span>
        · JSON: <span class="font-mono">GET /status/json</span>.
      </p>
    </div>
    """
  end
end
