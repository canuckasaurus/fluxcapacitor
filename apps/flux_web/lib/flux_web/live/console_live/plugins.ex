defmodule FluxWeb.ConsoleLive.Plugins do
  @moduledoc false
  use FluxWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Plugins")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:plugins}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Plugins</h1>
          <p class="opacity-70 mt-1">
            Model providers and tools installed for this workspace.
          </p>
        </div>
        <button
          class="btn btn-primary"
          disabled
          title="Plugin management ships with the model-provider milestone"
        >
          <.icon name="hero-plus" class="size-4" /> Install plugin
        </button>
      </div>

      <div class="card border border-dashed border-base-300 p-12 text-center space-y-3">
        <.icon name="hero-puzzle-piece" class="size-10 text-primary mx-auto" />
        <h2 class="font-semibold text-lg">Plugin management is coming soon</h2>
        <p class="opacity-70 max-w-md mx-auto text-sm">
          Admins will install model providers (OpenAI, Anthropic, Azure, Bedrock) and tools
          here, manage their credentials, and control which capabilities each plugin gets.
          This lands with the model-provider milestone.
        </p>
      </div>
    </Layouts.console>
    """
  end
end
