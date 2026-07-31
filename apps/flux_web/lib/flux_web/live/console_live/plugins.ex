defmodule FluxWeb.ConsoleLive.Plugins do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.Providers
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Plugins", editing: nil, form: nil)
     |> refresh()}
  end

  defp refresh(socket) do
    scope = socket.assigns.current_scope
    credentials = Providers.list_credentials(scope)

    assign(socket,
      plugins: Providers.list_provider_plugins(),
      credentials_by_plugin: Map.new(credentials, &{&1.plugin_id, &1}),
      can_manage: RBAC.can?(scope, :plugin_model_config),
      models: Providers.available_models(scope),
      default_model: Providers.default_model(scope)
    )
  end

  @impl true
  def handle_event("edit", %{"plugin-id" => plugin_id}, socket) do
    {:noreply, assign(socket, editing: plugin_id, form: to_form(%{}, as: :credentials))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("save", %{"credentials" => params}, socket) do
    plugin_id = socket.assigns.editing

    case Providers.upsert_credential(socket.assigns.current_scope, plugin_id, params) do
      {:ok, _credential} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credentials validated and saved.")
         |> assign(editing: nil, form: nil)
         |> refresh()}

      {:error, {:invalid_credentials, reason}} ->
        {:noreply, put_flash(socket, :error, "Validation failed: #{reason}")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not save credentials.")}
    end
  end

  def handle_event("set_default_model", %{"model_choice" => choice}, socket) do
    {plugin_id, model} =
      case String.split(choice, "|", parts: 2) do
        [plugin_id, model] -> {plugin_id, model}
        _cleared -> {"", ""}
      end

    case Providers.set_default_model(socket.assigns.current_scope, plugin_id, model) do
      {:ok, _workspace} ->
        {:noreply, socket |> put_flash(:info, "Default model saved.") |> refresh()}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to set the default model.")}
    end
  end

  def handle_event("remove", %{"credential-id" => id}, socket) do
    case Providers.delete_credential(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Credentials removed.") |> refresh()}
      _ -> {:noreply, put_flash(socket, :error, "Could not remove credentials.")}
    end
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
      <div>
        <h1 class="text-2xl font-bold">Plugins</h1>
        <p class="opacity-70 mt-1">
          Model providers available to this workspace. Configure credentials to unlock models.
        </p>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-3" id="default-model">
        <h2 class="font-semibold">Default model</h2>
        <p class="text-sm opacity-70">
          LLM and agent nodes that name no model fall back to this workspace default.
        </p>
        <form phx-change="set_default_model" id="default-model-form">
          <select name="model_choice" class="select select-bordered select-sm w-full max-w-md">
            <option value="" selected={@default_model == nil}>No default</option>
            <option
              :for={%{plugin_id: pid, plugin_name: pname, model: m} <- @models}
              value={"#{pid}|#{m.name}"}
              selected={
                @default_model != nil and
                  @default_model["provider_plugin_id"] == pid and
                  @default_model["model"] == m.name
              }
            >
              {pname} — {m.label}
            </option>
          </select>
        </form>
      </div>

      <div class="space-y-4">
        <div
          :for={plugin <- @plugins}
          class="card border border-base-200 p-6 space-y-3"
          id={"plugin-#{plugin.id}"}
        >
          <div class="flex items-center justify-between">
            <div>
              <h2 class="font-semibold flex items-center gap-2">
                {plugin.name}
                <span class="badge badge-ghost badge-sm">v{plugin.version}</span>
                <span
                  :if={@credentials_by_plugin[plugin.id] || plugin.credential_schema == []}
                  class="badge badge-success badge-sm"
                >
                  ready
                </span>
              </h2>
              <p class="text-sm opacity-70">{plugin.description}</p>
            </div>
            <div :if={@can_manage and plugin.credential_schema != []} class="flex gap-2">
              <button class="btn btn-sm" phx-click="edit" phx-value-plugin-id={plugin.id}>
                {if @credentials_by_plugin[plugin.id], do: "Update", else: "Configure"}
              </button>
              <button
                :if={credential = @credentials_by_plugin[plugin.id]}
                class="btn btn-sm btn-ghost text-error"
                phx-click="remove"
                phx-value-credential-id={credential.id}
                data-confirm="Remove these credentials?"
              >
                Remove
              </button>
            </div>
          </div>

          <.form
            :if={@editing == plugin.id}
            for={@form}
            id={"credentials-form-#{plugin.id}"}
            phx-submit="save"
            class="space-y-3 border-t border-base-200 pt-4"
          >
            <div :for={field <- plugin.credential_schema}>
              <.input
                field={@form[String.to_atom(field.key)]}
                name={"credentials[#{field.key}]"}
                type={if field.type == :secret, do: "password", else: "text"}
                label={field.label}
                placeholder={field.placeholder}
                required={field.required}
              />
              <p :if={field.help} class="text-xs opacity-60 mt-1">{field.help}</p>
            </div>
            <div class="flex gap-2">
              <button class="btn btn-primary btn-sm">Validate &amp; save</button>
              <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel">Cancel</button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.console>
    """
  end
end
