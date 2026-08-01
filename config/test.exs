import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :flux, Flux.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flux_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Inline testing mode: jobs execute synchronously in the calling process.
config :flux, Oban, testing: :manual

config :flux, Flux.Storage,
  backend: :local,
  local_path: "tmp/storage_test#{System.get_env("MIX_TEST_PARTITION")}"

# Static test-only master key for the vault (never use outside test).
config :flux, Flux.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("2vURG4dNJvXYi9YsdSF4bTOezOM3wpjJol3Ee+A+rFA=")}
  ]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :flux_web, FluxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VQIYJoe9OJJyRQVj1WtBvGhJXtWQ1qHWmzGX8caSvwerKZr7i9ZTkjF+ay9Epsum",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# In test we don't send emails
config :flux, Flux.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Keep tests hermetic: no DNS resolution in the SSRF guard.
config :flux, Flux.SSRF, enabled: false

# OIDC pointed at a stubbed provider (see oidc_controller_test.exs).
config :flux_web, FluxWeb.OIDC,
  issuer: "https://sso.example.com",
  client_id: "flux-client",
  client_secret: "flux-secret",
  name: "Example SSO"

# No rate limiting in tests.
config :flux_web, rate_limit_enabled: false

# Exercise the /metrics route in tests.
config :flux_web, metrics_enabled: true
