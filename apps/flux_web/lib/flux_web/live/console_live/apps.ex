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
       importing: false,
       form: to_form(App.changeset(%App{}, %{})),
       models: Providers.available_models(scope),
       fluxes: Flux.Workflows.list_workflows(scope),
       can_create: RBAC.can?(scope, :app_create_and_management),
       tag_filter: nil
     )
     |> load_apps()}
  end

  defp load_apps(socket) do
    scope = socket.assigns.current_scope
    starred = Flux.Accounts.favorite_ids(scope.account, "app")

    apps =
      Enum.sort_by(Chat.list_apps(scope), fn app ->
        {(MapSet.member?(starred, app.id) && 0) || 1, app.name}
      end)

    assign(socket,
      starred: starred,
      all_tags: apps |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.sort(),
      apps: apps,
      trashed: Chat.list_trashed_apps(scope)
    )
  end

  defp filter_by_tag(items, nil), do: items
  defp filter_by_tag(items, tag), do: Enum.filter(items, &(tag in &1.tags))

  defp parse_tags(text) do
    text
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.slice(&1, 0, 40))
    |> Enum.uniq()
    |> Enum.take(10)
  end

  @impl true
  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    tag = ((tag == socket.assigns.tag_filter or tag == "") && nil) || tag
    {:noreply, assign(socket, tag_filter: tag)}
  end

  def handle_event("set_tags", %{"app-id" => id, "tags" => text}, socket) do
    scope = socket.assigns.current_scope

    with %{} = app <- Enum.find(socket.assigns.apps, &(&1.id == id)),
         {:ok, _updated} <- Chat.update_app(scope, app, %{"tags" => parse_tags(text)}) do
      {:noreply, socket |> put_flash(:info, "Tags saved.") |> load_apps()}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this app.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the tags.")}
    end
  end

  def handle_event("toggle_star", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account
    {:ok, _result} = Flux.Accounts.toggle_favorite(account, "app", id)
    {:noreply, load_apps(socket)}
  end

  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true, importing: false)}
  end

  def handle_event("importing", _params, socket) do
    {:noreply, assign(socket, importing: true, creating: false)}
  end

  def handle_event("import", %{"dsl" => dsl}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, %{attrs: attrs, warnings: warnings}} <- Flux.Workflows.DSL.parse_app(dsl),
         {:ok, app} <- Chat.create_app(scope, attrs) do
      socket =
        if warnings == [] do
          put_flash(socket, :info, "App \"#{app.name}\" imported.")
        else
          put_flash(socket, :info, "Imported with notes: #{Enum.join(warnings, " ")}")
        end

      {:noreply, push_navigate(socket, to: ~p"/console/apps/#{app.id}")}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "The DSL is missing required app fields.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create apps.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false, importing: false)}
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

  def handle_event("restore", %{"app-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.restore_app(scope, id) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "\"#{app.name}\" restored.")
         |> assign(apps: Chat.list_apps(scope), trashed: Chat.list_trashed_apps(scope))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not restore that app.")}
    end
  end

  def handle_event("purge", %{"app-id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Chat.purge_app(scope, id) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted forever.")
         |> assign(trashed: Chat.list_trashed_apps(scope))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not delete that app.")}
    end
  end

  def handle_event("duplicate", %{"app-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %App{} = app <- Chat.get_app(scope, id),
         {:ok, copy} <- Chat.duplicate_app(scope, app) do
      {:noreply,
       socket
       |> put_flash(:info, ~s("#{copy.name}" is ready.))
       |> assign(apps: Chat.list_apps(scope))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not duplicate that app.")}
    end
  end

  def handle_event("delete", %{"app-id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %App{} = app <- Chat.get_app(scope, id),
         {:ok, _} <- Chat.delete_app(scope, app) do
      {:noreply,
       socket
       |> put_flash(:info, "App moved to the trash.")
       |> assign(apps: Chat.list_apps(scope), trashed: Chat.list_trashed_apps(scope))}
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
          <h1 class="text-2xl font-bold">{gettext("Apps")}</h1>
          <p class="opacity-70 mt-1">
            {gettext("Chat applications backed by your configured models.")}
          </p>
        </div>
        <div class="flex gap-2">
          <button
            :if={@can_create and not @importing}
            class="btn btn-outline"
            phx-click="importing"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Import DSL
          </button>
          <button :if={@can_create and not @creating} class="btn btn-primary" phx-click="new">
            <.icon name="hero-plus" class="size-4" /> New app
          </button>
        </div>
      </div>

      <div :if={@importing} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Import an app DSL</h2>
        <form phx-submit="import" id="app-import-form" class="space-y-3">
          <textarea
            name="dsl"
            rows="8"
            placeholder="Paste a chat/completion app DSL export (kind: app, mode: chat)…"
            class="textarea textarea-bordered w-full font-mono text-xs"
          ></textarea>
          <div class="flex gap-2">
            <button class="btn btn-primary btn-sm">Import</button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">Cancel</button>
          </div>
        </form>
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
            options={[
              {"Chat — back-and-forth conversation", "chat"},
              {"Completion — one-shot text generation from a form", "completion"},
              {"Chatflow — conversation driven by a published flux", "advanced_chat"}
            ]}
          />
          <.input
            :if={to_string(@form[:mode].value) != "advanced_chat"}
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
            :if={to_string(@form[:mode].value) == "advanced_chat"}
            field={@form[:workflow_id]}
            type="select"
            label="Flux (must be published; each turn runs it with {{sys.query}})"
            options={for flux <- @fluxes, do: {flux.name, flux.id}}
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

      <Layouts.empty_state
        :if={@apps == [] and not @creating}
        icon="hero-chat-bubble-left-right"
        title="No apps yet"
      >
        <p>Create your first chat app to start talking to a model.</p>
      </Layouts.empty_state>

      <div :if={@all_tags != []} class="flex flex-wrap items-center gap-1" id="tag-filter">
        <span class="text-xs opacity-60">Tags:</span>
        <button
          :for={tag <- @all_tags}
          type="button"
          class={["btn btn-xs", (@tag_filter == tag && "btn-primary") || "btn-ghost"]}
          phx-click="filter_tag"
          phx-value-tag={tag}
        >
          {tag}
        </button>
        <button
          :if={@tag_filter}
          type="button"
          class="btn btn-ghost btn-xs opacity-60"
          phx-click="filter_tag"
          phx-value-tag=""
        >
          clear
        </button>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={app <- filter_by_tag(@apps, @tag_filter)}
          class="card border border-base-200 p-6 space-y-2"
          id={"app-#{app.id}"}
        >
          <div class="flex items-start justify-between">
            <h2 class="font-semibold">
              <span :if={app.icon} class="mr-1">{app.icon}</span>{app.name}
              <button
                class="btn btn-ghost btn-xs"
                phx-click="toggle_star"
                phx-value-id={app.id}
                aria-label="Star this app"
                title="Starred apps float to the top (just for you)"
              >
                {(MapSet.member?(@starred, app.id) && "★") || "☆"}
              </button>
            </h2>
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
          <form
            :if={@can_create}
            phx-submit="set_tags"
            id={"tags-#{app.id}"}
            class="flex items-center gap-1"
          >
            <input type="hidden" name="app-id" value={app.id} />
            <input
              type="text"
              name="tags"
              value={Enum.join(app.tags, ", ")}
              placeholder="tags, comma, separated"
              class="input input-bordered input-xs flex-1"
              title="Free-form labels; the chips above filter by them"
            />
            <button class="btn btn-ghost btn-xs">Tag</button>
          </form>
          <p class="text-xs opacity-60">
            <span class="badge badge-ghost badge-xs align-middle">{app.mode}</span>
            {(app.mode == :advanced_chat && "flux-driven") ||
              "#{app.provider_plugin_id} · #{app.model}"}
          </p>
          <p :if={app.description} class="text-sm opacity-70">{app.description}</p>
          <div class="flex gap-2">
            <.link navigate={~p"/console/apps/#{app.id}"} class="btn btn-sm btn-outline w-fit">
              {(app.mode == :completion && "Open app") || "Open chat"}
            </.link>
            <button
              :if={@can_create}
              class="btn btn-sm btn-ghost"
              phx-click="duplicate"
              phx-value-app-id={app.id}
              title="Copy this app's configuration into a new unpublished app"
            >
              ⧉ Duplicate
            </button>
          </div>
        </div>
      </div>

      <details :if={@trashed != []} class="card border border-base-200 p-4" id="app-trash">
        <summary class="cursor-pointer text-sm font-semibold">
          Trash ({length(@trashed)}) — purged after 30 days
        </summary>
        <div class="mt-2 space-y-2">
          <div
            :for={app <- @trashed}
            class="flex items-center gap-2 text-sm"
            id={"trashed-#{app.id}"}
          >
            <span>{app.name}</span>
            <span class="text-xs opacity-50">
              deleted {Calendar.strftime(app.deleted_at, "%Y-%m-%d %H:%M")}
            </span>
            <div :if={@can_create} class="ml-auto flex gap-1">
              <button class="btn btn-ghost btn-xs" phx-click="restore" phx-value-app-id={app.id}>
                Restore
              </button>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="purge"
                phx-value-app-id={app.id}
                data-confirm={"Delete #{app.name} forever? This cannot be undone."}
              >
                Delete forever
              </button>
            </div>
          </div>
        </div>
      </details>
    </Layouts.console>
    """
  end
end
