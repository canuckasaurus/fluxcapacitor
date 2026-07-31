defmodule FluxWeb.SiteLive.FluxSite do
  @moduledoc """
  The public face of a published flux at `/site/flux/:token` — no login;
  the site token in the URL is the authorization. Renders a form from the
  published version's start variables and streams the run's answer output.
  Always runs the latest published version, never the draft.
  """
  use FluxWeb, :live_view

  alias Flux.Workflows

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    with {:ok, workflow} <- Workflows.get_workflow_by_site_token(token),
         scope = Workflows.site_scope(workflow),
         %{} = version <- Workflows.latest_version(scope, workflow.id) || {:error, :not_published} do
      {:ok,
       assign(socket,
         page_title: workflow.name,
         workflow: workflow,
         visitor_ip: FluxWeb.SiteRateLimit.visitor_ip(socket),
         site_scope: scope,
         version: version,
         run: nil,
         run_text: ""
       )}
    else
      {:error, _not_found_or_unpublished} ->
        {:ok, assign(socket, page_title: "Not found", workflow: nil)}
    end
  end

  @impl true
  def handle_event("run", params, socket) do
    %{workflow: workflow, site_scope: scope, version: version} = socket.assigns

    with true <- FluxWeb.SiteRateLimit.allow?(workflow.site_token, socket.assigns.visitor_ip),
         {:ok, run} <-
           Workflows.start_run(scope, workflow, params["inputs"] || %{},
             graph: version.graph,
             version: version.version,
             source: :api
           ) do
      {:noreply, assign(socket, run: run, run_text: "")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Too many requests — please slow down.")}

      {:error, {:invalid_graph, _errors}} ->
        {:noreply, put_flash(socket, :error, "This flux cannot run right now.")}
    end
  end

  def handle_event("stop", _params, socket) do
    if run = socket.assigns.run do
      Workflows.stop_run(socket.assigns.site_scope, run.id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:engine_event, {:node_chunk, %{delta: delta}}}, socket) do
    {:noreply, assign(socket, run_text: socket.assigns.run_text <> delta)}
  end

  def handle_info({:engine_event, _event}, socket), do: {:noreply, socket}

  def handle_info({:run_finished, run}, socket) do
    {:noreply, assign(socket, run: run)}
  end

  defp start_variables(graph) do
    case Enum.find(graph["nodes"] || [], &(&1["type"] == "start")) do
      nil -> []
      start -> List.wrap(start["config"]["variables"])
    end
  end

  @impl true
  def render(%{workflow: nil} = assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center p-6">
      <div class="text-center space-y-2">
        <.icon name="hero-eye-slash" class="size-10 opacity-40 mx-auto" />
        <h1 class="font-semibold text-lg">This flux is not available.</h1>
        <p class="text-sm opacity-60">
          The link may be wrong, publishing was turned off, or no version has been published.
        </p>
      </div>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex flex-col items-center p-4 sm:p-6">
      <div class="w-full max-w-2xl flex-1 flex flex-col gap-4">
        <header class="pt-2">
          <h1 class="text-xl font-bold">{@workflow.name}</h1>
          <p :if={@workflow.description} class="text-sm opacity-70">{@workflow.description}</p>
        </header>

        <form phx-submit="run" id="site-flux-form" class="space-y-3">
          <div :for={variable <- start_variables(@version.graph)} class="form-control">
            <label class="label-text text-sm mb-1">
              {variable["label"] || variable["name"]}
              <span :if={variable["required"]} class="text-error">*</span>
            </label>
            <textarea
              :if={variable["type"] == "paragraph"}
              name={"inputs[#{variable["name"]}]"}
              rows="3"
              required={variable["required"] == true}
              class="textarea textarea-bordered w-full"
            ></textarea>
            <input
              :if={variable["type"] != "paragraph"}
              type={(variable["type"] == "number" && "number") || "text"}
              name={"inputs[#{variable["name"]}]"}
              required={variable["required"] == true}
              class="input input-bordered w-full"
            />
          </div>
          <div class="flex gap-2">
            <button
              class="btn btn-primary btn-sm"
              disabled={@run != nil and @run.status == :running}
            >
              <.icon name="hero-play" class="size-4" /> Run
            </button>
            <button
              :if={@run != nil and @run.status == :running}
              type="button"
              class="btn btn-warning btn-sm"
              phx-click="stop"
            >
              Stop
            </button>
          </div>
        </form>

        <div
          :if={@run_text != ""}
          id="site-flux-output"
          class="rounded-box bg-base-200 p-4 text-sm whitespace-pre-wrap"
        >
          {@run_text}
          <span :if={@run != nil and @run.status == :running} class="animate-pulse">▌</span>
        </div>

        <div :if={@run != nil and @run.status not in [nil, :running]} class="space-y-2">
          <p :if={@run.status == :failed} class="text-sm text-error">
            {@run.error || "The run failed."}
          </p>
          <div :if={@run.status == :succeeded and @run.outputs != %{} and @run_text == ""}>
            <pre class="rounded-box bg-base-200 p-4 text-xs overflow-x-auto">{Jason.encode!(@run.outputs, pretty: true)}</pre>
          </div>
        </div>

        <footer class="py-2 text-center text-xs opacity-40">
          Powered by FluxCapacitor
        </footer>
      </div>
    </main>
    <Layouts.flash_group flash={@flash} />
    """
  end
end
