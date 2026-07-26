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

  scope "/", FluxWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", FluxWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
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
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Console (authenticated product area)

  scope "/console", FluxWeb do
    pipe_through [:browser, :require_authenticated_account]

    post "/workspaces/switch/:id", WorkspaceController, :switch

    live_session :console,
      on_mount: [
        {FluxWeb.AccountAuth, :require_authenticated},
        {FluxWeb.ConsoleHooks, :require_workspace}
      ] do
      live "/", ConsoleLive.Dashboard, :index
      live "/fluxes", ConsoleLive.Fluxes, :index
      live "/knowledge", ConsoleLive.Knowledge, :index
      live "/plugins", ConsoleLive.Plugins, :index
      live "/members", ConsoleLive.Members, :index
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
    pipe_through [:browser]

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
