# Operations

Running FluxCapacitor for a team: cost controls, safety rails,
observability, and backups. Everything here lives in **Settings**,
the **admin panel** (`FLUX_ADMIN_EMAILS`), or an environment variable.

## Health & self-checks

- `GET /health` — liveness (the VM answers).
- `GET /health/ready` — readiness: database + storage checks, `503`
  with per-check detail when degraded. In prod, probe with
  `Host: localhost` (or through your proxy with `x-forwarded-proto`)
  so `force_ssl` doesn't bounce the probe.
- `mix flux.doctor` — one line per configured service (database,
  storage, Oban, Tika, Gotenberg, coderunner, vector backend,
  metrics). `skipped` means not configured; the task exits non-zero
  on any failure, so it slots into deploy scripts.

## Cost controls

All per-workspace, in Settings → Cost controls:

- **Monthly token budget** — warns at 80% (a `budget_warning`
  notification), refuses new runs past the cap. Individual fluxes can
  carry their own monthly cap on top (editor → API panel).
- **Model price overrides** — price self-hosted and fine-tuned models
  per million tokens so cost rollups stop reading $0.
- **Concurrent-run cap** — bounds simultaneous interactive runs;
  batches and evals are exempt (they already run sequentially).
- **LLM cache** — identical prompts answer from memory within the
  TTL; repeated batch/eval runs stop paying twice.
- **Per-node caching** — deterministic nodes (HTTP, code) opt in with
  `cache_minutes` on the canvas; identical inputs skip the call.
- **Per-app daily token limits** — refusals return 429 on the API.
- **Per-app monthly cost budget** — caps an app's estimated USD spend
  for the month (Chat settings). The team is warned at 80% and again
  at 100% (`budget_warning`, once per level per month, emailable like
  any notification kind); past the cap the app answers like a spent
  daily limit.
- **Per-app rate limits** — each app can override the 120 req/min
  pipeline default for its own tokens (Chat settings).
- **Credential load balancing** — under Plugins, flag several keys of
  one provider into the pool ("Pool"): calls rotate across pooled keys
  round-robin and fail over to the next key on 429/quota/5xx errors.
  Unpooled setups keep resolving the default key.

Track spend on the Runs page (cost by flux, CSV export), the
dashboard rollups, and the Grafana panels (tokens/h, est. USD/h).

## Guardrails

Settings → Guardrails: newline-separated case-insensitive regexes
checked against chat and run inputs. `block` refuses the input;
`flag` lets it through. Either way a `guardrail` notification fires
(routable to webhooks). Outputs are always flag-only — the tokens are
already spent, so the team gets told instead of the user getting a
hole in the reply.

Two more gates run beside the patterns:

- **Model-backed moderation** — the workspace default model judges
  inputs against a written policy (one extra call per checked
  message). Judge failures allow.
- **External moderation API** — checked text POSTs to your own
  endpoint as `{"text", "context"}`; it answers
  `{"flagged": bool, "reason": …}` within 5 s. Choose `block` or
  `flag` for hits, and `fail open` (endpoint down ⇒ traffic passes)
  or `fail closed` (endpoint down ⇒ inputs refuse) for outages. The
  endpoint URL is SSRF-guarded.

## Chat channels

- **Inbound email**: App → Email channel mints a webhook URL
  (`/channels/email/emch_…`). Point a mail provider's inbound route
  (Mailgun, SES, Postmark) at it: sender + body become a chat turn,
  one conversation per correspondent, and the finished reply is mailed
  back from the platform's from-address. Guardrails and app limits
  apply like any other turn.

The human side of chat runs from the app monitor: a **live feed** (new
conversations and messages appear without a reload, changed threads
marked "new"), **typing indicators** both ways during handoffs,
**assignment** with mine/unassigned filters, **internal notes** the
visitor never sees, **resolve states** (a fresh visitor message
reopens), one-click **saved replies**, and a per-app **business-hours
schedule** (UTC; outside it the site shows an away note and stops
offering a human). A **handoff SLA alert** (Settings → Failure alerts)
fires a notification when a visitor waits longer than the configured
minutes, once per request.

## Notifications & webhooks

Every operational event lands in the in-console feed (filterable by
kind, per-item or bulk mark-read) and can route to signed webhooks:
endpoints subscribe per event (`run.*`, `notification.*`,
`document.indexed`/`document.failed`/`dataset.synced` for knowledge
ingestion, `conversation.started`/`message.completed`/
`handoff.requested` for chat lifecycle — CRM and analytics sync
without polling, …), payloads
are HMAC-SHA256 signed (`x-flux-signature`), deliveries are logged
with per-attempt outcomes and manual retry, and the **Send test**
button fires a `webhook.test` event so you can verify a receiver
before anything real depends on it.

