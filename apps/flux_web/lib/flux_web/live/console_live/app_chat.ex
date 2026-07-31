defmodule FluxWeb.ConsoleLive.AppChat do
  @moduledoc false
  use FluxWeb, :live_view

  alias Flux.Chat
  alias Flux.Chat.App
  alias Flux.RBAC

  @impl true
  def mount(%{"id" => app_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Chat.get_app(scope, app_id) do
      %App{} = app ->
        {:ok,
         assign(socket,
           page_title: app.name,
           app: app,
           conversation: nil,
           messages: [],
           streaming_id: nil,
           streaming_text: "",
           api_tokens: Chat.list_api_tokens(scope, app.id),
           new_token: nil,
           can_manage: RBAC.can?(scope, :app_create_and_management),
           can_edit: RBAC.can?(scope, :app_edit),
           var_rows: app.input_form,
           template_draft: app.prompt_template
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "App not found.")
         |> push_navigate(to: ~p"/console/apps")}
    end
  end

  @impl true
  def handle_event("send", %{"content" => content}, socket) when content != "" do
    scope = socket.assigns.current_scope
    app = socket.assigns.app

    conversation =
      socket.assigns.conversation || Chat.create_conversation(scope, app)

    {:ok, user_message, assistant_message} =
      Chat.send_message(scope, app, conversation, content)

    {:noreply,
     assign(socket,
       conversation: conversation,
       messages: socket.assigns.messages ++ [user_message],
       streaming_id: assistant_message.id,
       streaming_text: ""
     )}
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  def handle_event("stop", _params, socket) do
    if id = socket.assigns.streaming_id do
      Chat.stop_generation(socket.assigns.current_scope, id)
    end

    {:noreply, socket}
  end

  def handle_event("new-conversation", _params, socket) do
    {:noreply,
     assign(socket, conversation: nil, messages: [], streaming_id: nil, streaming_text: "")}
  end

  ## Completion apps: run panel + configuration

  def handle_event("run_completion", params, socket) do
    scope = socket.assigns.current_scope

    case Chat.send_completion(scope, socket.assigns.app, params["inputs"] || %{}) do
      {:ok, conversation, _user_message, assistant_message} ->
        {:noreply,
         assign(socket,
           conversation: conversation,
           messages: [],
           streaming_id: assistant_message.id,
           streaming_text: ""
         )}

      {:error, :not_completion_app} ->
        {:noreply, put_flash(socket, :error, "This app is not in completion mode.")}
    end
  end

  def handle_event("add_var", _params, socket) do
    {:noreply,
     assign(socket,
       var_rows: socket.assigns.var_rows ++ [%{"type" => "text-input", "required" => false}]
     )}
  end

  def handle_event("remove_var", %{"index" => index}, socket) do
    {:noreply,
     assign(socket,
       var_rows: List.delete_at(socket.assigns.var_rows, String.to_integer(index))
     )}
  end

  def handle_event("settings_change", params, socket) do
    {:noreply,
     assign(socket, template_draft: params["prompt_template"], var_rows: parse_var_rows(params))}
  end

  def handle_event("save_settings", params, socket) do
    scope = socket.assigns.current_scope

    rows =
      params
      |> parse_var_rows()
      |> Enum.reject(&(&1["variable"] == ""))

    case Chat.update_app(scope, socket.assigns.app, %{
           "prompt_template" => params["prompt_template"],
           "input_form" => rows
         }) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "Configuration saved.")
         |> assign(app: app, var_rows: app.input_form, template_draft: app.prompt_template)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this app.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not save the configuration.")}
    end
  end

  def handle_event("enable_site", _params, socket) do
    case Chat.enable_site(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, app} ->
        {:noreply, assign(socket, app: app)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to publish this app.")}
    end
  end

  def handle_event("disable_site", _params, socket) do
    case Chat.disable_site(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, app} ->
        {:noreply, assign(socket, app: app)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to unpublish this app.")}
    end
  end

  def handle_event("create-token", _params, socket) do
    case Chat.create_api_token(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, _token, raw} ->
        {:noreply,
         assign(socket,
           new_token: raw,
           api_tokens: Chat.list_api_tokens(socket.assigns.current_scope, socket.assigns.app.id)
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage API keys.")}
    end
  end

  def handle_event("revoke-token", %{"token-id" => id}, socket) do
    Chat.revoke_api_token(socket.assigns.current_scope, id)

    {:noreply,
     assign(socket,
       api_tokens: Chat.list_api_tokens(socket.assigns.current_scope, socket.assigns.app.id)
     )}
  end

  @impl true
  def handle_info({:chunk, delta}, socket) do
    {:noreply, assign(socket, streaming_text: socket.assigns.streaming_text <> delta)}
  end

  def handle_info({:done, message}, socket) do
    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [message],
       streaming_id: nil,
       streaming_text: ""
     )}
  end

  def handle_info({:error, message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, message.error || "Generation failed.")
     |> assign(
       messages: socket.assigns.messages ++ [message],
       streaming_id: nil,
       streaming_text: ""
     )}
  end

  defp parse_var_rows(%{"vars" => vars}) when is_map(vars) do
    vars
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} ->
      %{
        "variable" => String.trim(row["variable"] || ""),
        "label" => row["label"] || "",
        "type" => row["type"] || "text-input",
        "required" => row["required"] == "true"
      }
    end)
  end

  defp parse_var_rows(_params), do: []

  defp embed_snippet(app) do
    ~s(<iframe src="#{url(~p"/site/#{app.site_token}")}"\n  style="width: 100%; height: 640px; border: 0; border-radius: 12px;"\n  allow="clipboard-write"></iframe>)
  end

  defp bubble_snippet(site_token) do
    ~s(<script src="#{url(~p"/embed.js")}"\n  data-flux-site="#{url(~p"/site/#{site_token}")}" defer></script>)
  end

  defp completion_output(messages) do
    case List.last(messages) do
      %{role: :assistant, status: :error, error: error} -> error
      %{role: :assistant, content: content} -> content
      _no_output_yet -> nil
    end
  end

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
          <h1 class="text-2xl font-bold">{@app.name}</h1>
          <p class="opacity-60 text-sm">{@app.provider_plugin_id} · {@app.model}</p>
        </div>
        <div class="flex gap-2">
          <button :if={@app.mode == :chat} class="btn btn-sm btn-ghost" phx-click="new-conversation">
            New conversation
          </button>
          <.link navigate={~p"/console/apps"} class="btn btn-sm btn-ghost">&larr; All apps</.link>
        </div>
      </div>

      <div :if={@app.mode == :chat} class="card border border-base-200 p-6 space-y-4">
        <div id="chat-messages" class="space-y-3 max-h-[28rem] overflow-y-auto">
          <p :if={@messages == [] and @streaming_id == nil} class="text-sm opacity-60">
            Say something to start the conversation.
          </p>
          <div
            :for={message <- @messages}
            class={["chat", (message.role == :user && "chat-end") || "chat-start"]}
            id={"message-#{message.id}"}
          >
            <div class={[
              "chat-bubble whitespace-pre-wrap",
              message.role == :user && "chat-bubble-primary",
              message.status == :error && "chat-bubble-error"
            ]}>
              {if message.status == :error, do: message.error, else: message.content}
            </div>
          </div>
          <div :if={@streaming_id} class="chat chat-start" id="streaming-bubble">
            <div class="chat-bubble whitespace-pre-wrap">
              {@streaming_text}<span class="animate-pulse">▌</span>
            </div>
          </div>
        </div>

        <form phx-submit="send" class="flex gap-2" id="chat-form">
          <input
            type="text"
            name="content"
            autocomplete="off"
            placeholder="Type a message…"
            class="input input-bordered flex-1"
            disabled={@streaming_id != nil}
          />
          <button :if={@streaming_id == nil} class="btn btn-primary">Send</button>
          <button :if={@streaming_id} type="button" class="btn btn-warning" phx-click="stop">
            Stop
          </button>
        </form>
      </div>

      <div :if={@app.mode == :completion} class="card border border-base-200 p-6 space-y-4">
        <h2 class="font-semibold">Run</h2>
        <form phx-submit="run_completion" id="completion-form" class="space-y-3">
          <p :if={@app.input_form == []} class="text-sm opacity-60">
            No form variables defined — the prompt template runs as-is.
          </p>
          <div :for={field <- @app.input_form} class="form-control">
            <label class="label-text text-sm mb-1">
              {(field["label"] != "" && field["label"]) || field["variable"]}
              <span :if={field["required"]} class="text-error">*</span>
            </label>
            <textarea
              :if={field["type"] == "paragraph"}
              name={"inputs[#{field["variable"]}]"}
              rows="3"
              required={field["required"] == true}
              class="textarea textarea-bordered w-full"
            ></textarea>
            <input
              :if={field["type"] == "number"}
              type="number"
              name={"inputs[#{field["variable"]}]"}
              required={field["required"] == true}
              class="input input-bordered w-full"
            />
            <input
              :if={field["type"] not in ["paragraph", "number"]}
              type="text"
              name={"inputs[#{field["variable"]}]"}
              required={field["required"] == true}
              class="input input-bordered w-full"
            />
          </div>
          <div class="flex gap-2">
            <button :if={@streaming_id == nil} class="btn btn-primary btn-sm">
              <.icon name="hero-play" class="size-4" /> Run
            </button>
            <button :if={@streaming_id} type="button" class="btn btn-warning btn-sm" phx-click="stop">
              Stop
            </button>
          </div>
        </form>

        <div
          :if={@streaming_id != nil or completion_output(@messages) != nil}
          id="completion-output"
          class="rounded-box bg-base-200 p-4 text-sm whitespace-pre-wrap"
        >
          {(@streaming_id && @streaming_text) || completion_output(@messages)}
          <span :if={@streaming_id} class="animate-pulse">▌</span>
        </div>
      </div>

      <div
        :if={@app.mode == :completion and @can_edit}
        class="card border border-base-200 p-6 space-y-3"
      >
        <h2 class="font-semibold">Configuration</h2>
        <form
          id="settings-form"
          phx-submit="save_settings"
          phx-change="settings_change"
          class="space-y-3"
        >
          <label class="form-control block">
            <span class="label-text text-sm mb-1">
              Prompt template — reference variables as <code>{"{{inputs.name}}"}</code>
            </span>
            <textarea
              name="prompt_template"
              rows="3"
              placeholder="Summarize the following text: {{inputs.text}}"
              class="textarea textarea-bordered w-full font-mono"
            >{@template_draft}</textarea>
          </label>

          <p class="text-sm font-semibold">Form variables</p>
          <div
            :for={{row, index} <- Enum.with_index(@var_rows)}
            class="flex items-center gap-2 flex-wrap"
            id={"var-row-#{index}"}
          >
            <input
              type="text"
              name={"vars[#{index}][variable]"}
              value={row["variable"]}
              placeholder="variable"
              class="input input-bordered input-sm font-mono w-36"
            />
            <input
              type="text"
              name={"vars[#{index}][label]"}
              value={row["label"]}
              placeholder="Label"
              class="input input-bordered input-sm flex-1 min-w-32"
            />
            <select name={"vars[#{index}][type]"} class="select select-bordered select-sm w-32">
              <option value="text-input" selected={row["type"] in [nil, "", "text-input"]}>
                Text
              </option>
              <option value="paragraph" selected={row["type"] == "paragraph"}>Paragraph</option>
              <option value="number" selected={row["type"] == "number"}>Number</option>
            </select>
            <label class="flex items-center gap-1 text-xs">
              <input type="hidden" name={"vars[#{index}][required]"} value="false" />
              <input
                type="checkbox"
                name={"vars[#{index}][required]"}
                value="true"
                checked={row["required"] == true}
                class="checkbox checkbox-xs"
              /> required
            </label>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              phx-click="remove_var"
              phx-value-index={index}
            >
              <.icon name="hero-x-mark" class="size-3" />
            </button>
          </div>

          <div class="flex gap-2">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="add_var">
              <.icon name="hero-plus" class="size-4" /> Add variable
            </button>
            <button type="submit" class="btn btn-primary btn-sm">Save configuration</button>
          </div>
        </form>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-3" id="site-publishing">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">Site publishing</h2>
          <button
            :if={not @app.site_enabled}
            class="btn btn-sm btn-primary"
            phx-click="enable_site"
          >
            <.icon name="hero-globe-alt" class="size-4" /> Publish site
          </button>
          <button
            :if={@app.site_enabled}
            class="btn btn-sm btn-ghost text-error"
            phx-click="disable_site"
            data-confirm="Unpublish the public site?"
          >
            Unpublish
          </button>
        </div>
        <p :if={not @app.site_enabled} class="text-sm opacity-60">
          Publish this app at a public URL anyone can use — no login required.
        </p>
        <div :if={@app.site_enabled} class="space-y-2">
          <p class="text-sm">
            Live at
            <a
              href={url(~p"/site/#{@app.site_token}")}
              target="_blank"
              class="link link-primary font-mono text-xs"
            >
              {url(~p"/site/#{@app.site_token}")}
            </a>
          </p>
          <p class="text-xs opacity-60">Embed it on any page:</p>
          <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{embed_snippet(@app)}</pre>
          <p class="text-xs opacity-60">Or as a floating chat bubble:</p>
          <pre class="rounded-box bg-base-200 p-3 text-xs overflow-x-auto">{bubble_snippet(@app.site_token)}</pre>
        </div>
      </div>

      <div :if={@can_manage} class="card border border-base-200 p-6 space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="font-semibold">API keys</h2>
          <button class="btn btn-sm" phx-click="create-token">Create key</button>
        </div>
        <div :if={@new_token} class="alert alert-info text-sm">
          <span>
            Copy this key now — it won't be shown again:
            <code class="font-mono select-all">{@new_token}</code>
          </span>
        </div>
        <table :if={@api_tokens != []} class="table table-sm">
          <thead>
            <tr>
              <th>Key</th>
              <th>Last used</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @api_tokens} id={"token-#{token.id}"}>
              <td class="font-mono">{token.prefix}</td>
              <td class="text-sm opacity-70">
                {if token.last_used_at,
                  do: Calendar.strftime(token.last_used_at, "%b %d %H:%M"),
                  else: "never"}
              </td>
              <td class="text-right">
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="revoke-token"
                  phx-value-token-id={token.id}
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <p class="text-xs opacity-60">
          Use with
          <code>
            POST {(@app.mode == :completion && "/v1/completion-messages") || "/v1/chat-messages"}
          </code>
          and header <code>Authorization: Bearer app-…</code>
        </p>
      </div>
    </Layouts.console>
    """
  end
end
