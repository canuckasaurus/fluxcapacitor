defmodule FluxWeb.ConsoleLive.Knowledge do
  @moduledoc false
  use FluxWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Knowledge")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console flash={@flash} current_scope={@current_scope} active={:knowledge}>
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Knowledge</h1>
          <p class="opacity-70 mt-1">Document collections your Fluxes can retrieve from.</p>
        </div>
        <button class="btn btn-primary" disabled title="Knowledge bases ship with the RAG milestone">
          <.icon name="hero-plus" class="size-4" /> New knowledge base
        </button>
      </div>

      <div class="card border border-dashed border-base-300 p-12 text-center space-y-3">
        <.icon name="hero-book-open" class="size-10 text-primary mx-auto" />
        <h2 class="font-semibold text-lg">Knowledge bases are coming next</h2>
        <p class="opacity-70 max-w-md mx-auto text-sm">
          Upload PDFs, Office documents, and web content; FluxCapacitor will chunk, index, and
          embed them so Fluxes can answer with citations. This lands with the RAG milestone.
        </p>
      </div>
    </Layouts.console>
    """
  end
end