## Observability

- `FLUX_METRICS=1` exposes Prometheus metrics at `/metrics` — HTTP,
  LiveView, Ecto, Oban, BEAM, plus run counts/durations/tokens/cost.
- `docker compose --profile metrics up -d` runs Prometheus and a
  provisioned Grafana (localhost:3001, admin/fluxgrafana) with the
  FluxCapacitor dashboard ready.
- The admin panel shows **per-provider health** (calls, errors, error
  rate since boot) — "is it us or the provider" at a glance.
- OpenTelemetry traces and structured JSON logs are one env var each
  (`OTEL_EXPORTER_OTLP_ENDPOINT`, `FLUX_LOG_JSON=1`).
- API responses carry `x-ratelimit-limit` / `x-ratelimit-remaining`;
  429s add `Retry-After`.
- The instance admin panel (`FLUX_ADMIN_EMAILS`) shows **background
  jobs**: queue depths by state, retryable/discarded jobs with their
  last error, and retry/cancel buttons.

## MCP

- **Consume**: Tools → MCP servers registers any Model Context Protocol
  server (Streamable HTTP). Its tools join the picker for tool and
  agent nodes; auth headers are stored encrypted per workspace.
- **Serve**: `POST /mcp` speaks JSON-RPC 2.0 with a workspace `ws-` key
  as the bearer token. Every published flux is advertised as a tool
  (input schema from its start variables); `tools/call` runs the flux
  synchronously and returns its outputs. The prompt library serves as
  MCP prompts and dataset documents as MCP resources. Point Claude
  Desktop or any MCP client at `https://your-host/mcp`.

## OpenAI compatibility

`POST /v1/chat/completions` with an `app-` bearer token maps any
OpenAI SDK onto a chat app — blocking or streaming (`stream: true`,
`chat.completion.chunk` frames, `data: [DONE]`). Stateless: the caller
sends the whole history; the request's `model` field is ignored (the
app decides, including its fallback). Chatflow apps work too — the
bound flux runs with the last user message as the query and earlier
turns as `{{sys.history}}`. Quotas, guardrails, moderation, and the
app's own rate limit all apply.

