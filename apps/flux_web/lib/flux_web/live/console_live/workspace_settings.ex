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
       audit_retention_days: Accounts.audit_retention_days(scope),
       export_schedule: Accounts.export_schedule(scope),
       digest_frequency: Accounts.digest_frequency(scope),
       workspace_locale: Accounts.workspace_locale(scope),
       oidc_role_mapping: Accounts.oidc_role_mapping(scope),
       known_locales: Enum.sort(Gettext.known_locales(FluxWeb.Gettext)),
       console_logo: Accounts.console_logo(scope),
       token_budget: Accounts.token_budget(scope),
       llm_cache_minutes: Accounts.llm_cache_minutes(scope),
       default_model_params:
         Accounts.default_model_params(Flux.Accounts.Scope.workspace_id(scope)),
       cache_stats: Flux.LLMCache.stats(),
       embedding_cache_stats: Flux.EmbeddingCache.stats(),
       pricing_overrides:
         Flux.Pricing.overrides(Flux.Accounts.Scope.workspace_id(scope)) |> Enum.sort(),
       max_concurrent_runs: Accounts.max_concurrent_runs(scope),
       guardrails: Flux.Guardrails.config(Flux.Accounts.Scope.workspace_id(scope)),
       moderation: Flux.Guardrails.moderation_config(Flux.Accounts.Scope.workspace_id(scope)),
       moderation_api:
         Flux.Guardrails.moderation_api_config(Flux.Accounts.Scope.workspace_id(scope)),
       ip_allowlist: Flux.IPAllowlist.list(Flux.Accounts.Scope.workspace_id(scope)),
       alert_url: Accounts.alert_url(scope),
       alert_secret: Accounts.alert_secret(scope),
       can_webhooks: RBAC.can?(scope, :api_extension_manage),
       webhooks: Flux.Webhooks.list_endpoints(scope),
       webhook_deliveries: Flux.Webhooks.list_deliveries(scope, 25),
       can_api_keys: RBAC.can?(scope, :app_create_and_management),
       ws_tokens: Chat.list_workspace_tokens(scope),
       new_ws_token: nil,
       workspace_system_prompt: Accounts.workspace_system_prompt(scope),
       can_env: RBAC.can?(scope, :credential_manage),
       env_vars: Flux.WorkspaceEnv.list(scope),
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

  def handle_event(
        "set_default_params",
        %{"temperature" => temperature, "max_tokens" => max_tokens},
        socket
      ) do
    case Accounts.set_default_model_params(socket.assigns.current_scope, temperature, max_tokens) do
      {:ok, _workspace} ->
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Default model params saved.")
         |> assign(default_model_params: Accounts.default_model_params(workspace_id))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the defaults.")}
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

  def handle_event("add_guardrail_preset", %{"pattern" => pattern}, socket) do
    current = (socket.assigns.guardrails && socket.assigns.guardrails.patterns) || []

    if pattern in current do
      {:noreply, socket}
    else
      action = (socket.assigns.guardrails && socket.assigns.guardrails.action) || "redact"

      case Flux.Guardrails.configure(
             socket.assigns.current_scope,
             Enum.join(current ++ [pattern], "\n"),
             action
           ) do
        {:ok, _workspace} ->
          workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

          {:noreply,
           socket
           |> put_flash(:info, "Preset added to the guardrails.")
           |> assign(guardrails: Flux.Guardrails.config(workspace_id))}

        _error ->
          {:noreply, put_flash(socket, :error, "Could not add the preset.")}
      end
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

  def handle_event("set_ip_allowlist", %{"cidrs" => cidrs}, socket) do
    case Flux.IPAllowlist.configure(socket.assigns.current_scope, cidrs) do
      {:ok, _workspace} ->
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "IP allowlist saved.")
         |> assign(ip_allowlist: Flux.IPAllowlist.list(workspace_id))}

      {:error, {:invalid_cidr, entry}} ->
        {:noreply, put_flash(socket, :error, "Not an address or CIDR: #{entry}")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the allowlist.")}
    end
  end

  def handle_event("set_oidc_mapping", %{"claim" => claim, "mapping" => mapping_text}, socket) do
    mapping =
      mapping_text
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [value, role] -> [{String.trim(value), String.trim(role)}]
          _malformed -> []
        end
      end)
      |> Enum.filter(fn {value, role} ->
        value != "" and role in ~w(admin editor normal dataset_operator)
      end)
      |> Map.new()

    case Accounts.set_oidc_role_mapping(socket.assigns.current_scope, claim, mapping) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "OIDC role mapping saved.")
         |> assign(
           oidc_role_mapping:
             {(String.trim(claim) != "" and mapping != %{} && String.trim(claim)) || nil, mapping}
         )}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the mapping.")}
    end
  end

  def handle_event("set_workspace_locale", %{"locale" => locale}, socket) do
    locale = ((locale == "" or locale not in socket.assigns.known_locales) && nil) || locale

    case Accounts.set_workspace_locale(socket.assigns.current_scope, locale) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Default language saved — it applies on the next page load.")
         |> assign(workspace_locale: locale)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the default language.")}
    end
  end

  def handle_event("set_digest_frequency", %{"frequency" => frequency}, socket)
      when frequency in ~w(weekly daily off) do
    case Accounts.set_digest_frequency(socket.assigns.current_scope, frequency) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Digest frequency saved.")
         |> assign(digest_frequency: frequency)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the digest frequency.")}
    end
  end

  def handle_event("set_console_logo", %{"url" => url}, socket) do
    case Accounts.set_console_logo(socket.assigns.current_scope, url) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Console logo saved — reload to see the sidebar change.")
         |> assign(console_logo: String.trim(url))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the logo.")}
    end
  end

  def handle_event("rotate_webhook_secret", %{"id" => id}, socket) do
    case Flux.Webhooks.rotate_secret(socket.assigns.current_scope, id) do
      {:ok, endpoint} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "New signing secret for #{endpoint.url}: #{endpoint.secret} — update the receiver now."
         )
         |> assign(webhooks: Flux.Webhooks.list_endpoints(socket.assigns.current_scope))}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not rotate the secret.")}
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

  def handle_event(
        "set_moderation_api",
        %{"url" => url, "action" => action, "fail" => fail},
        socket
      ) do
    case Flux.Guardrails.configure_moderation_api(socket.assigns.current_scope, url, action, fail) do
      {:ok, _workspace} ->
        workspace_id = Flux.Accounts.Scope.workspace_id(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Moderation endpoint saved.")
         |> assign(moderation_api: Flux.Guardrails.moderation_api_config(workspace_id))}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the moderation endpoint.")}
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

  def handle_event("set_audit_retention", %{"days" => days}, socket) do
    parsed =
      case Integer.parse(String.trim(days)) do
        {n, ""} when n in 30..3650 -> n
        _blank_or_invalid -> nil
      end

    case Accounts.set_audit_retention_days(socket.assigns.current_scope, parsed) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           (parsed && "Audit entries now prune after #{parsed} days.") ||
             "Audit trail kept forever."
         )
         |> assign(audit_retention_days: parsed)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to change retention.")}
    end
  end

  def handle_event("set_system_prompt", %{"prompt" => prompt}, socket) do
    case Accounts.set_workspace_system_prompt(socket.assigns.current_scope, prompt) do
      {:ok, _workspace} ->
        trimmed = String.trim(prompt)

        {:noreply,
         socket
         |> put_flash(
           :info,
           (trimmed == "" && "Workspace prompt cleared.") ||
             "Saved — it now prefixes every chat app's system prompt."
         )
         |> assign(workspace_system_prompt: (trimmed == "" && nil) || trimmed)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to change this.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not save the workspace prompt.")}
    end
  end

  def handle_event("put_env_var", params, socket) do
    scope = socket.assigns.current_scope

    case Flux.WorkspaceEnv.put(
           scope,
           params["name"],
           params["value"],
           params["is_secret"] == "on"
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved — reachable as {{env.#{String.trim(params["name"] || "")}}}.")
         |> assign(env_vars: Flux.WorkspaceEnv.list(scope))}

      {:error, :bad_name} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Names are letters, digits, and underscores (no leading digit)."
         )}

      {:error, :blank_value} ->
        {:noreply, put_flash(socket, :error, "The value cannot be blank.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to manage credentials.")}
    end
  end

  def handle_event("delete_env_var", %{"name" => name}, socket) do
    scope = socket.assigns.current_scope
    Flux.WorkspaceEnv.delete(scope, name)
    {:noreply, assign(socket, env_vars: Flux.WorkspaceEnv.list(scope))}
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

  def handle_event("create_ws_token", %{"expires_in_days" => days} = params, socket) do
    expires_in_days =
      case Integer.parse(days) do
        {n, ""} when n > 0 -> n
        _never -> nil
      end

    rate_limit =
      case Integer.parse(to_string(params["rate_limit"] || "")) do
        {n, ""} when n > 0 -> n
        _default -> nil
      end

    case Chat.create_workspace_token(socket.assigns.current_scope,
           expires_in_days: expires_in_days,
           rate_limit_per_minute: rate_limit
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
    attrs = %{
      "url" => params["url"],
      "events" => Map.get(params, "events", []),
      "format" => Map.get(params, "format", "json")
    }

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

  def handle_event("archive_workspace", _params, socket) do
    case Accounts.archive_workspace(socket.assigns.current_scope) do
      {:ok, _workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace archived — an instance admin can restore it.")
         |> redirect(to: ~p"/console")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Only the owner can archive the workspace.")}
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

        <p class="text-sm opacity-70 pt-2">
          Default params: applied wherever an app or LLM node sets none of
          its own (a node's own value always wins). Blank turns a default off.
        </p>

        <form
          phx-submit="set_default_params"
          id="default-params-form"
          class="flex gap-2 items-end flex-wrap"
        >
          <label class="form-control">
            <span class="label-text text-xs opacity-70 mb-1">Temperature (0 to 2)</span>
            <input
              type="number"
              name="temperature"
              value={@default_model_params[:temperature]}
              min="0"
              max="2"
              step="0.05"
              placeholder="provider default"
              class="input input-bordered input-sm w-36"
            />
          </label>
          <label class="form-control">
            <span class="label-text text-xs opacity-70 mb-1">Max tokens</span>
            <input
              type="number"
              name="max_tokens"
              value={@default_model_params[:max_tokens]}
              min="1"
              placeholder="provider default"
              class="input input-bordered input-sm w-36"
            />
          </label>
          <button class="btn btn-primary btn-sm">Save defaults</button>
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

        <p class="text-sm opacity-70 pt-2">
          Audit trail: kept forever by default. Set a separate window (min
          30 days) only if a data-minimization policy requires pruning.
        </p>

        <form
          phx-submit="set_audit_retention"
          id="audit-retention-form"
          class="flex gap-2 items-center"
        >
          <input
            type="number"
            name="days"
            value={@audit_retention_days}
            min="30"
            max="3650"
            placeholder="∞"
            class="input input-bordered input-sm w-28"
          /> <span class="text-sm opacity-70">days (audit)</span>
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

        <p class="text-xs opacity-60" id="cache-stats">
          Cache since boot (instance-wide): {@cache_stats.hits} hits / {@cache_stats.misses} misses ({@cache_stats.hit_rate}% hit rate), {@cache_stats.entries} entr{(@cache_stats.entries ==
                                                                                                                                                                        1 &&
                                                                                                                                                                        "y") ||
            "ies"} held.
        </p>

        <p class="text-xs opacity-60" id="embedding-cache-stats">
          Embedding cache (always on, 24h TTL): {@embedding_cache_stats.hits} hits / {@embedding_cache_stats.misses} misses ({@embedding_cache_stats.hit_rate}% hit rate), {@embedding_cache_stats.entries} vectors held.
        </p>

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

      <div
        :if={@can_rename}
        class="card border border-base-200 p-6 space-y-3"
        id="workspace-prompt-card"
      >
        <h2 class="font-semibold">Workspace system prompt</h2>
        <p class="text-sm opacity-70">
          An org-wide prefix baked into every chat app's model calls —
          compliance boilerplate and tone rules live once instead of
          per app. Blank disables.
        </p>
        <form phx-submit="set_system_prompt" id="workspace-prompt-form" class="space-y-2">
          <textarea
            name="prompt"
            rows="3"
            placeholder="e.g. Never provide legal advice. Answer in the customer's language."
            class="textarea textarea-bordered textarea-sm w-full max-w-xl"
          >{@workspace_system_prompt}</textarea>
          <button class="btn btn-primary btn-sm">Save</button>
        </form>
      </div>

      <div :if={@can_env} class="card border border-base-200 p-6 space-y-3" id="env-vars-card">
        <h2 class="font-semibold">Environment variables</h2>
        <p class="text-sm opacity-70">
          Workspace-wide values every flux reaches as <span class="font-mono">{"{{env.NAME}}"}</span>
          — API keys and shared config live once. Encrypted at rest; <b>secret</b>
          values never display again. A flux's own env wins
          on name collisions.
        </p>

        <table :if={@env_vars != []} class="table table-xs max-w-2xl">
          <thead>
            <tr>
              <th>Name</th>
              <th>Value</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={var <- @env_vars} id={"env-var-#{var.name}"}>
              <td class="font-mono">{var.name}</td>
              <td class="font-mono">
                {(var.is_secret && "••••••") || var.value}
              </td>
              <td>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_env_var"
                  phx-value-name={var.name}
                  data-confirm={"Delete {{env.#{var.name}}}? Fluxes using it will render blanks."}
                >
                  ✕
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-submit="put_env_var" id="env-var-form" class="flex flex-wrap items-center gap-2">
          <input
            type="text"
            name="name"
            placeholder="API_BASE"
            class="input input-bordered input-sm w-40 font-mono"
            required
          />
          <input
            type="text"
            name="value"
            placeholder="value"
            class="input input-bordered input-sm w-64 font-mono"
            required
          />
          <label class="flex items-center gap-1 text-xs">
            <input type="checkbox" name="is_secret" class="checkbox checkbox-xs" /> secret
          </label>
          <button class="btn btn-primary btn-sm">Save</button>
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

        <div class="flex flex-wrap items-center gap-1" id="guardrail-presets">
          <span class="text-xs opacity-60">Presets:</span>
          <button
            :for={{label, pattern} <- Flux.Guardrails.presets()}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="add_guardrail_preset"
            phx-value-pattern={pattern}
            title={pattern}
          >
            + {label}
          </button>
        </div>

        <form phx-submit="set_guardrails" id="guardrails-form" class="space-y-2">
          <textarea
            name="patterns"
            rows="4"
            placeholder="credit card\npassword\n\\b\\d{3}-\\d{2}-\\d{4}\\b"
            class="textarea textarea-bordered textarea-sm w-full max-w-md font-mono"
          >{Enum.join((@guardrails && @guardrails.patterns) || [], "\n")}</textarea>
          <div class="flex gap-2 items-center">
            <select name="action" class="select select-bordered select-sm w-32">
              <option
                value="block"
                selected={(@guardrails && @guardrails.action) not in ["flag", "redact"]}
              >
                block
              </option>
              <option value="flag" selected={@guardrails && @guardrails.action == "flag"}>
                flag
              </option>
              <option
                value="redact"
                selected={@guardrails && @guardrails.action == "redact"}
                title="Mask matches with ••• in chat messages, replies, and run inputs instead of refusing"
              >
                redact
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

        <div class="divider my-1" />

        <h3 class="text-sm font-semibold">External moderation API</h3>
        <p class="text-sm opacity-70">
          Checked text POSTs to your endpoint as <span class="font-mono">{"{text, context}"}</span>; it answers <span class="font-mono">{"{flagged, reason}"}</span>. Runs alongside the
          patterns and the model judge — blank disables. <b>fail open</b>
          lets traffic through when the endpoint is down; <b>fail closed</b>
          blocks it.
        </p>

        <form phx-submit="set_moderation_api" id="moderation-api-form" class="space-y-2">
          <input
            type="url"
            name="url"
            value={@moderation_api && @moderation_api.url}
            placeholder="https://moderation.example.com/check"
            class="input input-bordered input-sm w-full max-w-md"
          />
          <div class="flex gap-2 items-center">
            <select name="action" class="select select-bordered select-sm w-32">
              <option value="block" selected={(@moderation_api && @moderation_api.action) != "flag"}>
                block
              </option>
              <option value="flag" selected={@moderation_api && @moderation_api.action == "flag"}>
                flag
              </option>
            </select>
            <select name="fail" class="select select-bordered select-sm w-36">
              <option value="open" selected={(@moderation_api && @moderation_api.fail) != "closed"}>
                fail open
              </option>
              <option value="closed" selected={@moderation_api && @moderation_api.fail == "closed"}>
                fail closed
              </option>
            </select>
            <button class="btn btn-primary btn-sm">Save endpoint</button>
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
                  class="btn btn-ghost btn-xs"
                  phx-click="rotate_webhook_secret"
                  phx-value-id={webhook.id}
                  data-confirm="Rotate the signing secret? The receiver must switch immediately."
                  title="Regenerate the whsec_ signing secret"
                >
                  Rotate secret
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
            />
            <select
              name="format"
              class="select select-bordered select-sm w-28"
              title="slack wraps events in Block Kit for Slack incoming-webhook URLs"
            >
              <option value="json">JSON</option>
              <option value="slack">Slack</option>
            </select>
            <button class="btn btn-primary btn-sm">Add webhook</button>
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
              <th>Limit</th>
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
              <td class="text-xs opacity-70">
                {(token.rate_limit_per_minute && "#{token.rate_limit_per_minute}/min") || "default"}
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
          <input
            type="number"
            name="rate_limit"
            min="1"
            max="10000"
            placeholder="req/min (default)"
            title="Optional per-key rate limit; blank uses the pipeline default"
            class="input input-bordered input-sm w-36"
          />
          <button class="btn btn-primary btn-sm">Mint API key</button>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="digest-card">
        <h2 class="font-semibold">Digest & branding</h2>

        <form
          phx-change="set_digest_frequency"
          id="digest-frequency-form"
          class="flex gap-2 items-center"
        >
          <span class="text-sm opacity-70">Activity digest:</span>
          <select name="frequency" class="select select-bordered select-sm w-32">
            <option value="weekly" selected={@digest_frequency == "weekly"}>weekly</option>
            <option value="daily" selected={@digest_frequency == "daily"}>daily</option>
            <option value="off" selected={@digest_frequency == "off"}>off</option>
          </select>
        </form>

        <form
          phx-change="set_workspace_locale"
          id="workspace-locale-form"
          class="flex gap-2 items-center"
        >
          <span class="text-sm opacity-70">Default console language:</span>
          <select
            name="locale"
            class="select select-bordered select-sm w-40"
            title="Used when a member has not picked a language and their browser does not say"
          >
            <option value="" selected={@workspace_locale == nil}>browser default</option>
            <option
              :for={locale <- @known_locales}
              value={locale}
              selected={@workspace_locale == locale}
            >
              {locale}
            </option>
          </select>
        </form>

        <form phx-submit="set_oidc_mapping" id="oidc-mapping-form" class="space-y-2">
          <p class="text-sm opacity-70">
            OIDC role mapping — roles follow the IdP on every SSO login. Claim name plus
            <code>value=role</code>
            lines (roles: admin, editor, normal, dataset_operator);
            owners and unmatched members are never touched.
          </p>
          <div class="flex gap-2 items-start">
            <input
              type="text"
              name="claim"
              value={elem(@oidc_role_mapping, 0)}
              placeholder="groups"
              class="input input-bordered input-sm w-36"
            />
            <textarea
              name="mapping"
              rows="3"
              placeholder="platform-admins=admin\nbuilders=editor"
              class="textarea textarea-bordered textarea-sm flex-1 font-mono"
            >{Enum.map_join(elem(@oidc_role_mapping, 1), "\n", fn {value, role} -> "#{value}=#{role}" end)}</textarea>
            <button class="btn btn-primary btn-sm">Save</button>
          </div>
        </form>

        <form phx-submit="set_console_logo" id="console-logo-form" class="flex gap-2 items-center">
          <input
            type="url"
            name="url"
            value={@console_logo}
            placeholder="https://…/logo.png (blank restores the wordmark)"
            class="input input-bordered input-sm w-96"
          />
          <button class="btn btn-primary btn-sm">Save logo</button>
        </form>
      </div>

      <div :if={@can_rename} class="card border border-base-200 p-6 space-y-3" id="ip-allowlist-card">
        <h2 class="font-semibold">API IP allowlist</h2>
        <p class="text-sm opacity-70">
          One address or CIDR per line (e.g. <code>203.0.113.0/24</code>).
          When set, service-API calls from other addresses get 403 — even
          with a valid key. Blank turns it off. Behind a reverse proxy,
          make sure the client address reaches the app.
        </p>
        <form phx-submit="set_ip_allowlist" id="ip-allowlist-form" class="space-y-2">
          <textarea
            name="cidrs"
            rows="3"
            placeholder="203.0.113.0/24\n198.51.100.7"
            class="textarea textarea-bordered w-full font-mono text-xs"
          >{Enum.join(@ip_allowlist, "\n")}</textarea>
          <button class="btn btn-primary btn-sm">Save allowlist</button>
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

        <div class="flex items-center gap-3">
          <button
            class="btn btn-outline btn-sm"
            phx-click="archive_workspace"
            data-confirm="Archive this workspace? It leaves everyone's switcher (nothing is deleted); an instance admin can restore it."
          >
            <.icon name="hero-archive-box" class="size-4" /> Archive workspace
          </button>
          <span class="text-xs opacity-60">The reversible alternative to deleting.</span>
        </div>

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
