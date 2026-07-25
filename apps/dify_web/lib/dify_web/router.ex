defmodule DifyWeb.Router do
  use DifyWeb, :router

  import DifyWeb.AccountAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DifyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_account
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DifyWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", DifyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dify_web, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DifyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DifyWeb do
    pipe_through [:browser, :require_authenticated_account]

    live_session :require_authenticated_account,
      on_mount: [{DifyWeb.AccountAuth, :require_authenticated}] do
      live "/accounts/settings", AccountLive.Settings, :edit
      live "/accounts/settings/confirm-email/:token", AccountLive.Settings, :confirm_email
    end

    post "/accounts/update-password", AccountSessionController, :update_password
  end

  scope "/", DifyWeb do
    pipe_through [:browser]

    live_session :current_account,
      on_mount: [{DifyWeb.AccountAuth, :mount_current_scope}] do
      live "/accounts/register", AccountLive.Registration, :new
      live "/accounts/log-in", AccountLive.Login, :new
      live "/accounts/log-in/:token", AccountLive.Confirmation, :new
    end

    post "/accounts/log-in", AccountSessionController, :create
    delete "/accounts/log-out", AccountSessionController, :delete
  end
end
