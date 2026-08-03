defmodule FluxWeb.ConsoleLive.Dashboard do
  @moduledoc false
  use FluxWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Dashboard",
       usage: Flux.Usage.workspace_summary(socket.assigns.current_scope)
     )}
  end

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
