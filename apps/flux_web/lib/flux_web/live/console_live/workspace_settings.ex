defmodule FluxWeb.ConsoleLive.WorkspaceSettings do
  @moduledoc "Workspace settings: rename, default model, danger zone."
  use FluxWeb, :live_view

  alias Flux.Accounts
  alias Flux.Chat
  alias Flux.Providers
  alias Flux.RBAC

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     assign(socket,
       page_title: "Workspace settings",
       can_rename: RBAC.can?(scope, :customization_manage),
       can_model: RBAC.can?(scope, :plugin_model_config),
       owner?: Flux.Accounts.Scope.role(scope) == :owner,
       models: Providers.available_models(scope),
       default_model: Providers.default_model(scope),
       retention_days: Accounts.retention_days(scope),
       export_schedule: Accounts.export_schedule(scope),
       token_budget: Accounts.token_budget(scope),
       llm_cache_minutes: Accounts.llm_cache_minutes(scope),
       pricing_overrides:
         Flux.Pricing.overrides(Flux.Accounts.Scope.workspace_id(scope)) |> Enum.sort(),
       max_concurrent_runs: Accounts.max_concurrent_runs(scope),
       guardrails: Flux.Guardrails.config(Flux.Accounts.Scope.workspace_id(scope)),
       moderation: Flux.Guardrails.moderation_config(Flux.Accounts.Scope.workspace_id(scope)),
       alert_url: Accounts.alert_url(scope),
       alert_secret: Accounts.alert_secret(scope),
       can_webhooks: RBAC.can?(scope, :api_extension_manage),
       webhooks: Flux.Webhooks.list_endpoints(scope),
       webhook_deliveries: Flux.Webhooks.list_deliveries(scope, 25),
       can_api_keys: RBAC.can?(scope, :app_create_and_management),
       ws_tokens: Chat.list_workspace_tokens(scope),
       new_ws_token: nil,
       can_scim: RBAC.can?(scope, :workspace_member_manage),
       scim_enabled: Accounts.scim_enabled?(scope),
       scim_token: nil,
       plan: Flux.Features.plan(scope)
     )}
  end

  @impl true
  def handle_event("rename", %{"name" => name}, socket) do
    case Accounts.rename_workspace(socket.assigns.current_scope, name) do
      {:ok, workspace} ->
        scope = %{socket.assigns.current_scope | workspace: workspace}

        {:noreply,
         socket
         |> put_flash(:info, "Workspace renamed.")
         |> assign(current_scope: scope)}

      {:error, :invalid_name} ->
        {:noreply, put_flash(socket, :error, "Enter a workspace name.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to rename.")}
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
        {:noreply,
         socket
         |> put_flash(:info, "Default model saved.")
         |> assign(default_model: Providers.default_model(socket.assigns.current_scope))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to set the default.")}
    end
  end

  def handle_event("set_budget", %{"tokens" => tokens}, socket) do
    parsed =
      case Integer.parse(tokens) do
        {n, ""} when n > 0 -> n
        _blank_or_invalid -> nil
      end

    case Accounts.set_token_budget(socket.assigns.current_scope, parsed) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, (parsed && "Budget set.") || "Budget removed.")
         |> assign(token_budget: parsed)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the budget.")}
    end
  end

  def handle_event("set_guardrails", %{"patterns" => patterns, "action" => action}, socket) do
    case Flux.Guardrails.configure(socket.assigns.current_scope, patterns, action) do
      {:ok, _workspace} ->
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Guardrails saved.")
         |> assign(guardrails: Flux.Guardrails.config(workspace_id))}

      {:error, {:invalid_pattern, pattern}} ->
        {:noreply, put_flash(socket, :error, "Invalid regex: #{pattern}")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the guardrails.")}
    end
  end

  def handle_event("set_pricing", %{"pricing" => pricing}, socket) do
    case Flux.Pricing.configure_overrides(socket.assigns.current_scope, pricing) do
      {:ok, _workspace} ->
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Model prices saved.")
         |> assign(pricing_overrides: Flux.Pricing.overrides(workspace_id) |> Enum.sort())}

      {:error, {:invalid_line, line}} ->
        {:noreply, put_flash(socket, :error, "Couldn't parse: #{line}")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the prices.")}
    end
  end

  def handle_event("set_moderation", %{"policy" => policy, "action" => action}, socket) do
    case Flux.Guardrails.configure_moderation(socket.assigns.current_scope, policy, action) do
      {:ok, _workspace} ->
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Moderation saved.")
         |> assign(moderation: Flux.Guardrails.moderation_config(workspace_id))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the moderation policy.")}
    end
  end

  def handle_event("set_concurrency", %{"cap" => cap}, socket) do
    parsed =
      case Integer.parse(cap) do
        {n, ""} when n in 1..1000 -> n
        _blank_or_invalid -> nil
      end

    case Accounts.set_max_concurrent_runs(socket.assigns.current_scope, parsed) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, (parsed && "Concurrency cap set.") || "Concurrency cap removed.")
         |> assign(max_concurrent_runs: parsed)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the cap.")}
    end
  end

  def handle_event("set_llm_cache", %{"minutes" => minutes}, socket) do
    parsed =
      case Integer.parse(minutes) do
        {n, ""} when n >= 0 -> n
        _invalid -> 0
      end

    case Accounts.set_llm_cache_minutes(socket.assigns.current_scope, parsed) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, (parsed > 0 && "LLM cache on.") || "LLM cache off.")
         |> assign(llm_cache_minutes: parsed)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the cache setting.")}
    end
  end

  def handle_event("set_export_schedule", %{"cron" => cron}, socket) do
    case Accounts.set_export_schedule(socket.assigns.current_scope, cron) do
      {:ok, _workspace} ->
        cron = String.trim(cron)

        {:noreply,
         socket
         |> put_flash(
           :info,
           (cron == "" && "Scheduled backups off.") ||
             "Backups scheduled — archives land on the Files page."
         )
         |> assign(export_schedule: (cron == "" && nil) || cron)}

      {:error, :invalid_cron} ->
        {:noreply, put_flash(socket, :error, "That isn't a valid cron expression.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the schedule.")}
    end
  end

  def handle_event("set_retention", %{"days" => days}, socket) do
    parsed =
      case Integer.parse(String.trim(days)) do
        {n, ""} when n in 1..3650 -> n
        _blank_or_invalid -> nil
      end

    case Accounts.set_retention_days(socket.assigns.current_scope, parsed) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, (parsed && "Retention set to #{parsed} days.") || "Retention off.")
         |> assign(retention_days: parsed)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to change retention.")}
    end
  end

  def handle_event("set_plan", %{"plan" => plan}, socket) do
    case Flux.Features.set_plan(socket.assigns.current_scope, plan) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Plan set to #{plan}.")
         |> assign(plan: plan)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only the owner can change the plan.")}

      {:error, :unknown_plan} ->
        {:noreply, put_flash(socket, :error, "Unknown plan.")}
    end
  end

  def handle_event("create_ws_token", %{"expires_in_days" => days}, socket) do
    expires_in_days =
      case Integer.parse(days) do
        {n, ""} when n > 0 -> n
        _never -> nil
      end

    case Chat.create_workspace_token(socket.assigns.current_scope,
           expires_in_days: expires_in_days
         ) do
      {:ok, _token, raw} ->
        {:noreply,
         assign(socket,
           new_ws_token: raw,
           ws_tokens: Chat.list_workspace_tokens(socket.assigns.current_scope)
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to mint API keys.")}
    end
  end

  def handle_event("revoke_ws_token", %{"id" => id}, socket) do
    Chat.revoke_api_token(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> put_flash(:info, "API key revoked.")
     |> assign(ws_tokens: Chat.list_workspace_tokens(socket.assigns.current_scope))}
  end

  def handle_event("enable_scim", _params, socket) do
    case Accounts.enable_scim(socket.assigns.current_scope) do
      {:ok, raw} ->
        {:noreply, assign(socket, scim_enabled: true, scim_token: raw)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage SCIM.")}
    end
  end

  def handle_event("disable_scim", _params, socket) do
    case Accounts.disable_scim(socket.assigns.current_scope) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "SCIM disabled — the token no longer works.")
         |> assign(scim_enabled: false, scim_token: nil)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage SCIM.")}
    end
  end

  def handle_event("set_alert_url", %{"url" => url}, socket) do
    case Accounts.set_alert_url(socket.assigns.current_scope, url) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alert webhook saved.")
         |> assign(
           alert_url: Accounts.alert_url(socket.assigns.current_scope),
           alert_secret: Accounts.alert_secret(socket.assigns.current_scope)
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to change alerts.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("add_webhook", params, socket) do
    attrs = %{"url" => params["url"], "events" => Map.get(params, "events", [])}

    case Flux.Webhooks.create_endpoint(socket.assigns.current_scope, attrs) do
      {:ok, _endpoint} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook added.")
         |> assign(webhooks: Flux.Webhooks.list_endpoints(socket.assigns.current_scope))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage webhooks.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {field, {message, _meta}} = List.first(changeset.errors)
        {:noreply, put_flash(socket, :error, "#{field} #{message}")}
    end
  end

  def handle_event("toggle_webhook", %{"id" => id}, socket) do
    endpoint = Enum.find(socket.assigns.webhooks, &(&1.id == id))

    with %{} <- endpoint,
         {:ok, _updated} <-
           Flux.Webhooks.update_endpoint(socket.assigns.current_scope, id, %{
             "enabled" => !endpoint.enabled
           }) do
      {:noreply,
       assign(socket, webhooks: Flux.Webhooks.list_endpoints(socket.assigns.current_scope))}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not update the webhook.")}
    end
  end

  def handle_event("retry_delivery", %{"id" => id}, socket) do
    case Flux.Webhooks.retry_delivery(socket.assigns.current_scope, id) do
      {:ok, _delivery} ->
        {:noreply,
         socket
         |> put_flash(:info, "Delivery re-queued.")
         |> assign(
           webhook_deliveries: Flux.Webhooks.list_deliveries(socket.assigns.current_scope, 25)
         )}

      {:error, :endpoint_gone} ->
        {:noreply, put_flash(socket, :error, "That endpoint no longer exists.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not retry the delivery.")}
    end
  end

  def handle_event("test_webhook", %{"id" => id}, socket) do
    case Flux.Webhooks.send_test(socket.assigns.current_scope, id) do
      {:ok, status} ->
        {:noreply,
         put_flash(socket, :info, "Test event sent — the endpoint answered HTTP #{status}.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, "Test failed: #{message}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not send the test event.")}
    end
  end

  def handle_event("delete_webhook", %{"id" => id}, socket) do
    case Flux.Webhooks.delete_endpoint(socket.assigns.current_scope, id) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook removed.")
         |> assign(webhooks: Flux.Webhooks.list_endpoints(socket.assigns.current_scope))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not remove the webhook.")}
    end
  end

  def handle_event("delete_workspace", %{"confirm" => confirm}, socket) do
    workspace = socket.assigns.current_scope.workspace

    cond do
      confirm != workspace.name ->
        {:noreply, put_flash(socket, :error, "Type the workspace name exactly to confirm.")}

      true ->
        case Accounts.delete_workspace(socket.assigns.current_scope) do
          {:ok, _workspace} ->
            {:noreply,
             socket
             |> put_flash(:info, "Workspace deleted.")
             |> redirect(to: ~p"/console")}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "Only the owner can delete the workspace.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:settings}
    >
      <div>
        <h1 class="text-2xl font-bold">{gettext("Workspace settings")}</h1>

        <p class="opacity-70 mt-1">{@current_scope.workspace.name}</p>

        <div class="mt-3 flex flex-wrap gap-1">
          <a :if={@can_rename} href="#name-card" class="badge badge-ghost badge-sm">Name</a>
          <a :if={@can_model} href="#model-card" class="badge badge-ghost badge-sm">Default model</a>
          <a :if={@can_rename} href="#retention-card" class="badge badge-ghost badge-sm">Retention</a>
          <a :if={@can_rename} href="#alerts-card" class="badge badge-ghost badge-sm">Alerts</a>
          <a :if={@can_api_keys} href="#api-keys-card" class="badge badge-ghost badge-sm">
            API keys
          </a>
          <a :if={@can_rename} href="#export-card" class="badge badge-ghost badge-sm">
            Export / Import
          </a>
          <a :if={@owner?} href="#plan-card" class="badge badge-ghost badge-sm">Plan</a>
          <a :if={@can_scim} href="#scim-card" class="badge badge-ghost badge-sm">SCIM</a>
          <a :if={@owner?} href="#danger-card" class="badge badge-ghost badge-sm text-error">
            Danger zone
          </a>
        </div>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="name-card">
        <h2 class="font-semibold">Name</h2>

        <form phx-submit="rename" id="rename-form" class="flex gap-2">
          <input
            type="text"
            name="name"
            value={@current_scope.workspace.name}
            required
            class="input input-bordered w-full max-w-md"
          /> <button class="btn btn-primary">Rename</button>
        </form>
      </div>

      <div :if={@can_model} class="card border border-base-200 p-6 space-y-3" id="model-card">
        <h2 class="font-semibold">Default model</h2>

        <p class="text-sm opacity-70">LLM and agent nodes that name no model fall back to this.</p>

        <form phx-change="set_default_model" id="settings-default-model-form">
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

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="retention-card">
        <h2 class="font-semibold">Data retention</h2>

        <p class="text-sm opacity-70">
          Runs and chat messages older than this are pruned nightly. Blank keeps
          everything forever; conversations and the audit trail are never pruned.
        </p>

        <form phx-submit="set_retention" id="retention-form" class="flex gap-2 items-center">
          <input
            type="number"
            name="days"
            value={@retention_days}
            min="1"
            max="3650"
            placeholder="∞"
            class="input input-bordered input-sm w-28"
          /> <span class="text-sm opacity-70">days</span>
          <button class="btn btn-primary btn-sm">Save</button>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="cost-card">
        <h2 class="font-semibold">Cost controls</h2>

        <p class="text-sm opacity-70">
          A monthly token budget warns at 80% and refuses new runs past the
          cap (blank = unlimited). The LLM cache returns identical prompts
          from memory within the TTL — repeated batch and eval runs stop
          paying twice (0 = off).
        </p>

        <form phx-submit="set_budget" id="budget-form" class="flex gap-2 items-center">
          <input
            type="number"
            name="tokens"
            value={@token_budget}
            min="1"
            placeholder="∞"
            class="input input-bordered input-sm w-40"
          /> <span class="text-sm opacity-70">tokens / month</span>
          <button class="btn btn-primary btn-sm">Save</button>
        </form>

        <form phx-submit="set_concurrency" id="concurrency-form" class="flex gap-2 items-center">
          <input
            type="number"
            name="cap"
            value={@max_concurrent_runs}
            min="1"
            max="1000"
            placeholder="∞"
            class="input input-bordered input-sm w-40"
            title="Interactive runs beyond this refuse until others finish; batches and evals are exempt (they run sequentially)."
          /> <span class="text-sm opacity-70">concurrent runs</span>
          <button class="btn btn-primary btn-sm">Save</button>
        </form>

        <form phx-submit="set_llm_cache" id="llm-cache-form" class="flex gap-2 items-center">
          <input
            type="number"
            name="minutes"
            value={@llm_cache_minutes}
            min="0"
            max="10080"
            class="input input-bordered input-sm w-40"
          /> <span class="text-sm opacity-70">cache minutes</span>
          <button class="btn btn-primary btn-sm">Save</button>
        </form>

        <div class="divider my-1" />

        <h3 class="text-sm font-semibold">Model price overrides</h3>
        <p class="text-sm opacity-70">
          One per line: <span class="font-mono text-xs">model-prefix $in/M $out/M</span>
          — prices your self-hosted or fine-tuned models so cost rollups
          stop reading $0. Overrides beat the built-in table on prefix
          match; blank clears.
        </p>
        <form phx-submit="set_pricing" id="pricing-form" class="space-y-2">
          <textarea
            name="pricing"
            rows="3"
            placeholder="my-finetune 2.0 8.0"
            class="textarea textarea-bordered textarea-sm w-full max-w-md font-mono"
          >{Enum.map_join(@pricing_overrides, "\n", fn {model, [input, output]} -> "#{model} #{input} #{output}" end)}</textarea>
          <button class="btn btn-primary btn-sm">Save prices</button>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="guardrails-card">
        <h2 class="font-semibold">Guardrails</h2>

        <p class="text-sm opacity-70">
          Deny patterns (case-insensitive regex, one per line) checked
          against chat and run inputs — <b>block</b>
          refuses them, <b>flag</b>
          lets them through. Either way a matching input or
          output raises a <span class="font-mono">guardrail</span>
          notification (routable to webhooks). Blank disables.
        </p>

        <form phx-submit="set_guardrails" id="guardrails-form" class="space-y-2">
          <textarea
            name="patterns"
            rows="4"
            placeholder="credit card\npassword\n\\b\\d{3}-\\d{2}-\\d{4}\\b"
            class="textarea textarea-bordered textarea-sm w-full max-w-md font-mono"
          >{Enum.join((@guardrails && @guardrails.patterns) || [], "\n")}</textarea>
          <div class="flex gap-2 items-center">
            <select name="action" class="select select-bordered select-sm w-32">
              <option value="block" selected={(@guardrails && @guardrails.action) != "flag"}>
                block
              </option>
              <option value="flag" selected={@guardrails && @guardrails.action == "flag"}>
                flag
              </option>
            </select>
            <button class="btn btn-primary btn-sm">Save guardrails</button>
          </div>
        </form>

        <div class="divider my-1" />

        <h3 class="text-sm font-semibold">Model-backed moderation</h3>
        <p class="text-sm opacity-70">
          The workspace default model judges inputs against this policy
          (<b>block</b> refuses, <b>flag</b> lets through; outputs are
          always flag-only). One extra model call per checked message —
          blank disables. Judge failures allow rather than block.
        </p>

        <form phx-submit="set_moderation" id="moderation-form" class="space-y-2">
          <textarea
            name="policy"
            rows="3"
            placeholder="No medical or legal advice. No competitor pricing discussions."
            class="textarea textarea-bordered textarea-sm w-full max-w-md"
          >{@moderation && @moderation.policy}</textarea>
          <div class="flex gap-2 items-center">
            <select name="action" class="select select-bordered select-sm w-32">
              <option value="block" selected={(@moderation && @moderation.action) != "flag"}>
                block
              </option>
              <option value="flag" selected={@moderation && @moderation.action == "flag"}>
                flag
              </option>
            </select>
            <button class="btn btn-primary btn-sm">Save moderation</button>
          </div>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="alerts-card">
        <h2 class="font-semibold">Failure alerts</h2>

        <p class="text-sm opacity-70">
          Failed runs POST a JSON alert to this webhook (blank disables).
        </p>

        <form phx-submit="set_alert_url" id="alert-url-form" class="flex gap-2">
          <input
            type="url"
            name="url"
            value={@alert_url}
            placeholder="https://hooks.example.com/flux-alerts"
            class="input input-bordered input-sm w-full max-w-md"
          /> <button class="btn btn-primary btn-sm">Save</button>
        </form>

        <p :if={@alert_secret} class="text-xs opacity-70">
          Deliveries are signed: <span class="font-mono">x-flux-signature: sha256=HMAC(body)</span>
          with secret <span class="font-mono select-all">{@alert_secret}</span>
        </p>
      </div>

      <div :if={@can_webhooks} class="card border border-base-200 p-6 space-y-3" id="webhooks-card">
        <h2 class="font-semibold">Outgoing webhooks</h2>

        <p class="text-sm opacity-70">Run lifecycle events POST a signed JSON payload to each endpoint
          (<span class="font-mono">x-flux-signature: sha256=HMAC(body)</span> with the
          endpoint's secret). Deliveries retry on failure.</p>

        <table :if={@webhooks != []} class="table table-xs">
          <thead>
            <tr>
              <th>URL</th>

              <th>Events</th>

              <th>Secret</th>

              <th></th>
            </tr>
          </thead>

          <tbody>
            <tr :for={webhook <- @webhooks} id={"webhook-#{webhook.id}"}>
              <td class="max-w-xs truncate">{webhook.url}</td>

              <td class="text-xs">{Enum.join(webhook.events, ", ")}</td>

              <td class="font-mono text-xs select-all">{webhook.secret}</td>

              <td class="flex gap-1">
                <button
                  class={["btn btn-xs", (webhook.enabled && "btn-ghost") || "btn-warning"]}
                  phx-click="toggle_webhook"
                  phx-value-id={webhook.id}
                >
                  {(webhook.enabled && "Disable") || "Enable"}
                </button>
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="test_webhook"
                  phx-value-id={webhook.id}
                  title="Send a signed webhook.test event now"
                >
                  Send test
                </button>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_webhook"
                  phx-value-id={webhook.id}
                  data-confirm="Remove this webhook endpoint?"
                >
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="add_webhook" id="add-webhook-form" class="space-y-2">
          <div class="flex gap-2">
            <input
              type="url"
              name="url"
              required
              placeholder="https://hooks.example.com/flux"
              class="input input-bordered input-sm w-full max-w-md"
            /> <button class="btn btn-primary btn-sm">Add webhook</button>
          </div>

          <div class="flex flex-wrap gap-3 text-sm">
            <label :for={event <- Flux.Webhooks.events()} class="flex items-center gap-1">
              <input
                type="checkbox"
                name="events[]"
                value={event}
                checked={event in ["run.succeeded", "run.failed"]}
                class="checkbox checkbox-xs"
              /> {event}
            </label>
          </div>
        </form>

        <details :if={@webhook_deliveries != []} id="deliveries-log">
          <summary class="text-sm font-semibold cursor-pointer">
            Delivery log ({length(@webhook_deliveries)} recent)
          </summary>
          <table class="table table-xs mt-2">
            <thead>
              <tr>
                <th>When</th>
                <th>Event</th>
                <th>Status</th>
                <th>Attempts</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={delivery <- @webhook_deliveries} id={"delivery-#{delivery.id}"}>
                <td class="text-xs opacity-70">
                  {Calendar.strftime(delivery.inserted_at, "%m-%d %H:%M:%S")}
                </td>
                <td class="text-xs">{delivery.event}</td>
                <td>
                  <span class={[
                    "badge badge-xs",
                    (delivery.status in 200..299 && "badge-success") ||
                      (delivery.status == nil && delivery.attempts == 0 && "badge-ghost") ||
                      "badge-error"
                  ]}>
                    {delivery.status || (delivery.attempts == 0 && "queued") || "error"}
                  </span>
                  <span :if={delivery.last_error} class="text-xs opacity-60 ml-1">
                    {delivery.last_error}
                  </span>
                </td>
                <td class="text-xs">{delivery.attempts}</td>
                <td>
                  <button
                    class="btn btn-ghost btn-xs"
                    phx-click="retry_delivery"
                    phx-value-id={delivery.id}
                  >
                    Retry
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </details>
      </div>

      <div :if={@can_api_keys} class="card border border-base-200 p-6 space-y-3" id="api-keys-card">
        <h2 class="font-semibold">Workspace API keys</h2>

        <p class="text-sm opacity-70">
          <span class="font-mono text-xs">ws-…</span>
          keys authenticate the workspace-level API (datasets, quality, models) —
          no app or flux binding. App and flux keys live on their own pages.
        </p>

        <div :if={@new_ws_token} class="space-y-1">
          <p class="text-sm text-warning">Copy this key now — it is shown once:</p>
          <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto" id="new-ws-token">{@new_ws_token}</pre>
        </div>

        <table :if={@ws_tokens != []} class="table table-xs">
          <thead>
            <tr>
              <th>Key</th>
              <th>Expires</th>
              <th>Last used</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={token <- @ws_tokens} id={"ws-token-#{token.id}"}>
              <td class="font-mono text-xs">{token.prefix}</td>
              <td class="text-xs">
                {(token.expires_at && Calendar.strftime(token.expires_at, "%Y-%m-%d")) || "never"}
              </td>
              <td class="text-xs opacity-70">
                {(token.last_used_at && Calendar.strftime(token.last_used_at, "%Y-%m-%d %H:%M")) ||
                  "—"}
              </td>
              <td>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="revoke_ws_token"
                  phx-value-id={token.id}
                  data-confirm="Revoke this key? Anything using it stops working."
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="create_ws_token" id="create-ws-token-form" class="flex gap-2 items-center">
          <select name="expires_in_days" class="select select-bordered select-sm w-44">
            <option value="">Never expires</option>
            <option value="30">Expires in 30 days</option>
            <option value="90">Expires in 90 days</option>
            <option value="365">Expires in 365 days</option>
          </select>
          <button class="btn btn-primary btn-sm">Mint API key</button>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="export-card">
        <h2 class="font-semibold">Export</h2>

        <p class="text-sm opacity-70">Download everything — flux and app DSL, dataset documents and
          settings, workspace configuration — as one JSON archive. Secrets
          (provider keys, tokens) are never included.</p>

        <a href={~p"/console/workspace-export"} class="btn btn-outline btn-sm w-fit">
          <.icon name="hero-arrow-down-tray" class="size-4" /> Download workspace export
        </a>

        <form phx-submit="set_export_schedule" id="export-schedule-form" class="flex gap-2">
          <input
            type="text"
            name="cron"
            value={@export_schedule}
            placeholder="cron, e.g. 0 3 * * * (blank = off)"
            class="input input-bordered input-sm w-56 font-mono"
            title="Writes the export archive to storage on this schedule; it appears on the Files page."
          />
          <button class="btn btn-outline btn-sm">Schedule backups</button>
        </form>
        <form
          action={~p"/console/workspace-import"}
          method="post"
          enctype="multipart/form-data"
          class="flex items-center gap-2"
          id="workspace-import-form"
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input
            type="file"
            name="archive"
            accept=".json,application/json"
            required
            class="file-input file-input-sm"
          /> <button class="btn btn-outline btn-sm">Import archive</button>
        </form>

        <p class="text-xs opacity-60">Importing adds the archive's fluxes, apps, and datasets to this
          workspace (existing data is never touched). Cross-references like a
          chatflow's flux may need rebinding afterwards.</p>
      </div>

      <div :if={@owner?} class="card border border-base-200 p-6 space-y-3" id="plan-card">
        <h2 class="font-semibold">Plan</h2>

        <p class="text-sm opacity-70">
          Self-hosted deployments run as <span class="font-mono text-xs">enterprise</span>
          (everything on). Lower plans gate custom roles, annotations, datasource
          sync, SCIM, and LLM entity extraction — the hook a licensing backend
          plugs into.
        </p>

        <form phx-change="set_plan" id="plan-form">
          <select name="plan" class="select select-bordered select-sm w-48">
            <option
              :for={plan <- Enum.sort(Flux.Features.plans())}
              value={plan}
              selected={@plan == plan}
            >
              {plan}
            </option>
          </select>
        </form>
      </div>

      <div :if={@can_scim} class="card border border-base-200 p-6 space-y-3" id="scim-card">
        <h2 class="font-semibold">SCIM provisioning</h2>

        <p class="text-sm opacity-70">
          Let your identity provider create and remove members automatically.
          Base URL: <span class="font-mono text-xs">{url(~p"/") <> "scim/v2"}</span>
          — provisioned users join as <span class="font-mono text-xs">normal</span>
          members.
        </p>

        <div :if={@scim_token} class="space-y-1">
          <p class="text-sm text-warning">Copy this bearer token now — it is shown once:</p>
          <pre class="rounded bg-base-200 p-2 text-xs overflow-x-auto" id="scim-token">{@scim_token}</pre>
        </div>

        <div class="flex gap-2">
          <button class="btn btn-primary btn-sm" phx-click="enable_scim">
            {(@scim_enabled && "Rotate token") || "Enable SCIM"}
          </button>
          <button
            :if={@scim_enabled}
            class="btn btn-ghost btn-sm text-error"
            phx-click="disable_scim"
            data-confirm="Disable SCIM? The current token stops working."
          >
            Disable
          </button>
        </div>
      </div>

      <div :if={@owner?} class="card border border-error/40 p-6 space-y-3" id="danger-card">
        <h2 class="font-semibold text-error">Danger zone</h2>

        <p class="text-sm opacity-70">
          Deleting the workspace permanently removes every app, flux, dataset,
          run, and member. Type
          <span class="font-mono font-semibold">{@current_scope.workspace.name}</span>
          to confirm.
        </p>

        <form phx-submit="delete_workspace" id="delete-workspace-form" class="flex gap-2">
          <input
            type="text"
            name="confirm"
            placeholder={@current_scope.workspace.name}
            class="input input-bordered input-sm w-full max-w-md"
          />
          <button class="btn btn-error btn-sm" data-confirm="This cannot be undone. Delete?">
            Delete workspace
          </button>
        </form>
      </div>
    </Layouts.console>
    """
  end
end
