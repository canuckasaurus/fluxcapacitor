defmodule FluxWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FluxWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-200">
      <div class="flex-1">
        <a href="/" class="flex w-fit items-center gap-2">
          <.icon name="hero-bolt-solid" class="size-6 flux-bolt" />
          <span class="text-lg flux-wordmark">FluxCapacitor</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex px-1 space-x-2 items-center">
          <li>
            <a href={FluxWeb.docs_url()} target="_blank" class="btn btn-ghost btn-sm">Docs</a>
          </li>
          <li :if={@current_scope}>
            <.link navigate={~p"/console"} class="btn btn-primary btn-sm">
              Console <span aria-hidden="true">&rarr;</span>
            </.link>
          </li>
          <li :if={is_nil(@current_scope)}>
            <.link navigate={~p"/accounts/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
          </li>
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-16 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The authenticated console layout: fixed sidebar with the product sections,
  topbar with the workspace name and account menu, content area.

  ## Examples

      <Layouts.console flash={@flash} current_scope={@current_scope} active={:fluxes}>
        ...
      </Layouts.console>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :active, :atom, required: true, doc: "which sidebar section is active"

  attr :workspaces, :list,
    default: [],
    doc: "all {workspace, membership} pairs for the switcher"

  attr :full_bleed, :boolean,
    default: false,
    doc: "let the content use the full width and height (canvas pages)"

  slot :inner_block, required: true

  def console(assigns) do
    ~H"""
    <div class="min-h-screen flex bg-base-100">
      <aside class="w-60 shrink-0 border-r border-base-200 flex flex-col">
        <div class="px-4 py-4 border-b border-base-200">
          <.link navigate={~p"/console"} class="flex items-center gap-2">
            <.icon name="hero-bolt-solid" class="size-6 flux-bolt" />
            <span class="text-lg flux-wordmark">FluxCapacitor</span>
          </.link>
        </div>

        <nav class="flex-1 px-2 py-4 space-y-1 overflow-y-auto">
          <.sidebar_link
            navigate={~p"/console"}
            icon="hero-home"
            label="Dashboard"
            active={@active == :dashboard}
          />

          <.sidebar_section label="Build" />
          <.sidebar_link
            navigate={~p"/console/fluxes"}
            icon="hero-squares-2x2"
            label="Flux Creator"
            active={@active == :fluxes}
          />
          <.sidebar_link
            navigate={~p"/console/apps"}
            icon="hero-chat-bubble-left-right"
            label="Apps"
            active={@active == :apps}
          />
          <.sidebar_link
            navigate={~p"/console/templates"}
            icon="hero-document-duplicate"
            label="Doc templates"
            active={@active == :templates}
          />

          <.sidebar_section label="Ground" />
          <.sidebar_link
            navigate={~p"/console/knowledge"}
            icon="hero-book-open"
            label="Knowledge"
            active={@active == :knowledge}
          />
          <.sidebar_link
            navigate={~p"/console/tools"}
            icon="hero-wrench-screwdriver"
            label="Tools"
            active={@active == :tools}
          />
          <.sidebar_link
            navigate={~p"/console/plugins"}
            icon="hero-puzzle-piece"
            label="Plugins"
            active={@active == :plugins}
          />

          <.sidebar_section label="Operate" />
          <.sidebar_link
            navigate={~p"/console/members"}
            icon="hero-user-group"
            label="Members"
            active={@active == :members}
          />
          <.sidebar_link
            :if={Flux.RBAC.can?(@current_scope, :workspace_member_manage)}
            navigate={~p"/console/audit"}
            icon="hero-clipboard-document-list"
            label="Audit log"
            active={@active == :audit}
          />
          <.sidebar_link
            navigate={~p"/console/settings"}
            icon="hero-cog-6-tooth"
            label="Settings"
            active={@active == :settings}
          />

          <div class="pt-2">
            <a
              href={FluxWeb.docs_url()}
              target="_blank"
              class="flex items-center gap-2 rounded-lg px-3 py-2 text-sm opacity-70 hover:bg-base-200 hover:opacity-100"
            >
              <.icon name="hero-academic-cap" class="size-4" /> Docs
              <.icon name="hero-arrow-top-right-on-square" class="size-3 ml-auto opacity-50" />
            </a>
          </div>
        </nav>

        <div class="px-4 py-4 border-t border-base-200 space-y-3">
          <div :if={@current_scope.workspace} class="text-xs">
            <div class="opacity-60">Workspace</div>
            <details class="dropdown dropdown-top w-full">
              <summary class="font-semibold truncate cursor-pointer list-none flex items-center gap-1">
                {@current_scope.workspace.name}
                <.icon name="hero-chevron-up-down-micro" class="size-3 opacity-60 shrink-0" />
              </summary>
              <ul class="dropdown-content menu bg-base-100 rounded-box z-20 w-52 p-2 shadow border border-base-200">
                <li :for={{workspace, _membership} <- @workspaces}>
                  <span :if={workspace.id == @current_scope.workspace.id} class="font-semibold">
                    {workspace.name} ✓
                  </span>
                  <.link
                    :if={workspace.id != @current_scope.workspace.id}
                    href={~p"/console/workspaces/switch/#{workspace.id}"}
                    method="post"
                  >
                    {workspace.name}
                  </.link>
                </li>
                <li class="border-t border-base-200 mt-1 pt-1">
                  <.link navigate={~p"/console/workspaces/new"}>
                    <.icon name="hero-plus-micro" class="size-3" /> New workspace
                  </.link>
                </li>
              </ul>
            </details>
          </div>
          <div class="text-xs">
            <div class="opacity-60">Signed in as</div>
            <div class="font-semibold truncate">{@current_scope.account.email}</div>
          </div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/accounts/settings"} class="btn btn-ghost btn-xs">Settings</.link>
            <.link href={~p"/accounts/log-out"} method="delete" class="btn btn-ghost btn-xs">
              Log out
            </.link>
          </div>
          <.theme_toggle />
        </div>
      </aside>

      <main class={[
        "flex-1 min-w-0 overflow-x-auto",
        (@full_bleed && "p-4") || "px-6 py-8"
      ]}>
        <div class={(@full_bleed && "h-full") || "mx-auto max-w-5xl space-y-6"}>
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :label, :string, required: true

  defp sidebar_section(assigns) do
    ~H"""
    <div class="px-3 pt-4 pb-1 text-[0.62rem] font-semibold uppercase tracking-[0.14em] opacity-50">
      {@label}
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2 rounded-lg px-3 py-2 text-sm",
        @active && "bg-primary/10 text-primary font-semibold",
        !@active && "hover:bg-base-200"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/2 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=dark]_&]:left-1/2 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/2 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/2 justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
