defmodule FluxWeb.ConsoleLive.Fluxes do
  @moduledoc false
  use FluxWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Flux Creator")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console flash={@flash} current_scope={@current_scope} active={:fluxes}>
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Flux Creator</h1>
          <p class="opacity-70 mt-1">Design, debug, and publish AI workflows.</p>
        </div>
        <button
          class="btn btn-primary"
          disabled
          title="The visual creator ships with the workflow engine milestone"
        >
          <.icon name="hero-plus" class="size-4" /> New Flux
        </button>
      </div>

      <div class="card border border-dashed border-base-300 p-12 text-center space-y-3">
        <.icon name="hero-squares-2x2" class="size-10 text-primary mx-auto" />
        <h2 class="font-semibold text-lg">The visual canvas is on its way</h2>
        <p class="opacity-70 max-w-md mx-auto text-sm">
          The Flux Creator — the drag-and-drop workflow canvas with LLM, logic, knowledge, and
          tool nodes — arrives with the workflow-engine milestone. Meanwhile, set up your
          workspace: connect plugins, upload knowledge, and invite your team.
        </p>
      </div>
    </Layouts.console>
    """
  end
end
