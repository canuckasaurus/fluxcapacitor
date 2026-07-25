# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :flux, :scopes,
  account: [
    default: true,
    module: Flux.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:account, :id],
    schema_key: :account_id,
    schema_type: :binary_id,
    schema_table: :accounts,
    test_data_fixture: Flux.AccountsFixtures,
    test_setup_helper: :register_and_log_in_account
  ]

# Configure Mix tasks and generators
config :flux,
  ecto_repos: [Flux.Repo]

# Background jobs. Queue names are the platform's stable vocabulary — workers
# reference them by atom, so add queues here rather than renaming.
config :flux, Oban,
  engine: Oban.Engines.Basic,
  repo: Flux.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ],
  queues: [
    default: 10,
    ingest: 5,
    embed: 8,
    mail: 10,
    bulk: 5,
    cleanup: 2,
    triggers: 5,
    provisioning: 5,
    export: 2,
    run_persist: 10
  ]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :flux, Flux.Mailer, adapter: Swoosh.Adapters.Local

config :flux_web,
  ecto_repos: [Flux.Repo],
  generators: [context_app: :flux, binary_id: true]

# Symlinking node_modules requires elevated privileges on Windows; we don't
# import from assets/node_modules in hooks, so the warning is noise.
config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

# Configures the endpoint
config :flux_web, FluxWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FluxWeb.ErrorHTML, json: FluxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Flux.PubSub,
  live_view: [signing_salt: "CoZ8DlXK"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  flux_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/flux_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  flux_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/flux_web", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
