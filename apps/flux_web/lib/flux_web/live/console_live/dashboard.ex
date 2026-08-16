defmodule FluxWeb.ConsoleLive.Dashboard do
  @moduledoc false
  use FluxWeb, :live_view

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    # Live-ish dashboard: refresh the cards every 30s while open.
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok, refresh(assign(socket, page_title: "Dashboard"))}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      usage: Flux.Usage.workspace_summary(scope),
      member_usage: Flux.Usage.member_usage(scope) |> Enum.take(8),
      quality: Flux.Usage.quality_summary(scope),
      onboarding: Flux.Usage.onboarding(scope),
      activity: Flux.Audit.list(scope, 8),
      forecast: month_forecast(scope)
    )
  end

  # Straight-line month-end projection: tokens so far ÷ days elapsed ×
  # days in month, against the budget when one is set — the 80% warning
  # tells you when it happened; this tells you it's coming.
  defp month_forecast(scope) do
    workspace_id = Flux.Accounts.Scope.workspace_id(scope)
    spent = Flux.Usage.month_tokens(workspace_id)
    today = Date.utc_today()
    days_elapsed = max(today.day, 1)
    days_in_month = Date.days_in_month(today)
    projected = div(spent * days_in_month, days_elapsed)
    budget = Flux.Accounts.token_budget(scope)

    %{
      spent: spent,
      projected: projected,
      budget: budget,
      budget_pct: budget && budget > 0 && div(projected * 100, budget)
    }
  end

  defp onboarding_step(:provider), do: {"Connect a model provider", ~p"/console/plugins"}
  defp onboarding_step(:flux), do: {"Build your first flux", ~p"/console/fluxes"}
  defp onboarding_step(:publish), do: {"Publish a version", ~p"/console/fluxes"}
  defp onboarding_step(:knowledge), do: {"Add a knowledge dataset", ~p"/console/knowledge"}
  defp onboarding_step(:run), do: {"Run a flux or chat with an app", ~p"/console/fluxes"}
  defp onboarding_step(:invite), do: {"Invite a teammate", ~p"/console/members"}

  defp humanize_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp humanize_bytes(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp humanize_bytes(bytes), do: "#{bytes} B"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console
      flash={@flash}
      current_scope={@current_scope}
      workspaces={@workspaces}
      active={:dashboard}
    >
      <div>
        <h1 class="text-2xl font-bold">
          {gettext("Welcome to")} {@current_scope.workspace.name}
        </h1>
        <p class="opacity-70 mt-1">
          {gettext("You're signed in as")} {@current_scope.account.email} ({@current_scope.membership.role}).
        </p>
        <p class="opacity-50 mt-1 text-sm italic">
          Where we're going, we don't need boilerplate.
        </p>
      </div>

      <div
        :if={Enum.any?(@onboarding, &(not &1.done))}
        class="card border border-base-200 p-6 space-y-3"
        id="onboarding-checklist"
      >
        <div class="flex items-center gap-3">
          <h2 class="font-semibold">{gettext("Getting started")}</h2>
          <progress
            class="progress progress-primary w-40"
            value={Enum.count(@onboarding, & &1.done)}
            max={length(@onboarding)}
            aria-label={gettext("Getting started progress")}
          ></progress>
          <span class="text-xs opacity-60">
            {Enum.count(@onboarding, & &1.done)}/{length(@onboarding)}
          </span>
        </div>
        <ul class="space-y-1">
          <li :for={step <- @onboarding} class="flex items-center gap-2 text-sm">
            <.icon
              name={if step.done, do: "hero-check-circle-solid", else: "hero-minus-circle"}
              class={["size-5", if(step.done, do: "text-success", else: "opacity-40")]}
            />
            <% {label, path} = onboarding_step(step.key) %>
            <span :if={step.done} class="opacity-60 line-through">{label}</span>
            <.link :if={not step.done} navigate={path} class="link link-hover">
              {label}
            </.link>
          </li>
        </ul>
      </div>

      <div class="card border border-base-200 p-6 space-y-4" id="workspace-usage">
        <h2 class="font-semibold">{gettext("Usage (last %{days} days)", days: @usage.days)}</h2>

        <div class="stats stats-horizontal flex-wrap circuit-panel">
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Replies")}</div>
            <div class="stat-value text-lg circuit-value circuit-green">
              {@usage.tokens.replies}
            </div>
          </div>
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Tokens in")}</div>
            <div class="stat-value text-lg circuit-value circuit-amber">
              {@usage.tokens.input}
            </div>
          </div>
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Tokens out")}</div>
            <div class="stat-value text-lg circuit-value circuit-red">
              {@usage.tokens.output}
            </div>
          </div>
          <div class="stat py-2 px-4" id="cost-forecast">
            <div class="stat-title text-xs">{gettext("Month-end projection")}</div>
            <div class={[
              "stat-value text-lg circuit-value",
              (@forecast.budget_pct && @forecast.budget_pct > 100 && "circuit-red") ||
                "circuit-cyan"
            ]}>
              ~{@forecast.projected} tok
            </div>
            <div class="stat-desc">
              {@forecast.spent} so far<span :if={@forecast.budget}> · {@forecast.budget_pct}% of the {@forecast.budget} budget</span>
            </div>
          </div>
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Runs")}</div>
            <div class="stat-value text-lg circuit-value circuit-green">
              {@usage.runs |> Map.values() |> Enum.sum()}
            </div>
            <div :if={Map.get(@usage.runs, :failed, 0) > 0} class="stat-desc circuit-red">
              {@usage.runs[:failed]} failed
            </div>
          </div>
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Run tokens")}</div>
            <div class="stat-value text-lg circuit-value circuit-cyan" id="run-token-total">
              {@usage.run_tokens.input + @usage.run_tokens.output}
            </div>
            <div :if={@usage.run_tokens.estimated_cost_usd > 0} class="stat-desc">
              ~${:erlang.float_to_binary(@usage.run_tokens.estimated_cost_usd, decimals: 4)} est.
            </div>
          </div>
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Uploads")}</div>
            <div class="stat-value text-lg circuit-value circuit-amber">
              {humanize_bytes(@usage.storage_bytes)}
            </div>
          </div>
          <div class="stat py-2 px-4">
            <div class="stat-title text-xs">{gettext("Knowledge")}</div>
            <div class="stat-value text-lg circuit-value circuit-cyan">
              {@usage.knowledge.segments}
            </div>
            <div class="stat-desc">
              segments · {@usage.knowledge.documents} docs · {@usage.knowledge.datasets} sets
            </div>
          </div>
        </div>

        <div :if={@usage.top_apps != []} class="space-y-1">
          <p class="text-sm font-semibold">{gettext("Top apps by tokens")}</p>
          <table class="table table-xs max-w-xl">
            <thead>
              <tr>
                <th>{gettext("App")}</th>
                <th>{gettext("Replies")}</th>
                <th>{gettext("Tokens")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={app <- @usage.top_apps}>
                <td>{app.name}</td>
                <td>{app.replies}</td>
                <td>{app.tokens}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@usage.daily != []} class="space-y-1">
          <p class="text-sm font-semibold">{gettext("Daily")}</p>
          <table class="table table-xs max-w-xl">
            <thead>
              <tr>
                <th>{gettext("Day")}</th>
                <th>{gettext("Replies")}</th>
                <th>{gettext("Tokens in")}</th>
                <th>{gettext("Tokens out")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @usage.daily}>
                <td>{row.day}</td>
                <td>{row.replies}</td>
                <td>{row.input}</td>
                <td>{row.output}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <p
          :if={@usage.tokens.replies == 0 and @usage.runs == %{}}
          class="text-sm opacity-60"
        >
          {gettext("Nothing to report yet — usage appears here once apps and fluxes run.")}
        </p>
      </div>

      <div
        :if={@member_usage != []}
        class="card border border-base-200 p-6 space-y-3"
        id="member-usage"
      >
        <h2 class="font-semibold">Who is spending (30 days)</h2>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Started by</th>
              <th class="text-right">Runs</th>
              <th class="text-right">Tokens</th>
              <th class="text-right">Est. cost</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @member_usage}>
              <td class="text-xs">{row.who}</td>
              <td class="text-right text-xs">{row.runs}</td>
              <td class="text-right text-xs">{row.tokens}</td>
              <td class="text-right text-xs">${Float.round(row.cost * 1.0, 4)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card border border-base-200 p-6 space-y-3" id="quality-panel">
        <div class="flex items-center gap-2">
          <h2 class="font-semibold">{gettext("Quality")}</h2>
          <span class="badge badge-ghost badge-sm">
            {@quality.gated_sets} {gettext("gates")}
          </span>
          <span :if={@quality.scheduled_sets > 0} class="badge badge-ghost badge-sm">
            {@quality.scheduled_sets} {gettext("scheduled")}
          </span>
          <.link navigate={~p"/console/labeling"} class="badge badge-ghost badge-sm link-hover">
            {@quality.unlabeled_tasks} {gettext("to label")}
          </.link>
          <span :if={@quality.avg_agreement} class="badge badge-ghost badge-sm">
            {gettext("agreement")} {round(@quality.avg_agreement * 100)}%
          </span>
        </div>

        <table :if={@quality.recent_evals != []} class="table table-xs max-w-xl">
          <thead>
            <tr>
              <th>{gettext("Eval set")}</th>
              <th>{gettext("Target")}</th>
              <th>{gettext("Score")}</th>
              <th>{gettext("Pass / fail")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={eval <- @quality.recent_evals}>
              <td>{eval.set_name}</td>
              <td><span class="badge badge-ghost badge-xs">{eval.target}</span></td>
              <td class="font-mono">{eval.avg_score}</td>
              <td class="text-xs">{eval.passed} / {eval.failed}</td>
            </tr>
          </tbody>
        </table>

        <p :if={@quality.recent_evals == []} class="text-sm opacity-60">
          {gettext("No evals yet — score a flux from its Evals page and results land here.")}
        </p>
      </div>

      <div :if={@activity != []} class="card border border-base-200 p-6 space-y-2" id="activity-feed">
        <h2 class="font-semibold">{gettext("Recent activity")}</h2>
        <ul class="space-y-1">
          <li :for={entry <- @activity} class="text-sm flex items-baseline gap-2">
            <span class="opacity-50 text-xs whitespace-nowrap">
              {Calendar.strftime(entry.inserted_at, "%b %d %H:%M")}
            </span>
            <span class="badge badge-ghost badge-xs">{entry.action}</span>
            <span class="opacity-70 truncate">
              {(entry.actor && entry.actor.email) || "system"}
            </span>
          </li>
        </ul>
        <.link navigate={~p"/console/audit"} class="link link-hover text-xs opacity-60">
          {gettext("Full audit log")} →
        </.link>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <.link
          navigate={~p"/console/fluxes"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-squares-2x2" class="size-6 text-primary" />
          <h2 class="font-semibold">{gettext("Create a Flux")}</h2>
          <p class="text-sm opacity-70">
            Build an AI workflow on the visual canvas and publish it for your team.
          </p>
        </.link>

        <.link
          navigate={~p"/console/knowledge"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-book-open" class="size-6 text-primary" />
          <h2 class="font-semibold">{gettext("Add knowledge")}</h2>
          <p class="text-sm opacity-70">
            Upload documents so your Fluxes can answer with your organization's content.
          </p>
        </.link>

        <.link
          navigate={~p"/console/plugins"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-puzzle-piece" class="size-6 text-primary" />
          <h2 class="font-semibold">{gettext("Set up plugins")}</h2>
          <p class="text-sm opacity-70">
            Connect model providers and tools your workspace can use.
          </p>
        </.link>

        <.link
          navigate={~p"/console/members"}
          class="card border border-base-200 p-6 hover:border-primary transition-colors space-y-2"
        >
          <.icon name="hero-user-group" class="size-6 text-primary" />
          <h2 class="font-semibold">{gettext("Invite your team")}</h2>
          <p class="text-sm opacity-70">
            Add teammates and assign roles so everyone can collaborate.
          </p>
        </.link>
      </div>
    </Layouts.console>
    """
  end
end
