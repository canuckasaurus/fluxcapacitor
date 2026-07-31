defmodule FluxWeb.Router do
  use FluxWeb, :router

  import FluxWeb.AccountAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FluxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_account
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :service_api do
    plug :accepts, ["json"]
    plug FluxWeb.Plugs.ServiceAuth
    plug FluxWeb.Plugs.RateLimit, name: "v1", by: :service, limit: 120, scale_ms: 60_000
  end

  pipeline :auth_rate_limit do
    plug FluxWeb.Plugs.RateLimit,
      name: "auth",
      by: :ip,
      limit: 10,
      scale_ms: 60_000,
      methods: ["POST"]
  end

  ## Service API (FluxCapacitor service API, Bearer app-… tokens)

  scope "/v1", FluxWeb.V1 do
    pipe_through :service_api

    post "/chat-messages", ChatMessageController, :create
    post "/workflows/run", WorkflowRunController, :create
    post "/workflows/runs/:id/resume", WorkflowRunController, :resume

    post "/completion-messages", ChatMessageController, :completion
    post "/files/upload", AppResourceController, :upload_file
    get "/parameters", AppResourceController, :parameters
    get "/conversations", AppResourceController, :conversations
    get "/messages", AppResourceController, :messages
    post "/chat-messages/:id/stop", AppResourceController, :stop
    post "/messages/:id/feedbacks", AppResourceController, :feedback
    get "/meta", AppResourceController, :meta
    post "/conversations/:id/name", AppResourceController, :rename_conversation
    delete "/conversations/:id", AppResourceController, :delete_conversation
  end

  scope "/", FluxWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Public published app sites (token in path is the authorization)

  scope "/site", FluxWeb do
    pipe_through [:browser, :allow_embedding]

    live_session :public_site do
      live "/flux/:token", SiteLive.FluxSite, :show
      live "/:token", SiteLive.AppSite, :show
    end
  end

  ## Public workflow triggers (token in path is the authorization)

  scope "/triggers", FluxWeb do
    pipe_through :api

    post "/webhook/:token", TriggerController, :webhook
  end

  # Other scopes may use custom stacks.
  # scope "/api", FluxWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:flux_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FluxWeb.Telemetry
    end
  end

  # The Swoosh mailbox preview is compiled in for every environment but only
  # answers when :mailbox_enabled is set (dev always; releases opt in with
  # FLUX_MAILBOX=1 — the local-deploy substitute for a real mail adapter).
  # It sits behind authentication since it exposes every delivered email.
  scope "/dev" do
    pipe_through [:browser, :require_authenticated_account, :require_mailbox_enabled]

    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end

  # Published sites are meant to be iframed from anywhere; undo the
  # SAMEORIGIN default set by put_secure_browser_headers for this scope only.
  defp allow_embedding(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header("content-security-policy", "frame-ancestors *")
  end

  defp require_mailbox_enabled(conn, _opts) do
    if Application.get_env(:flux_web, :mailbox_enabled, false) do
      conn
    else
      conn |> send_resp(404, "Not Found") |> halt()
    end
  end

  ## Console (authenticated product area)

  scope "/console", FluxWeb do
    pipe_through [:browser, :require_authenticated_account]

    post "/workspaces/switch/:id", WorkspaceController, :switch
    get "/fluxes/:id/export", FluxDslController, :export

    live_session :console,
      on_mount: [
        {FluxWeb.AccountAuth, :require_authenticated},
        {FluxWeb.ConsoleHooks, :require_workspace}
      ] do
      live "/", ConsoleLive.Dashboard, :index
      live "/apps", ConsoleLive.Apps, :index
      live "/apps/:id", ConsoleLive.AppChat, :show
      live "/fluxes", ConsoleLive.Fluxes, :index
      live "/fluxes/:id", ConsoleLive.FluxEditor, :edit
      live "/knowledge", ConsoleLive.Knowledge, :index
      live "/plugins", ConsoleLive.Plugins, :index
      live "/tools", ConsoleLive.Tools, :index
      live "/members", ConsoleLive.Members, :index
      live "/audit", ConsoleLive.Audit, :index
    end

    # Workspace onboarding sits outside :require_workspace by design.
    live_session :console_onboarding,
      on_mount: [{FluxWeb.AccountAuth, :require_authenticated}] do
      live "/workspaces/new", ConsoleLive.WorkspaceNew, :new
    end
  end

  ## Authentication routes

  scope "/", FluxWeb do
    pipe_through [:browser, :require_authenticated_account]

    get "/invitations/accept/:token", InvitationController, :accept

    live_session :require_authenticated_account,
      on_mount: [{FluxWeb.AccountAuth, :require_authenticated}] do
      live "/accounts/settings", AccountLive.Settings, :edit
      live "/accounts/settings/confirm-email/:token", AccountLive.Settings, :confirm_email
    end

    post "/accounts/update-password", AccountSessionController, :update_password
  end

  scope "/", FluxWeb do
    pipe_through [:browser, :auth_rate_limit]

    live_session :current_account,
      on_mount: [{FluxWeb.AccountAuth, :mount_current_scope}] do
      live "/accounts/register", AccountLive.Registration, :new
      live "/accounts/log-in", AccountLive.Login, :new
      live "/accounts/log-in/:token", AccountLive.Confirmation, :new
    end

    post "/accounts/log-in", AccountSessionController, :create
    delete "/accounts/log-out", AccountSessionController, :delete
  end
end
