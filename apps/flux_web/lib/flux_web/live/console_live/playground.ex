defmodule FluxWeb.ConsoleLive.Playground do
  @moduledoc """
  Model playground: one prompt against up to four provider/models side
  by side — reply, latency, tokens, and estimated cost per column, with
  one click to promote a winner to the workspace default.
  """
  use FluxWeb, :live_view

  alias Flux.Providers

  @max_columns 4

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "Playground",
       models: Providers.available_models(scope),
       can_default: Flux.RBAC.can?(scope, :plugin_model_config),
       prompt: "",
       results: %{},
       pending: [],
       selected: []
     )}
  end

  @impl true
  def handle_event("run", %{"prompt" => prompt} = params, socket) do
    choices =
      params
      |> Map.get("choices", [])
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@max_columns)

    prompt = String.trim(prompt)

    cond do
      prompt == "" ->
        {:noreply, put_flash(socket, :error, "Write a prompt first.")}

      choices == [] ->
        {:noreply, put_flash(socket, :error, "Pick at least one model.")}

      true ->
        parent = self()
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        for choice <- choices do
          [plugin_id, model] = String.split(choice, "|", parts: 2)

          Task.Supervisor.start_child(Flux.GenerationSupervisor, fn ->
            send(
              parent,
              {:playground_result, choice,
               Providers.playground_run(workspace_id, plugin_id, model, prompt)}
            )
          end)
        end

        {:noreply,
         assign(socket, prompt: prompt, selected: choices, pending: choices, results: %{})}
    end
  end

  def handle_event("make_default", %{"choice" => choice}, socket) do
    [plugin_id, model] = String.split(choice, "|", parts: 2)

    case Providers.set_default_model(socket.assigns.current_scope, plugin_id, model) do
      {:ok, _workspace} ->
        {:noreply, put_flash(socket, :info, "#{model} is now the workspace default model.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to set the default.")}
    end
  end

  @impl true
  def handle_info({:playground_result, choice, result}, socket) do
    {:noreply,
     assign(socket,
       results: Map.put(socket.assigns.results, choice, result),
       pending: List.delete(socket.assigns.pending, choice)
     )}
  end

  defp choice_label(models, choice) do
    case String.split(choice, "|", parts: 2) do
      [plugin_id, model] ->
        Enum.find_value(models, "#{plugin_id} — #{model}", fn entry ->
          entry.plugin_id == plugin_id and entry.model.name == model &&
            "#{entry.plugin_name} — #{entry.model.label}"
        end)

      _other ->
        choice
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:playground}
    >
      <div>
        <h1 class="text-2xl font-bold">{gettext("Playground")}</h1>
        <p class="opacity-70 mt-1">
          One prompt, several models side by side — pick the winner with numbers.
        </p>
      </div>

      <form phx-submit="run" id="playground-form" class="card border border-base-200 p-6 space-y-3">
        <textarea
          name="prompt"
          rows="4"
          placeholder="Write the prompt to race…"
          class="textarea textarea-bordered w-full"
        >{@prompt}</textarea>

        <div class="flex flex-wrap gap-3 text-sm">
          <label
            :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
            class="flex items-center gap-1"
          >
            <input
              type="checkbox"
              name="choices[]"
              value={"#{pid}|#{m.name}"}
              checked={"#{pid}|#{m.name}" in @selected}
              class="checkbox checkbox-xs"
            /> {pname} — {m.label}
          </label>
        </div>

        <button class="btn btn-primary btn-sm w-fit" disabled={@pending != []}>
          {(@pending != [] && "Racing…") || "Run (max 4)"}
        </button>
      </form>

      <div :if={@selected != []} class="grid gap-4 md:grid-cols-2">
        <div
          :for={choice <- @selected}
          class="card border border-base-200 p-4 space-y-2"
          id={"result-#{:erlang.phash2(choice)}"}
        >
          <h2 class="font-semibold text-sm">{choice_label(@models, choice)}</h2>

          <p :if={choice in @pending} class="text-sm opacity-60 animate-pulse">Running…</p>

          <%= case @results[choice] do %>
            <% {:ok, result} -> %>
              <div class="markdown-chat text-sm max-h-72 overflow-y-auto">
                {FluxWeb.Markdown.render(result.content)}
              </div>
              <p class="text-xs opacity-70">
                {result.latency_ms} ms · {result.input_tokens}in/{result.output_tokens}out
                <span :if={result.cost_usd}>
                  · ~${:erlang.float_to_binary(result.cost_usd * 1.0, decimals: 6)}
                </span>
              </p>
              <button
                :if={@can_default}
                class="btn btn-outline btn-xs w-fit"
                phx-click="make_default"
                phx-value-choice={choice}
              >
                Make workspace default
              </button>
            <% {:error, reason} -> %>
              <p class="text-sm text-error">Errored: {inspect(reason)}</p>
            <% nil -> %>
          <% end %>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