Direct-model apps also speak **function calling** (`tools` pass
through; `tool_calls` answer with `finish_reason: "tool_calls"`;
`tool`-role results round-trip) and **structured outputs**
(`response_format` `json_schema` — forced via a respond tool,
validated against the schema with one corrective retry, honest 502
when the model can't comply; `json_object` injects an instruction).
The two cannot be combined on one request, and chatflow apps refuse
both — their flux runs its own tools. `GET /v1/models` lists provider
models (the app's bound model first) for SDK autodiscovery, and
`POST /v1/embeddings` covers embedding models. `POST /v1/moderations`
answers in the OpenAI moderation shape, judged by the workspace
guardrails (deny patterns + the LLM moderation policy) — the
simplified category set is `pattern` and `policy`.

## Status page

- `GET /status` (public, no login): component health from the doctor
  checks plus an incident note editable in the admin panel.
  `GET /status/json` answers the same for scripts.
- Optional external monitor: `docker compose --profile uptime up -d`
  starts Uptime Kuma on :3002 — point its checks at
  `http://app:4000/health/ready` and `/status/json` for alerting
  history and hosted public status beyond the native page.

## Alerting

`ops/alerts.yml` ships five Prometheus rules (app down, 5xx rate, run
failures, Oban backlog, BEAM memory), loaded automatically by the
compose Prometheus. Add an `alerting:` block in `ops/prometheus.yml`
to point them at your Alertmanager, or surface them in Grafana.
Metric names are verified against the live `/metrics` endpoint.

## Email

- `FLUX_SMTP_HOST/PORT/USERNAME/PASSWORD/SSL` + `FLUX_MAIL_FROM`
  enable delivery; `PHX_HOST` builds console links inside the mails.
- Members opt into notification kinds per account (Settings → Email
  notifications) — run failures, budget warnings, the weekly digest,
  handoff requests, and the monthly cost report (1st of the month,
  last month's tokens, estimated USD, and top fluxes).
- Webhook endpoints take a **Slack format** option: events post as
  Block Kit, ready for an incoming-webhook URL.
- **Email branding** (Settings → Email branding): a workspace from-name
  and reply-to applied to outbound workspace mail — invites,
  notification emails, transcripts, away notes, email-channel replies —
  including the `[Name]` subject prefix. The sending address stays
  `FLUX_MAIL_FROM` (your SMTP sender domain); account mail (magic
  links, security alerts) stays platform-branded.

## SAML single sign-on

Native SP-side SAML 2.0 (Samly/esaml) beside the OIDC login:

- `SAML_IDP_METADATA_FILE` — path to the IdP's metadata XML (mount it
  into the container). Setting this is what turns SAML on; the login
  page grows a "Continue with SSO" button.
- `SAML_SP_ENTITY_ID` — SP entity id (defaults to the app URL).
- `SAML_SP_KEY` / `SAML_SP_CERT` — PEM paths, only when the IdP
  requires signed requests (`openssl req -x509 -newkey rsa:2048
  -nodes -days 1095` makes a pair).
- `SAML_REQUIRE_SIGNED=0` — accept unsigned assertions (leave unset in
  production).

Point the IdP at `<base>/sso/sp/metadata/idp` for SP metadata; it
POSTs assertions to `<base>/sso/sp/consume/idp`. The email attribute
(`email`, `mail`, the OID form, or the XML-SOAP claim — the subject as
a fallback) provisions or resolves an account exactly like OIDC.

## Account security

- **Session lifetime**: console sessions live 14 days by default;
  `FLUX_SESSION_VALIDITY_DAYS` tightens that instance-wide. The check
  runs at verify time, so lowering it also ends sessions already past
  the new window. `FLUX_SESSION_IDLE_MINUTES` adds an independent
  inactivity timeout (5–10080): a session unused that long is dead
  even with absolute lifetime remaining.
- **Login throttling**: the login POST is rate-limited per IP (10/min)
  and per email address across IPs (15 per 15 minutes) — the second
  bucket is what stops a distributed guesser rotating addresses.
  Lockouts land in the audit trail as `account.login_throttled`.
- **Audit retention**: the audit trail is kept forever by default. A
  per-workspace `audit retention` setting (Settings -> Data retention,
  min 30 days) opts into pruning for data-minimization policies.

- **TOTP 2FA**: every account can enroll from Account settings — scan
  the QR (or type the base32 key) into any authenticator app, confirm
  with a first code, and store the eight one-time recovery codes.
  Password logins then detour through a code challenge; magic-link,
  OIDC, and SAML logins are unaffected (those factors belong to the
  mailbox/IdP). Turning 2FA off discards the secret and codes.
- **API IP allowlist** (Settings → API IP allowlist): one address or
  CIDR per line; when set, `/v1` calls from anywhere else answer 403
  `ip_forbidden` even with a valid key, and the attempt lands in the
  audit trail as `api.ip_rejected`. The check runs on the socket's
  remote address — behind a reverse proxy, forward the client address
  (or the list ends up describing your proxy).
- **Per-key rate limits**: any API key (app, flux, or workspace kind)
  can carry its own requests/minute cap, set when minting. A capped
  key gets its own bucket; key limit beats the app's chat-settings
  limit beats the pipeline default (60/min).
- **Site passcodes**: a published app site can require a passcode
  (App → Site → Passcode) — visitors enter it once per browser
  session. It's a share-gate, not authentication: rotate it by saving
  a new one, remove it by saving blank.
- **Passkeys**: accounts can register WebAuthn credentials (platform
  authenticators, security keys) from Account settings and sign in
  password-free from the login page. Verification is pure Elixir
  (`wax`); registration and login both require the browser to be on
  the configured origin, so set `FLUX_BASE_URL` correctly.
- **SSO role mapping, three ways**: SCIM Groups push role changes,
  and the workspace's claim→role mapping (Settings → Digest &
  branding) now applies to both OIDC id-token claims *and* SAML
  assertion attributes on every login.
- **New-device alerts**: a sign-in from an ip + browser pair no
  earlier session used emails the account automatically (the very
  first session stays quiet — everything is new then). The email
  points at Account settings → Sessions for revocation.
- **SCIM Groups**: alongside `/scim/v2/Users`, `/scim/v2/Groups`
  accepts IdP group pushes where the group id is the role — put
  people in an `editor` group in Okta/Entra and their workspace role
  follows. Removal returns them to `normal`; owners never move.
- **OIDC claim→role mapping**: OIDC-only shops get the same role sync
  without SCIM. Settings → Digest & branding takes a claim name (say
  `groups`) and `value=role` lines; every SSO login re-applies the
  mapping to that workspace's membership. Owners and unmatched
  members are never touched — removal stays a human decision.
- **Browser push**: each member can enable Web Push per browser from
  Account settings. Handoff requests and run failures then reach the
  desktop even with the console closed. The VAPID keypair is minted
  automatically on first use and lives in instance settings — no
  external push service. Requires HTTPS (or localhost) for the
  service worker.
- **Workspace default language**: Settings → Digest & branding can
  pin a console language used when a member hasn't picked one and
  their browser doesn't negotiate one; explicit `?locale=` choices
  and browser preferences still win over it.

## Backups & retention

- **Scheduled backups**: `FLUX_SCHEDULED_BACKUPS=true` writes every
  workspace's export archive through the storage layer (S3 in
  production, `backups/<date>/…`) nightly after 03:00 UTC, once per
  calendar day — the cron-free sibling of `mix flux.backup`.
  Individual workspace failures are logged, never fatal.

