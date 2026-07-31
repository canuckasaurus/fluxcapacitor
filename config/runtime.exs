import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

config :flux_web, FluxWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Releases don't run `mix phx.server`; PHX_SERVER=true starts the endpoint.
if System.get_env("PHX_SERVER") do
  config :flux_web, FluxWeb.Endpoint, server: true
end

# FLUX_SSRF_ALLOW: comma-separated hostnames exempt from the outbound
# HTTP guard (e.g. "localhost" for a local deploy calling local APIs).
if allow = System.get_env("FLUX_SSRF_ALLOW") do
  config :flux, Flux.SSRF,
    enabled: true,
    allow: allow |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# CODE_RUNNER_URL points at the internal flux-coderunner service; without
# it, code nodes fail with a clear configuration error.
if url = System.get_env("CODE_RUNNER_URL") do
  config :flux, Flux.CodeRunner.Sandbox,
    url: url,
    api_key: System.get_env("CODE_RUNNER_API_KEY")
end

# FLUX_MAILBOX=1 keeps delivered email in memory and serves the
# authenticated /dev/mailbox preview — for local deploys without a real
# mail adapter. Leave unset in any real production environment.
if config_env() == :prod and System.get_env("FLUX_MAILBOX") == "1" do
  config :flux_web, mailbox_enabled: true
  config :swoosh, local: true
end

# Storage backend toggle: STORAGE_BACKEND=s3 points at any S3-compatible
# endpoint (MinIO or AWS). Unset keeps the per-env default (:local in dev).
if System.get_env("STORAGE_BACKEND") == "s3" do
  bucket =
    System.get_env("S3_BUCKET") ||
      raise "STORAGE_BACKEND=s3 requires S3_BUCKET"

  config :flux, Flux.Storage, backend: :s3, bucket: bucket

  config :ex_aws,
    access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
    region: System.get_env("S3_REGION", "us-east-1")

  # S3_ENDPOINT (e.g. http://localhost:9000 for MinIO) switches off AWS.
  if endpoint = System.get_env("S3_ENDPOINT") do
    uri = URI.parse(endpoint)

    config :ex_aws, :s3,
      scheme: "#{uri.scheme}://",
      host: uri.host,
      port: uri.port
  end
end

# The vault master key encrypts per-workspace data-encryption keys. Dev and
# test ship static keys in their config files; prod requires the env var.
if config_env() == :prod do
  master_key =
    System.get_env("FLUX_MASTER_KEY") ||
      raise """
      environment variable FLUX_MASTER_KEY is missing.
      Generate one with: openssl rand -base64 32
      """

  config :flux, Flux.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(master_key)}
    ]
end

# FLUX_ROLE gates what this node runs: "all" (default) serves web and works
# jobs, "web" serves HTTP only (no Oban queues), "worker" works jobs only.
if config_env() != :test do
  case System.get_env("FLUX_ROLE", "all") do
    "web" ->
      config :flux, Oban, queues: false, plugins: false

    "worker" ->
      config :flux_web, FluxWeb.Endpoint, server: false

    "all" ->
      :ok

    other ->
      raise "invalid FLUX_ROLE=#{inspect(other)}; expected all | web | worker"
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :flux, Flux.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :flux_web, FluxWeb.Endpoint,
    url: [
      host: System.get_env("PHX_HOST", "localhost"),
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # If you are doing OTP releases, you need to instruct Phoenix
  # to start each relevant endpoint:
  #
  #     config :flux_web, FluxWeb.Endpoint, server: true
  #
  # Then you can assemble a release by calling `mix release`.
  # See `mix help release` for more information.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :flux_web, FluxWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :flux_web, FluxWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :flux, Flux.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.

  config :flux, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end

# FLUX_METRICS=1 exposes Prometheus metrics at GET /metrics (unauthenticated —
# keep it network-restricted or off on public deployments).
if System.get_env("FLUX_METRICS") in ~w(1 true) do
  config :flux_web, metrics_enabled: true
end

# FLUX_LOG_JSON=1 switches the default logger handler to structured JSON
# (one object per line; request_id and workspace metadata included).
if System.get_env("FLUX_LOG_JSON") in ~w(1 true) do
  config :logger, :default_handler,
    formatter: {LoggerJSON.Formatters.Basic, metadata: [:request_id, :workspace_id]}
end

# Standard OTEL env vars drive the exporter; setting the endpoint enables
# OTLP traces (Phoenix + Ecto + workflow-run spans).
if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry, traces_exporter: :otlp
end
