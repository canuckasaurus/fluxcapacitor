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
      # Datasource plugins with credential schemas (e.g. a feed URL) are
      # configured through the same credential store as model providers.
      plugins:
        Providers.list_provider_plugins() ++
          Enum.filter(plugin_runtime().list_datasource_plugins(), &(&1.credential_schema != [])),
      credentials_by_plugin: Enum.group_by(credentials, & &1.plugin_id),
      can_manage: RBAC.can?(scope, :plugin_model_config),
      can_install: RBAC.can?(scope, :plugin_install),
      installable_plugins:
        plugin_runtime().list_tool_plugins() ++ plugin_runtime().list_datasource_plugins(),
      installed_plugin_ids: MapSet.new(Flux.Tools.list_installed_plugin_ids(scope)),
      endpoint_tokens: endpoint_tokens(scope),
      models: Providers.available_models(scope),
      default_model: Providers.default_model(scope)
    )
  end

  defp plugin_runtime, do: Application.get_env(:flux, :plugin_runtime, Flux.PluginRuntime)

  # Installed plugins that serve HTTP → their /e/:token base URLs.
  defp endpoint_tokens(scope) do
    installed = MapSet.new(Flux.Tools.list_installed_plugin_ids(scope))

    for manifest <- plugin_runtime().list_endpoint_plugins(),
        MapSet.member?(installed, manifest.id),
        token = Flux.Tools.endpoint_token(scope, manifest.id),
        into: %{} do
      {manifest.id, token}
    end
  end

  @impl true
  def handle_event("edit", %{"plugin-id" => plugin_id}, socket) do
    {:noreply, assign(socket, editing: plugin_id, form: to_form(%{}, as: :credentials))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form: nil)}
  end

  def handle_event("save", %{"credentials" => config} = params, socket) do
    plugin_id = socket.assigns.editing

    case Providers.upsert_credential(
           socket.assigns.current_scope,
           plugin_id,
           config,
           params["credential_name"]
         ) do
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

  def handle_event("install_plugin", %{"plugin-id" => plugin_id}, socket) do
    case Flux.Tools.install_plugin(socket.assigns.current_scope, plugin_id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Plugin installed.") |> refresh()}
      _error -> {:noreply, put_flash(socket, :error, "Could not install the plugin.")}
    end
  end

  def handle_event("uninstall_plugin", %{"plugin-id" => plugin_id}, socket) do
    case Flux.Tools.uninstall_plugin(socket.assigns.current_scope, plugin_id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Plugin uninstalled.") |> refresh()}
      _error -> {:noreply, put_flash(socket, :error, "Could not uninstall the plugin.")}
    end
  end

  def handle_event("remove", %{"credential-id" => id}, socket) do
    case Providers.delete_credential(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Credentials removed.") |> refresh()}
      _ -> {:noreply, put_flash(socket, :error, "Could not remove credentials.")}
    end
  end

  def handle_event("revalidate", %{"credential-id" => id}, socket) do
    case Providers.validate_credential(socket.assigns.current_scope, id) do
      {:ok, _credential} ->
        {:noreply, socket |> put_flash(:info, "The key works — validated just now.") |> refresh()}

      {:error, {:invalid_credentials, reason}} ->
        {:noreply, put_flash(socket, :error, "The provider rejected the key: #{reason}")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not test that key.")}
    end
  end

  def handle_event("make_default", %{"credential-id" => id}, socket) do
    case Providers.set_default_credential(socket.assigns.current_scope, id) do
      :ok -> {:noreply, socket |> put_flash(:info, "Default credential set.") |> refresh()}
      _error -> {:noreply, put_flash(socket, :error, "Could not set the default.")}
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
        <h1 class="text-2xl font-bold">{gettext("Plugins")}</h1>

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

      <div :if={@installable_plugins != []} class="card border border-base-200 p-6 space-y-3">
        <h2 class="font-semibold">Tool &amp; datasource plugins</h2>

        <p class="text-sm opacity-70">
          Installed tool plugins appear as toolsets in tool and agent nodes;
          installed datasources can sync documents into knowledge datasets.
        </p>

        <div
          :for={plugin <- @installable_plugins}
          class="flex items-center gap-3"
          id={"tool-plugin-#{plugin.id}"}
        >
          <div class="flex-1">
            <p class="font-semibold text-sm">
              {plugin.name}
              <span class="badge badge-ghost badge-xs align-middle">{plugin.category}</span>
            </p>

            <p class="text-xs opacity-70">{plugin.description}</p>
            <pre
              :if={token = @endpoint_tokens[plugin.id]}
              class="mt-1 rounded bg-base-200 px-2 py-1 text-xs overflow-x-auto"
            >{url(~p"/e/#{token}")}</pre>
          </div>

          <span
            :if={MapSet.member?(@installed_plugin_ids, plugin.id)}
            class="badge badge-success badge-sm"
          >
            installed
          </span>
          <button
            :if={@can_install and not MapSet.member?(@installed_plugin_ids, plugin.id)}
            class="btn btn-sm btn-primary"
            phx-click="install_plugin"
            phx-value-plugin-id={plugin.id}
          >
            Install
          </button>
          <button
            :if={@can_install and MapSet.member?(@installed_plugin_ids, plugin.id)}
            class="btn btn-sm btn-ghost text-error"
            phx-click="uninstall_plugin"
            phx-value-plugin-id={plugin.id}
          >
            Uninstall
          </button>
        </div>
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
                {plugin.name} <span class="badge badge-ghost badge-sm">v{plugin.version}</span>
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
                {if @credentials_by_plugin[plugin.id], do: "Add key", else: "Configure"}
              </button>
            </div>
          </div>

          <div :if={credentials = @credentials_by_plugin[plugin.id]} class="space-y-1">
            <div
              :for={credential <- credentials}
              class="flex items-center gap-2 text-sm"
              id={"credential-#{credential.id}"}
            >
              <span class="font-mono text-xs">{credential.name}</span>
              <span :if={credential.is_default} class="badge badge-primary badge-xs">default</span>
              <span :if={credential.validated_at} class="text-xs opacity-50">
                validated {Calendar.strftime(credential.validated_at, "%Y-%m-%d")}
              </span>
              <div :if={@can_manage} class="ml-auto flex gap-1">
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="revalidate"
                  phx-value-credential-id={credential.id}
                  title="Test this key against the provider right now"
                >
                  Test
                </button>
                <button
                  :if={not credential.is_default}
                  class="btn btn-ghost btn-xs"
                  phx-click="make_default"
                  phx-value-credential-id={credential.id}
                >
                  Make default
                </button>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="remove"
                  phx-value-credential-id={credential.id}
                  data-confirm={"Remove the #{credential.name} key?"}
                >
                  Remove
                </button>
              </div>
            </div>
          </div>

          <.form
            :if={@editing == plugin.id}
            for={@form}
            id={"credentials-form-#{plugin.id}"}
            phx-submit="save"
            class="space-y-3 border-t border-base-200 pt-4"
          >
            <.input
              name="credential_name"
              value="default"
              type="text"
              label="Key name (several keys can coexist — rotate without downtime)"
            />
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