- **Export** (Settings → Export): the whole workspace — fluxes, apps,
  datasets, eval sets, labeling projects, retrieval cases — as one
  JSON archive. Secrets are never included. **Schedule backups** with
  a cron; archives land on the Files page and fire an `export_ready`
  notification.
- **Import** adds an archive's contents to a workspace without
  touching existing data.
- **Retention** prunes runs and chat messages past N days (blank
  keeps forever). Trash (fluxes, apps, datasets, labeling projects)
  purges after 30 days; notifications sweep at 90 days, webhook
  delivery logs at 30.
- **Remembered URL sources** re-fetch nightly at 03:00 UTC, replacing
  their documents in place.

### Restore runbook

Rehearsed against a live deployment (see the parity ledger, entry 40).
To restore a workspace from an export archive:

1. **Have the archive** — a scheduled backup from the Files page, or a
   manual download from Settings → Export.
2. **Create (or pick) the target workspace** and make it current, then
   import via Settings → Import archive. Headless, the same drill is:

   ```
   docker exec <app-container> bin/flux rpc '
   account = Flux.Repo.get_by!(Flux.Accounts.Account, email: "you@example.com")
   {:ok, {workspace, _}} = Flux.Accounts.create_workspace(account, %{name: "Restored"})
   {:ok, _} = Flux.Accounts.switch_workspace(account, workspace.id)
   scope = Flux.Accounts.scope_for(Flux.Repo.get!(Flux.Accounts.Account, account.id))
   {:ok, counts} = Flux.Import.workspace(scope, File.read!("/path/to/export.json"))
   IO.inspect(counts)
   '
   ```

3. **Verify counts** — the import reports fluxes/apps/datasets/documents
   restored, with warnings for anything skipped.
4. **Rebind cross-references** — a chatflow's flux binding and provider
   credentials (never exported) need reconnecting by hand.
5. Imported documents re-index automatically; retrieval works as soon
   as indexing completes.

Postgres itself should also be backed up (`pg_dump` or volume
snapshots) — the JSON archive is the portable, workspace-granular
layer, not a full database replacement.

## Performance baselines

Round-2 load guards (run with `mix test --include perf apps/flux_web/test/perf`),
measured on the dev workstation, echo provider:

- **50 concurrent chat sessions**: all stream to completion in ~350 ms
  wall clock (~6 ms amortized per session).
- **100-row batch**: completes in ~7.4 s (~13.5 rows/s) through the
  full engine + persistence path.
- **Corpus scale** (round 1, 10k segments / 1k conversations): hybrid
  retrieval ~ms-hundreds, monitor reads and usage rollups well under
  their 3 s ceilings.

## Scheduled things, at a glance

| What | When | Where configured |
|---|---|---|
| Schedule/plugin triggers | per cron/interval | Editor → Triggers |
| Recurring batches | per cron | Flux → Batches → Repeat |
| Scheduled evals | per cron | Flux → Evals |
| Scheduled retrieval evals | per cron | Knowledge → Settings |
| Scheduled conversation evals | per cron | App → Monitoring |
| Scheduled exports | per cron | Settings → Export |
| URL source re-fetch | 03:00 UTC daily | Knowledge → re-fetch nightly |
| Trash purge & log sweeps | nightly | automatic |
| Weekly digest | Monday 08:00 UTC | automatic |
| Cost-spike check | 08:10 UTC daily | automatic |
| Schedule watchdog | 08:20 UTC daily | automatic |

Cron fields show a **next fire** preview wherever you enter them.
