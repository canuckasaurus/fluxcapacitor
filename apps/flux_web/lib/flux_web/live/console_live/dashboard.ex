defmodule FluxWeb.ConsoleLive.Dashboard do
  @moduledoc false
  use FluxWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:dashboard}
    >
      <div>
        <h1 class="text-2xl font-bold">
          Welcome to {@current_scope.workspace.name}
        </h1>
        <p class="opacity-70 mt-1">
          You're signed in as {@current_scope.account.email} ({@current_scope.membership.role}).
        </p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <.link
          navigate={~p"/console/fluxes"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-squares-2x2" class="size-6 text-primary" />
          <h2 class="font-semibold">Create a Flux</h2>
          <p class="text-sm opacity-70">
            Build an AI workflow on the visual canvas and publish it for your team.
          </p>
        </.link>

        <.link
          navigate={~p"/console/knowledge"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-book-open" class="size-6 text-primary" />
          <h2 class="font-semibold">Add knowledge</h2>
          <p class="text-sm opacity-70">
            Upload documents so your Fluxes can answer with your organization's content.
          </p>
        </.link>

        <.link
          navigate={~p"/console/plugins"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-puzzle-piece" class="size-6 text-primary" />
          <h2 class="font-semibold">Set up plugins</h2>
          <p class="text-sm opacity-70">
            Connect model providers and tools your workspace can use.
          </p>
        </.link>

        <.link
          navigate={~p"/console/members"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-user-group" class="size-6 text-primary" />
          <h2 class="font-semibold">Invite your team</h2>
          <p class="text-sm opacity-70">
            Add teammates and assign roles so everyone can collaborate.
          </p>
        </.link>
      </div>
    </Layouts.console>
    """
  end
end
