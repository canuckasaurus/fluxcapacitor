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
    plug FluxWeb.Plugs.Locale
    plug :fetch_current_scope_for_account
  end

  pipeline :api do
    plug :accepts, ["json", "scim+json"]
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

    # OpenAI-compatible: any OpenAI SDK with base_url swapped in.
    post "/chat/completions", OpenAIController, :create
    post "/embeddings", OpenAIController, :embeddings
    get "/models", OpenAIController, :models

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
    get "/spec", AppResourceController, :spec

    get "/datasets", DatasetController, :index
    post "/datasets", DatasetController, :create
    delete "/datasets/:id", DatasetController, :delete
    post "/datasets/:id/document/create-by-text", DatasetController, :create_by_text
    post "/datasets/:id/document/create-by-url", DatasetController, :create_by_url
    post "/workflows/batch", QualityController, :batch_create
    get "/batches/:id", QualityController, :batch_show
    get "/batches/:id/events", QualityController, :batch_events
    get "/eval-runs/:id/events", QualityController, :eval_events
    get "/eval-sets", QualityController, :eval_sets
    post "/eval-sets/:id/run", QualityController, :eval_run_create
    get "/eval-runs/:id", QualityController, :eval_run_show
    get "/labeling/projects", QualityController, :labeling_projects
    post "/labeling/projects/:id/tasks", QualityController, :labeling_tasks_create
    get "/labeling/projects/:id/next", QualityController, :labeling_next
    post "/labeling/tasks/:id/label", QualityController, :labeling_label
    get "/labeling/projects/:id/export", QualityController, :labeling_export
    # Moved from /v1/models in v0.5.0 — that path is now the
    # OpenAI-compatible listing so SDKs autodiscover.
    get "/registry/models", QualityController, :models
    post "/registry/models", QualityController, :model_register
    get "/notifications", QualityController, :notifications
    get "/conversation-evals", QualityController, :conversation_evals
    post "/conversation-evals/:id/run", QualityController, :conversation_eval_run
    get "/ab-stats", QualityController, :ab_stats
    get "/datasets/:id/retrieval-cases", QualityController, :retrieval_cases
    post "/datasets/:id/retrieval-cases", QualityController, :retrieval_case_create
    post "/datasets/:id/retrieval-eval", QualityController, :retrieval_eval

    get "/datasets/:id/documents", DatasetController, :documents
    delete "/datasets/:id/documents/:document_id", DatasetController, :delete_document
    get "/datasets/:id/documents/:document_id/segments", DatasetController, :segments
    post "/datasets/:id/retrieve", DatasetController, :retrieve
  end

  scope "/", FluxWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Run-file downloads (the file_… token is the authorization)

  scope "/files", FluxWeb do
    pipe_through :browser

    get "/:token", FileController, :download
  end

  ## Load-balancer probes (no auth, no CSRF; probe with Host: localhost
  ## or x-forwarded-proto to clear force_ssl in prod)

  scope "/health", FluxWeb do
    pipe_through :api

    get "/", HealthController, :index
    get "/ready", HealthController, :ready
  end

  # SAML SSO (Samly): metadata, request, and assertion-consumer routes.
  # The IdP POSTs assertions here, so CSRF stays off; the session is
  # still fetched so the assertion lands in it.
  pipeline :saml do
    plug :accepts, ["html"]
    plug :fetch_session
  end

  scope "/sso" do
    pipe_through :saml

    forward "/", Samly.Router
  end

  scope "/auth", FluxWeb do
    pipe_through [:browser]

    get "/saml/complete", SamlController, :complete
  end

  # Public status page (HTML for humans, JSON for scripts and monitors
  # like Uptime Kuma).
  scope "/status", FluxWeb do
    pipe_through :browser

    get "/", StatusController, :show
  end

  scope "/status", FluxWeb do
    pipe_through :api

    get "/json", StatusController, :show_json
  end

  # Shared run traces: the signed token in the URL is the authorization.
  scope "/share", FluxWeb do
    pipe_through :browser

    get "/runs/:token", RunShareController, :show
  end

  ## Public published app sites (token in path is the authorization)

  scope "/site", FluxWeb do
    pipe_through [:browser, :allow_embedding, :ensure_site_visitor]

    live_session :public_site do
      live "/flux/:token", SiteLive.FluxSite, :show
      live "/:token", SiteLive.AppSite, :show
    end
  end

  # FluxCapacitor as an MCP server: published fluxes are callable tools.
  # A workspace `ws-` key in the Authorization header names the workspace.
  scope "/mcp", FluxWeb do
    pipe_through :api

    post "/", McpController, :handle
  end

  ## Public workflow triggers (token in path is the authorization)

  scope "/triggers", FluxWeb do
    pipe_through :api

    post "/webhook/:token", TriggerController, :webhook
  end

  # SCIM 2.0 provisioning (IdP-driven); the bearer token names the workspace.
  scope "/scim/v2", FluxWeb do
    pipe_through :api

    get "/Users", ScimController, :index
    post "/Users", ScimController, :create
    get "/Users/:id", ScimController, :show
    patch "/Users/:id", ScimController, :patch
    put "/Users/:id", ScimController, :put
    delete "/Users/:id", ScimController, :delete
  end

  # Endpoint plugins: workspace installations serve HTTP under their token.
  scope "/e", FluxWeb do
    pipe_through :api

    match :*, "/:token", PluginEndpointController, :handle
    match :*, "/:token/*path", PluginEndpointController, :handle
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
  scope "/dev" do
    pipe_through [:browser, :require_mailbox_access]

    forward "/mailbox", Plug.Swoosh.MailboxPreview
  end

  # Published sites are meant to be iframed from anywhere; undo the
  # SAMEORIGIN default set by put_secure_browser_headers for this scope only.
  defp allow_embedding(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header("content-security-policy", "frame-ancestors *")
  end

  # A stable anonymous visitor ref in the signed session cookie, so
  # returning visitors get their public-site conversation back.
  defp ensure_site_visitor(conn, _opts) do
    if get_session(conn, "site_visitor") do
      conn
    else
      ref = "web_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      put_session(conn, "site_visitor", ref)
    end
  end

  # Local dev skips authentication — a brand-new user needs the mailbox
  # to read their *first* magic link, before they can possibly log in.
  # Opt-in release mailboxes stay auth-gated: they expose every
  # delivered email, and the first account there arrives via seeds/SSO.
  defp require_mailbox_access(conn, opts) do
    cond do
      not Application.get_env(:flux_web, :mailbox_enabled, false) ->
        conn |> send_resp(404, "Not Found") |> halt()

      Application.get_env(:flux_web, :dev_routes, false) ->
        conn

      true ->
        require_authenticated_account(conn, opts)
    end
  end

  ## Console (authenticated product area)

  scope "/console", FluxWeb do
    pipe_through [:browser, :require_authenticated_account]

    post "/workspaces/switch/:id", WorkspaceController, :switch
    get "/palette", PaletteController, :index
    get "/fluxes-export", FluxDslController, :export_many
    get "/workspace-export", WorkspaceExportController, :export
    get "/usage-export", WorkspaceExportController, :usage
    get "/runs-export", WorkspaceExportController, :runs
    get "/audit-export", WorkspaceExportController, :audit
    post "/workspace-import", WorkspaceExportController, :import
    get "/fluxes/:id/export", FluxDslController, :export
    get "/fluxes/:id/svg", FluxDslController, :export_svg
    get "/fluxes/:id/runs/:run_id/fixture", FluxDslController, :run_fixture
    get "/fluxes/:id/batches/:batch_id/results", FluxDslController, :batch_results
    get "/fluxes/:id/evals/:eval_run_id/results", FluxDslController, :eval_results
    get "/apps/:id/export", FluxDslController, :export_app
    get "/apps/:id/conversations/:conversation_id/export", FluxDslController, :conversation_export
    get "/apps/:id/finetune-export", FluxDslController, :finetune_export
    get "/apps/:id/monitor-export", FluxDslController, :monitor_export
    get "/labeling/:id/export", FluxDslController, :labeling_export
    get "/templates/:id/file", DocTemplateController, :file
    post "/templates/:id/test-render", DocTemplateController, :test_render

    live_session :console,
      on_mount: [
        FluxWeb.Plugs.Locale,
        {FluxWeb.AccountAuth, :require_authenticated},
        {FluxWeb.ConsoleHooks, :require_workspace}
      ] do
      live "/", ConsoleLive.Dashboard, :index
      live "/apps", ConsoleLive.Apps, :index
      live "/apps/:id", ConsoleLive.AppChat, :show
      live "/apps/:id/monitor", ConsoleLive.AppMonitor, :show
      live "/fluxes", ConsoleLive.Fluxes, :index
      live "/fluxes/:id", ConsoleLive.FluxEditor, :edit
      live "/fluxes/:id/batches", ConsoleLive.FluxBatches, :index
      live "/fluxes/:id/evals", ConsoleLive.FluxEvals, :index
      live "/knowledge", ConsoleLive.Knowledge, :index
      live "/labeling", ConsoleLive.Labeling, :index
      live "/runs", ConsoleLive.Runs, :index
      live "/files", ConsoleLive.Files, :index
      live "/notifications", ConsoleLive.Notifications, :index
      live "/admin", ConsoleLive.Admin, :index
      live "/plugins", ConsoleLive.Plugins, :index
      live "/tools", ConsoleLive.Tools, :index
      live "/playground", ConsoleLive.Playground, :index
      live "/templates", ConsoleLive.DocTemplates, :index
      live "/interviews", ConsoleLive.Interviews, :index
      live "/docs", ConsoleLive.Docs, :index
      live "/docs/:guide", ConsoleLive.Docs, :index
      live "/members", ConsoleLive.Members, :index
      live "/audit", ConsoleLive.Audit, :index
      live "/settings", ConsoleLive.WorkspaceSettings, :edit
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
      on_mount: [FluxWeb.Plugs.Locale, {FluxWeb.AccountAuth, :mount_current_scope}] do
      live "/accounts/register", AccountLive.Registration, :new
      live "/accounts/log-in", AccountLive.Login, :new
      live "/accounts/log-in/:token", AccountLive.Confirmation, :new
    end

    post "/accounts/log-in", AccountSessionController, :create
    delete "/accounts/log-out", AccountSessionController, :delete

    # OIDC single sign-on (no-ops unless FLUX_OIDC_* is configured).
    get "/auth/oidc", OIDCController, :request
    get "/auth/oidc/callback", OIDCController, :callback
  end
end
