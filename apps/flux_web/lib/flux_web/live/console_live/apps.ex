defmodule FluxWeb.ConsoleLive.Apps do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.Chat
  alias Flux.Chat.App
  alias Flux.Providers
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Apps",
       creating: false,
       form: to_form(App.changeset(%App{}, %{})),
       models: Providers.available_models(scope),
       can_create: RBAC.can?(scope, :app_create_and_management)
     )
     |> assign(apps: Chat.list_apps(scope))}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false)}
  end

  def handle_event("validate", %{"app" => params}, socket) do
    {:noreply, assign(socket, form: to_form(App.changeset(%App{}, split_model_choice(params))))}
  end

  def handle_event("save", %{"app" => params}, socket) do
    params = split_model_choice(params)

    case Chat.create_app(socket.assigns.current_scope, params) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "App \"#{app.name}\" created.")
         |> push_navigate(to: ~p"/console/apps/#{app.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create apps.")}
    end
  end

  def handle_event("delete", %{"app-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %App{} = app <- Chat.get_app(scope, id),
         {:ok, _} <- Chat.delete_app(scope, app) do
      {:noreply,
       socket |> put_flash(:info, "App deleted.") |> assign(apps: Chat.list_apps(scope))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not delete that app.")}
    end
  end

  # The select submits "plugin_id|model"; split it back into two fields.
  defp split_model_choice(%{"model_choice" => choice} = params) do
    case String.split(choice, "|", parts: 2) do
      [plugin_id, model] ->
        params
        |> Map.put("provider_plugin_id", plugin_id)
        |> Map.put("model", model)

      _ ->
        params
    end
  end

  defp split_model_choice(params), do: params

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:apps}
    >
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">Apps</h1>
          <p class="opacity-70 mt-1">Chat applications backed by your configured models.</p>
        </div>
        <button :if={@can_create and not @creating} class="btn btn-primary" phx-click="new">
          <.icon name="hero-plus" class="size-4" /> New app
        </button>
      </div>

      <div :if={@creating} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Create an app</h2>
        <p :if={@models == []} class="text-sm text-warning">
          No models available — configure a provider under Plugins first.
        </p>
        <.form for={@form} id="app-form" phx-submit="save" phx-change="validate" class="space-y-3">
          <.input field={@form[:name]} type="text" label="Name" placeholder="Support Assistant" />
          <.input
            field={@form[:mode]}
            type="select"
            label="Mode"
            options={[{"Chat — back-and-forth conversation", "chat"},
                      {"Completion — one-shot text generation from a form", "completion"}]}
          />
          <.input
            field={@form[:model_choice]}
            name="app[model_choice]"
            type="select"
            label="Model"
            options={
              for %{plugin_id: pid, plugin_name: pname, model: m} <- @models do
                {"#{pname} — #{m.label}", "#{pid}|#{m.name}"}
              end
            }
          />
          <.input
            :if={to_string(@form[:mode].value || "chat") == "chat"}
            field={@form[:system_prompt]}
            type="textarea"
            label="System prompt"
            placeholder="You are a helpful assistant for..."
          />
          <.input
            :if={to_string(@form[:mode].value) == "completion"}
            field={@form[:prompt_template]}
            type="textarea"
            label="Prompt template"
            placeholder="Summarize the following text: {{inputs.text}}"
          />
          <p :if={to_string(@form[:mode].value) == "completion"} class="text-xs opacity-60">
            Reference form variables as <code>{"{{inputs.name}}"}</code> — define the form
            fields on the app page after creating it.
          </p>
          <div class="flex gap-2">
            <button class="btn btn-primary" disabled={@models == []}>Create app</button>
            <button type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
          </div>
        </.form>
      </div>

      <div
        :if={@apps == [] and not @creating}
        class="card border border-dashed border-base-300 p-12 text-center space-y-3"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-10 text-primary mx-auto" />
        <h2 class="font-semibold text-lg">No apps yet</h2>
        <p class="opacity-70 text-sm">Create your first chat app to start talking to a model.</p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={app <- @apps}
          class="card border border-base-200 p-6 space-y-2"
          id={"app-#{app.id}"}
        >
          <div class="flex items-start justify-between">
            <h2 class="font-semibold">{app.name}</h2>
            <button
              :if={@can_create}
              class="btn btn-ghost btn-xs text-error"
              phx-click="delete"
              phx-value-app-id={app.id}
              data-confirm={"Delete #{app.name}?"}
            >
              Delete
            </button>
          </div>
          <p class="text-xs opacity-60">
            <span class="badge badge-ghost badge-xs align-middle">{app.mode}</span>
            {app.provider_plugin_id} · {app.model}
          </p>
          <p :if={app.description} class="text-sm opacity-70">{app.description}</p>
          <.link navigate={~p"/console/apps/#{app.id}"} class="btn btn-sm btn-outline w-fit">
            {(app.mode == :completion && "Open app") || "Open chat"}
          </.link>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
