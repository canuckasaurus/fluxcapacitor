# Changelog

All notable changes to FluxCapacitor are recorded here. The format loosely
follows [Keep a Changelog](https://keepachangelog.com/); the project follows
semantic versioning once past 1.0. Detailed build history lives in the ledger
at `docs/PARITY-PLAN.md`.

## Unreleased

### Batch 40
- External knowledge bases: register a user-hosted retrieval endpoint
  as a dataset (Dify-compatible `/retrieval` contract) — its records
  flow into answers, citations, hit testing, and retrieval evals like
  local chunks. API key DEK-encrypted; endpoint SSRF-guarded.
- External moderation API: guardrails can POST checked text to your
  own endpoint alongside the regex patterns and the model judge —
  block or flag on a hit, fail-open or fail-closed when it's down.
- Credential load balancing: flag several provider keys into a pool
  and calls rotate across them round-robin, failing over to the next
  key on rate limits and provider outages.
- Embed origin lockdown: an app can list the origins allowed to
  iframe its published site; the site's `frame-ancestors` CSP narrows
  from `*` to exactly that list.
- Conversation assignment: assign any conversation to a specific
  member from the monitor (beyond self-claim on handoffs), with
  mine/unassigned filters so two humans stop answering one visitor.
- Canned replies: workspace-shared reply snippets, inserted into a
  handoff answer with one click.
- Budget alert emails: apps at 80% and then 100% of their monthly
  cost budget notify the team once per level — the hard cutoff is no
  longer the first warning.

### Batch 39
- Passkeys (WebAuthn): register platform authenticators from account
  settings and sign in without a password — pure-Elixir `wax`, no
  external auth service. TOTP stays.
- Inbound email chat channel: a per-app webhook address turns mail
  into chat turns (one thread per correspondent) and mails the model's
  reply back.
- Dataset file API: `/v1/datasets/:id/document/create-by-file`
  (multipart, extraction included) and
  `…/documents/:id/update-by-text` (old content becomes a revision).
- Idempotency keys: an `Idempotency-Key` header on `/v1` POSTs replays
  the stored JSON response instead of double-running; keys live a day.
- App monthly cost budget: cap an app's estimated monthly spend; past
  it the app answers like a spent daily limit. (Also fixed a latent
  crash: cost rollups mishandled `Pricing.estimate`'s tuple return for
  priced models.)
- Per-member usage: a "who is spending" table on the dashboard from
  run attribution.
- Live visitor presence: the app monitor shows how many visitors have
  the site open right now; a human reply to a visitor who left (and
  shared an email) sends a heads-up mail with the site link.
- Run bookmarks: pin runs above the scroll, per account.
- Guardrail preset library: one-click PII patterns (emails, phones,
  cards, IBANs) for the deny/redact lists.
- SAML attribute→role mapping: the same SSO role mapping OIDC uses now
  also applies to SAML assertions — the trio (SCIM, OIDC, SAML) is
  complete.

### Batch 38
- Public-site localization: every visitor-facing site string runs
  through gettext with browser negotiation — German, Spanish, and
  French ship translated.
- Per-email login throttling: alongside the per-IP limit, one email
  hammered from many addresses locks for fifteen minutes (audited).
- Session idle timeout: `FLUX_SESSION_IDLE_MINUTES` ends sessions
  unused that long, independent of the absolute lifetime.
- OpenAI Responses API: `POST /v1/responses` (blocking + SSE event
  stream) — the endpoint new OpenAI SDKs default to.
- Chat document uploads: PDFs, Office files, and text ride into
  console and site chats; text is extracted once at upload (Tika /
  native) and appended to the model's context.
- Site voice input: the mic button and provider transcription reach
  the public site.
- `GET /v1/messages/:id/suggested`: follow-up question suggestions
  over the API (reference-compatible).
- Dataset-scoped API keys: `ds-` tokens open exactly one dataset's
  knowledge endpoints — share a KB without workspace-wide power.
- Flux and app tags: comma-separated labels with filter chips on both
  index pages (runs already had them).
- OIDC claim→role mapping: workspace roles follow a configured
  id-token claim on every SSO login (the OIDC sibling of SCIM Groups).
- OpenAPI toolset import by URL: fetch a spec instead of pasting it
  (SSRF-guarded) — the honest reading of "plugin install from URL";
  plugins are compiled modules, toolsets are data.
- Scheduled backups: `FLUX_SCHEDULED_BACKUPS=true` dumps every
  workspace's export archive through the storage layer (S3 in
  production) nightly after 03:00 UTC, once per day.

### Batch 37 (mega)
- API citations: `/v1/chat-messages` responses (blocking and the SSE
  `message_end` event) carry `metadata.retriever_resources` — the
  knowledge sources behind a chatflow answer, in the reference shape.
- `GET /v1/usage`: daily token and estimated-cost totals across flux
  runs and chat replies (`?days=`, workspace or app token).
- New-device login alerts: a sign-in from an ip/browser pair no earlier
  session used emails the account (first-ever sessions stay quiet).
- Message edit & retry: rewrite your last console-chat message in place
  and regenerate the reply — later turns are discarded, guardrails
  re-apply.
- Trigger "Fire now": start a run from any trigger's stored inputs
  straight from the editor, no waiting for cron, webhook, or mail.
- Document download: a per-document button in the knowledge browser
  streams the stored original (behind its own long-dormant
  `dataset_document_download` permission).
- Audit actor filter: narrow the audit trail (and its CSV export) to
  one member.
- Workspace default locale: a console language that fills in when a
  member never picked one and their browser doesn't say.
- Browser push notifications: native Web Push (VAPID + aes128gcm on
  `:crypto`, no push SDK) for handoff requests and run failures —
  subscribe per browser from account settings.
- Visitor transcript email: site visitors who shared their email can
  have the conversation mailed to them.
- Prompt-snippet picker: the prompt library is insertable into an app's
  system prompt (which also gained a proper editing card in app
  settings).
- SCIM Groups: `/scim/v2/Groups` maps IdP group pushes onto workspace
  roles (Okta value-list and Entra filtered-path styles; owners never
  move).

### Batch 36 (mega)
- Webhook secret rotation: one click regenerates an endpoint's
  `whsec_` (shown once) with an audit entry.
- App settings snapshots: named copies of an app's configuration with
  restore — the undo app edits never had (capped at twenty).
- Document revision history: replace-mode uploads keep the outgoing
  content as a restorable revision (last five per name); restoring
  stacks today's content as the newest revision, never destroying.
- Quiet hours: per-account UTC window; notification emails inside it
  defer to the window's end via a scheduled job (the feed is
  unaffected).
- Prompt A/B: test an alternative system prompt on a share of
  conversations, with per-arm feedback stats beside the model A/B.
- Favorites: star fluxes and apps (per account); starred float to the
  top of their index pages.
- Fallback chains: an ordered list of backup models tried in sequence
  after the single fallback.
- Conversation cost rollup: per-conversation tokens and estimated cost
  in the monitor drill-in.
- Handoff SLA: median time-to-first-human-reply (30 days) on the
  monitor's handoff queue.
- Import DSL from URL: paste a link to import a flux (SSRF-guarded).
- Console branding: a workspace logo replaces the sidebar wordmark for
  white-label deployments.
- Dataset embedding meter: approximate embedded tokens per dataset
  (chars/4 per indexing pass) — embedding spend was invisible.
- Digest frequency: the activity digest becomes weekly, daily, or off
  per workspace.

### Batch 35
- Visitor identity capture: an optional pre-chat name/email form on
  public sites (per-app toggle), stored on the conversation and shown
  in the monitor and handoff queue — anonymous `web_…` refs become
  contactable people.
- Scheduled publish: publish the draft at a chosen time (one-shot,
  UTC) from the publish dropdown; the scheduler performs it and gate
  evals still apply. A failed publish notifies instead of shipping.
- Document expiry: an optional per-document date; the nightly sweep
  disables expired documents so they drop out of retrieval — for
  content that's only true until a date.
- Handoff assignment: claim or release handoff conversations; the
  queue shows who owns what, so two agents stop answering the same
  visitor.
- Palette deep search: typing three or more characters into Ctrl+K
  also searches conversation titles and run inputs/outputs
  server-side, with deep links that open the monitor conversation or
  expand the run.

### Batch 34
- API-key expiry warnings: keys expiring within seven days raise one
  `api_key_expiring` notification (webhook-routable) instead of dying
  as a silent 401.
- Feedback comments: visitors and API callers can attach text to a
  rating (site inline form; `content` on `POST /v1/messages/:id/feedbacks`),
  shown in the monitor's feedback review and the feedback CSV.
- Annotation editing: edit question/answer in place (a changed question
  re-embeds) and toggle annotations on/off from the monitor.
- Batch cancel: stop an in-flight CSV batch — rows not yet started are
  skipped, finished rows keep their runs, the batch lands `canceled`.
- Flux-site parity: published workflow form pages get the passcode gate
  and custom CSS that app sites already had.
- `PATCH /v1/datasets/:id`: dataset settings (chunking, retrieval
  mode/weight, Q&A indexing, thresholds) over the API for
  infra-as-code; embedding model changes stay behind the guarded
  switch-and-re-embed flow.

### Batch 33
- OpenAI-compatible `POST /v1/images/generations`: image generation
  through the workspace default model's provider, answering `b64_json`.
- Run attribution: every run records `started_by` — the account email,
  `api:<key prefix>`, `trigger:<kind>`, `mcp`, `batch`, `replay`, or
  `retry` — shown in the runs drill-in and riding along in exports.
- Dataset duplicate: one-click copy of settings and documents (tags and
  metadata included), indexed through the normal pipeline; sync
  schedules and eval history deliberately stay behind.
- Embedding model switch: changing a dataset's embedding model is now
  an explicit switch-and-re-embed move (audited), never a silent
  settings edit that poisons the index with mixed vectors.
- Site custom CSS: a per-app CSS block on public sites (style-tag
  breakout stripped, 4k cap) for full white-labeling.
- Audit trail retention: an optional separate `audit_retention_days`
  (min 30; default keep-forever) in the nightly sweep.
- Configurable session lifetime: `FLUX_SESSION_VALIDITY_DAYS` tightens
  the 14-day console-session window instance-wide — checked at verify
  time, so lowering it also ends sessions already past the new window.

### Batch 32
- Q&A-format indexing: an opt-in dataset mode where chunks index as
  model-generated questions (embedded and full-text searched) carrying
  the original passage — retrieval matches how users actually ask and
  still returns the prose. Rides the parent-promotion rails.
- App icons: a per-app emoji shown on console cards and the public
  site header (when no logo is set).
- Conversations CSV: the monitor bulk-exports every conversation's
  messages (id, title, visitor ref, role, content, feedback, time —
  up to 10k rows).
- Run tags: tag runs from the drill-in or the API's `tags` param;
  the runs page filters by tag (GIN-indexed).
- Chat-bubble theming: the embed snippet carries `data-flux-color`,
  `data-flux-icon`, `data-flux-position`, and `data-flux-greeting`
  (a one-time tooltip), wired to the app's theme settings.
- Inbound email trigger: a new trigger kind with an `emt_` URL for
  Mailgun/SES-style inbound-mail webhooks — from/subject/body arrive
  as run inputs (body doubles as `query`).
- Canvas frames: named, resizable group boxes on the flux canvas,
  saved with the graph like sticky notes.
- Message pinning: bookmark console chat messages; pinned ones sit in
  a strip above the thread.
- Workspace default model params: default temperature/max_tokens
  applied wherever an app or LLM node sets none of its own.

### Batch 31
- Retrieval modes: datasets choose `hybrid` (default), `semantic`, or
  `keyword` ranking, and hybrid takes an optional semantic weight that
  skews the RRF fusion toward either side. The full-text source got a
  GIN expression index so keyword ranking is an index scan.
- TOTP two-factor authentication: enroll from account settings (QR code
  + manual key), confirm with a first code, get eight one-time recovery
  codes. Password logins detour through a code challenge; magic links
  and SSO are unaffected (the IdP owns those factors).
- Site passcodes: a public app site can require a passcode once per
  browser session — softer than turning the site off, stronger than
  security-by-URL.
- Conversation auto-titles: after the first exchange the workspace
  model writes a short title, replacing the truncated first question
  (manual renames always win; no model keeps the old behavior).
- OpenAI-compatible `POST /v1/moderations`: judges input against the
  workspace guardrails (deny patterns + the LLM moderation policy) and
  answers in the OpenAI moderation shape.
- Per-key rate limits: any API key can carry its own requests/minute
  cap (its own bucket, shown in the key tables); key limit beats app
  limit beats pipeline default.
- Run comments: team notes on any workflow run from the runs page —
  author, timestamp, author-or-owner delete.
- Workspace IP allowlist: optional CIDR list gating the entire `/v1`
  service API; rejected calls get 403 and land in the audit trail.

### Breaking
- The model-registry API moved from `GET/POST /v1/models` to
  `GET/POST /v1/registry/models`. `GET /v1/models` now answers in
  OpenAI's list shape (the workspace's provider models, the app's bound
  model first) so OpenAI SDKs and gateways autodiscover.

### Batch 30
- Toolchain: the release image now builds on **Elixir 1.20.3 /
  OTP 28.5** (from 1.16.2 / OTP 26); all dependencies updated
  (Phoenix 1.8.10, LiveView 1.2, Req 0.7, Oban 2.23.1, Sobelow 0.15,
  Swoosh 1.27, and friends). Two upgrade fallouts fixed: the heroicons
  git dep dropped `depth: 1` (Elixir 1.20 validates it against a lock
  written by 1.16), and the ExAws Req adapter no longer passes empty
  bodies — Req 0.7 turns any request carrying a `:body` option into a
  POST, which broke S3 GET/DELETE against MinIO.
- Model params round-out: `stop`, `frequency_penalty`,
  `presence_penalty`, `top_k`, and `seed` pass through to providers
  (mapped to `stop_sequences`/`top_k` on Anthropic).
- Failed-run auto-retry: a per-flux toggle gives failed runs one
  automatic second attempt (linked via `retry_of`); batches keep
  their own row retry.
- Audit webhook events: `audit.recorded` joins the signed fan-out —
  SIEMs ingest the trail live.
- Storage rollup: per-workspace stored bytes on the admin panel.
- Eval set copy: duplicate a set (cases and weights) onto another
  flux.
- Single-run JSON export: a download button on the runs drill-in
  (inputs, outputs, per-node trace).
- Site maintenance page: disabling a site shows a friendly "back
  soon" page instead of hard-404ing visitors mid-conversation.

### Batch 29
- Workspace system prompt: an org-wide prefix baked into every chat
  app's model calls — compliance boilerplate and tone rules live once.
- `mix flux.backup`: one task dumps every workspace's export archive
  to a directory (exits non-zero on failure — cron-ready).
- Citation deep-links: console chat sources link into the knowledge
  browser (dataset selected, document expanded).
- Cost forecast: a month-end token projection on the dashboard,
  colored against the budget — the 80% warning tells you when it
  happened; this tells you it's coming.
- Visitor transcript download: site visitors download their own
  conversation as Markdown (session-ref authorized).
- Credential re-validate: a Test button on saved provider keys —
  expired keys stop surfacing as cryptic run failures.
- Trash purge parity: datasets and conversations gain the purge-now
  buttons fluxes and apps already had.

### Batch 28
- Serving pin: freeze a flux's serving version explicitly — new
  publishes stop deploying until you unpin (wins over the A/B split;
  the rollback lever that survives releases).
- Paused-run reminders: a daily notification counts runs that have
  sat waiting for input over 24 hours.
- Visitor forget (GDPR): one action hard-deletes a visitor's
  conversations, messages, and uploads, with an audit entry.
- Dataset archives over the API: `GET /v1/datasets/:id/export` and
  `POST /v1/datasets/import`.
- Latency percentiles: p50/p95 run duration on the fluxes index
  health badges.
- Bulk conversation operations: multi-select label and delete on the
  monitoring page.
- Watchdog mute: silence the schedule watchdog per trigger for
  known-stalled schedules.

### Batch 27
- Schedule watchdog: a daily check flags enabled schedules that
  haven't fired within twice their expected period — the dead-man's
  switch for automation.
- Chunk preview: paste sample text in dataset settings and see the
  chunks the current settings produce before re-indexing.
- Batch outputs → dataset: a completed batch's successful rows land
  as documents in a chosen dataset (generate → index in one motion).
- Provider call log: the admin health table gains a recent-calls ring
  (provider, model, latency, outcome — last 100).
- Conversation drill-ins show the rolling-memory summary the model
  carries forward.
- "Open flux ↗" links on subflux, iteration, and loop panels.
- `GET /v1/visitors`: the per-visitor rollup over the API.

### Batch 26
- Anthropic-compatible `POST /v1/messages` (blocking and streaming
  with the full event sequence) — Claude SDKs point at apps with a
  base-URL swap, beside the OpenAI surface.
- OpenAI-compatible `POST /v1/audio/transcriptions` (multipart) and
  `POST /v1/audio/speech` through the workspace default provider.
- Run API round-out: `GET /v1/workflows/runs/:id` (with `?trace=true`
  per-node executions) and `POST .../stop`.
- Dataset export/import: a portable `flux-dataset/v1` JSON archive
  (documents, tags, metadata, retrieval cases, URL sources) with an
  Export button and an Import picker in the knowledge browser.
- Site visitors rate replies: 👍/👎 on public chat, flowing into the
  same feedback loop the console sees.
- Editor input presets: save named sample inputs on the run panel and
  reload them with one click (up to 20 per flux).
- Cost spike alerts: a daily check flags workspaces whose yesterday
  token spend more than doubled the trailing week's average.

### Batch 25
- Compat structured outputs: `response_format` with `json_schema` on
  `POST /v1/chat/completions` forces and validates JSON (one
  corrective retry, honest 502 on failure); `json_object` works too.
- Conversation trash: deletes are soft (30-day purge, restorable from
  monitoring) — the last hard-deleting object gains trash parity.
- Embedding cache: identical texts reuse their vectors (always on,
  24h TTL, partial hits) — re-indexing stops paying twice; stats
  beside the LLM cache's.
- Visitor analytics: per-`end_user_ref` rollup on monitoring —
  conversations, messages, tokens, feedback, last seen.
- Publish notes: releases take an optional note, shown in the
  versions modal.
- URL sources take a "fetch now" button beside the nightly sweep.
- Prompt library versioning: edits archive the previous content;
  history lists and restores per snippet.

### Batch 24
- OpenAI-compat tool calling: `POST /v1/chat/completions` passes
  `tools` through to the app's model and answers `tool_calls`
  (blocking and streaming); `tool`-role messages and replayed
  assistant `tool_calls` round-trip, so function-calling loops work
  against a base-URL swap. Chatflow apps refuse tools honestly — they
  run their own.
- Workspace environment variables: an encrypted store reachable as
  `{{env.NAME}}` from every flux; secret values are write-only; a
  flux's own env wins on collisions.
- Dataset content search: a search box over a dataset's segments in
  the knowledge browser.
- Annotation import/export: CSV out from monitoring, CSV paste-in for
  bulk curation.
- Knowledge webhook events: `document.indexed`, `document.failed`,
  and `dataset.synced` join the signed-webhook catalog.
- Editor shortcuts overlay: press `?` on the canvas for the keyboard
  cheat sheet.
- Quality API: `GET /v1/conversation-evals`,
  `POST /v1/conversation-evals/:id/run`, and `GET /v1/ab-stats` on
  `app-` tokens — CI drives scripted dialogues and reads A/B results.

### Batch 23
- Sub-flux call node: run a published flux as a single node — inputs
  map from templates (`name = {{ref}}` per line), the sub-flux's end
  outputs come back as the node's outputs, version-pinnable.
- LLM node vision: a `vision_variable` resolving to an uploaded image
  rides the user message to vision-capable models — workflows can
  finally see images.
- Image generation: an optional `invoke_image` provider capability
  (OpenAI images shape on the OpenAI/compatible plugins) exposed as a
  built-in `Images` toolset for tool and agent nodes; generated PNGs
  land on the Files page.
- Conversation evals take a cron — scripted dialogues re-run
  unattended, score drops notify (same treatment retrieval evals got).
- Bulk document operations: multi-select in the dataset browser to
  enable/disable (a new per-document flag that cascades to segments —
  retrieval skips disabled documents), tag, or delete several at once.
- Instance announcement banner: admins set a note that shows atop
  every console page (maintenance windows, migration notices).

## v0.4.0 — 2026-08-08

Three batches on from v0.3.0: enterprise sign-on, model experimentation,
and evals that watch themselves. Ledger entries 43–46 carry the detail.

### Batch 22
- SAML 2.0 single sign-on (Samly/esaml, native — no proxy sidecar):
  point `SAML_IDP_METADATA_FILE` at the IdP metadata and the login page
  grows an SSO button; assertions provision accounts like OIDC.
- Chat-app model A/B: a challenger model takes a stable percentage of
  conversations; the monitoring page compares replies, feedback, and
  tokens per variant.
- Conversation-level evals: scripted multi-turn dialogues replay
  through an app (or its chatflow) and an LLM judge scores the whole
  transcript — regressions raise a notification.
- Scheduled retrieval evals: a cron on the dataset re-scores the golden
  retrieval cases; a hit-rate or MRR drop raises a notification.
- Delay node: wait `seconds` or until an ISO-8601 time (both
  template-capable, 300s cap) — pacing for rate-limited APIs.
- Canvas find: Ctrl/Cmd-F on the editor filters nodes by title, type,
  or id, highlights matches, and jumps to the first.
- Sessions in account settings show each token's IP and browser.

### Batch 21
- Chatflow conversations fold the same rolling summary into
  `{{sys.history}}` that direct-model apps get.
- OpenAI-compatible `POST /v1/embeddings` with any service token.
- Batches run rows in parallel on request (2/4/8; capped at 8).
- Audio uploads (mp3/wav/webm) transcribe into dataset documents
  through the workspace default provider.
- Extract-to-flux: a canvas selection becomes a new flux with outside
  references rewritten as start variables.
- Workspace exports carry conversations (titles, labels, completed
  turns, capped at 500 per app) and restore them on import.
- Any node takes `timeout_ms` (editor field in seconds) — a stalling
  node fails honestly instead of hanging the run.

### Conversations & support
- Human handoff: site visitors can ask for a person; the conversation
  flags into a console queue (with notification) and a teammate's
  reply lands in the visitor's chat live.
- Conversation labels, filterable on the monitoring page.
- Guardrails gain a redact action — matches mask with `•••` in chat
  messages, replies, and run inputs instead of refusing.

### Models & knowledge
- Ollama provider: local models auto-discover from `/api/tags`.
- Model playground: one prompt across up to four models side by side
  with latency, tokens, and cost; one click sets the workspace default.
- Image documents: datasets accept images, described and
  text-transcribed by the workspace vision model.
- Typed document metadata with retrieval and knowledge-node filters.
- Run a flux over a dataset: every document becomes a batch row.

### Operations & sharing
- Public /status page (component health + admin incident note), JSON
  variant for monitors, optional Uptime Kuma compose profile.
- Slack Block Kit format on webhook endpoints.
- Read-only share links for run traces (signed, 30-day expiry).
- Canvas SVG export; monitoring feedback/usage CSV exports.
- LLM cache hit-rate stats; workspace archive (owner archives,
  instance admin restores); monthly cost report notification + email.

### API & apps
- The OpenAI-compatible endpoint reaches chatflow apps — bridged
  through their published flux with the earlier turns as history.
- Per-app rate limits override the 120 req/min pipeline default.
- Read-aloud uses real provider voices when the provider has a speech
  endpoint (`invoke_speech` capability, OpenAI `/audio/speech` shape);
  browser voices remain the fallback.

### Costs & knowledge
- Workspace model price overrides (self-hosted/fine-tuned models
  priced per million tokens) feed every cost rollup.
- Per-flux monthly token budgets beside the workspace budget — 80%
  warning, honest refusal past the cap.
- Same-named document re-uploads replace in place instead of
  duplicating.

### Operations
- `ops/alerts.yml`: five Prometheus alert rules (app down, 5xx rate,
  run failures, Oban backlog, BEAM memory) loaded by the compose
  Prometheus, metric names verified against the live endpoint.

## v0.3.0 — 2026-08-07

Three batches on from v0.2.0: hardening, then interoperability, then
the conversational round-out. Highlights below; ledger entries 40–42
carry the detail.

### OpenAI compatibility & voice
- `POST /v1/chat/completions` with an `app-` token speaks OpenAI's
  wire format (blocking and streaming) — any OpenAI SDK talks to a
  chat app with a base-URL swap.
- Voice input: hold the mic in console or site chat, release to
  transcribe through the provider's Whisper-style endpoint (a new
  optional `invoke_transcription` capability on provider plugins);
  every reply has a read-aloud button (browser voices, no provider).

### Conversations & agents
- Rolling memory: long chats fold older turns into an incrementally
  maintained summary on the conversation instead of overflowing the
  context window.
- Agent nodes attach multiple toolsets at once (OpenAPI, plugin, and
  MCP mixed), with colliding tool names deduped.
- Model-backed moderation beside the regex guardrails: the workspace
  default model judges inputs against a policy (block or flag;
  outputs always flag-only; judge failures allow).

### Notifications
- Per-account email opt-in per notification kind — run failures,
  budget warnings, the weekly digest, and the rest arrive by mail
  through the SMTP relay.

### MCP phase 2
- The `/mcp` server now advertises the prompt library as MCP prompts
  and dataset documents as MCP resources alongside flux tools.

### Interoperability
- MCP client: register Model Context Protocol servers (Streamable
  HTTP, encrypted auth headers) as workspace tool sources — their
  tools join the picker for tool and agent nodes.
- MCP server: `POST /mcp` advertises every published flux as a
  callable tool (input schema from start variables), authenticated
  with a workspace `ws-` key; `tools/call` runs synchronously.

### Retrieval & models
- Parent-child chunking per dataset: small child chunks embedded for
  precision, the enclosing parent section returned for context,
  deduplicated across hits.
- Structured LLM output now validates against its JSON schema with one
  corrective retry (errors quoted back to the model) before failing.
- Chat apps take a fallback model — one retry on another provider when
  the primary errors, recorded on the reply's usage.
- Conversation variables written by chatflows are inspectable above
  the console chat.

### Operations
- Background jobs in the admin panel: queue depths by state, failing
  jobs with their last error, retry/cancel in place.

### Security & hygiene
- Sobelow, credo (warnings + consistency), `deps.audit`, and dialyzer
  wired into the workflow; one real finding fixed (plugin endpoint
  content-type allowlist) and every dialyzer warning resolved or
  explicitly justified.
- Session management on account settings: every signed-in device
  listed, revoke one, or log out everywhere.
- Workspace-level `ws-` API keys (same perpetual/expiring lifetimes as
  app and flux keys) minted from the settings page.
- Audit log gains a from/to date filter and CSV export.

### Product
- Duplicate any app or flux in one click — configuration and draft
  graph copied, publish state reset.
- Conversations download as Markdown or JSON from the chat header.

### Operations
- SMTP delivery for account email against any relay
  (`FLUX_SMTP_HOST/PORT/USERNAME/PASSWORD/SSL`, `FLUX_MAIL_FROM`).
- Backup restore drill rehearsed against the live container; restore
  runbook added to the operations guide.
- **Fixed:** pgvector similarity search crashed in production releases
  (`vector` type unknown to Postgrex) — parameters now cast through
  text. Found by the restore drill's retrieval check.
- Round-2 performance baselines: 50 concurrent chat streams ~350 ms
  wall; 100-row batch ~13.5 rows/s.

## v0.2.0 — 2026-08-07

Four batches on from v0.1.0: the chat experience finished, the shop
windows refreshed, and the operations story completed. Highlights:

### Chat & apps
- Image uploads for vision models from the chat box (console + sites),
  conversation history with resume/rename/delete/search, streaming
  markdown, copy buttons, opt-in follow-up question chips.
- Published sites carry OpenGraph/meta tags and a favicon from the
  app's theme, so shared links unfurl properly.

### Providers & tokens
- Azure OpenAI and Amazon Bedrock (hand-rolled SigV4) providers.
- API tokens: perpetual or expiring by choice (30/90/365 days),
  last-used stamps, `401 token_expired`, one-click revocation.

### Debugging & operations
- Side-by-side run comparison; replay a finished run from any node
  (upstream outputs reused); batches retry only failed rows; runs
  export as JSONL with per-node traces; per-node output caching.
- `/health` + `/health/ready` probes, `mix flux.doctor` environment
  self-check, webhook test events, rate-limit headers, per-provider
  health on the admin panel, token/cost Prometheus metrics with
  provisioned Grafana panels (`--profile metrics`).
- Notification feed filters by kind with per-item mark-read; cron
  fields preview their next fire; a new Operations guide ships in
  the console docs.

### Knowledge & authoring
- PDF/Office uploads through Tika; depth-1 URL crawl; remembered URL
  sources re-fetched nightly (replace-in-place); prompt library with
  an editor insert picker; canvas align/distribute, presence avatars,
  and sub-flux version pinning.

### Console
- Ctrl+K command palette (pages, entities, workspace switching),
  themed confirm dialogs, an in-console API reference with per-endpoint
  curl examples, dashboard activity feed + getting-started checklist,
  flux health badges, German joins English/French/Spanish.

## v0.1.0 — 2026-08-03

The first tagged release: the full platform, from a standing start to 700+
hermetic tests, in eleven build batches. Where we're going, we don't need
roads — but a changelog helps.

### Workflow engine (`flux_engine`)
- 25 node types on a pure, host-agnostic engine: start, LLM, agent (tool
  loops, drives, approval pauses), code, http, if/else, iteration, loop,
  template, variable aggregator, knowledge retrieval, document extractor,
  file output (HTML/PDF/Markdown/CSV/JSON/text), human input, labeling,
  interview, and more.
- Pause/resume with two resume modes (feed-forward and re-run), parallel
  branch execution, per-node token attribution, sub-flux composition with
  optional version pinning on iteration/loop nodes.

### Console (`flux_web`)
- Visual canvas editor: drag-drop nodes, sticky notes, undo, versions with
  graph diffs, A/B traffic splits, publish gates, Edit-with-AI, template
  gallery (built-in + workspace "save as template").
- Apps: chat, advanced chat (chatflow), and completion modes; public sites
  with theming and embed snippets; annotations; suggested questions;
  markdown-rendered replies with regenerate.
- Knowledge: datasets with hybrid retrieval (RRF over semantic + keyword +
  entity), markdown-aware chunking, query expansion, document tags,
  retrieval evals (hit rate + MRR), trash with restore.
- Quality loop: eval sets (exact/contains/regex/LLM-judge graders, weights,
  schedules, gates), labeling projects (consensus voting, gold honeypots,
  labeler accuracy), model registry with `registry:<name>` refs.
- Operations: runs page with filters/search/waterfall drill-in, batch runs
  over CSV with schedules, usage rollups + cost cards + CSV export,
  notifications feed with webhook routing and delivery log, workspace
  settings (guardrails, budgets, concurrency caps, LLM cache, retention,
  export schedules), instance admin panel, onboarding checklist, audit log.
- i18n: French and Spanish catalogs; locale plug + per-session switching.

### API (`/v1`)
- OpenAPI-documented REST surface: apps, chat (SSE streaming), workflows,
  runs, datasets, batches, evals, labeling, models, notifications,
  retrieval cases — with typed error envelopes and per-app API tokens.

### Providers & plugins (`flux_plugin_runtime`)
- Model providers: OpenAI, Anthropic, Gemini, Azure OpenAI, Amazon Bedrock
  (hand-rolled SigV4), any OpenAI-compatible endpoint, and a keyless echo
  provider so everything demos without credentials.
- Tool/datasource plugins: utility, RSS, LlamaIndex, Notion, S3, Google
  Drive; plugin SDK package (`packages/flux_plugin`) with manifests,
  credential schemas, and endpoint tokens.

### RAG (`flux_rag`)
- Pluggable vector stores: in-BEAM cosine (default), pgvector (guarded
  migration + HNSW), ArangoDB (AQL cosine + entity-graph traversals).
- Entity extraction and co-occurrence graph sync for graph-flavored
  retrieval.

### Infrastructure
- Docker Compose stack: app, pgvector Postgres, MinIO, Gotenberg, Tika,
  sandboxed coderunner (network-namespace split, ML libraries preloaded),
  optional ArangoDB (`rag` profile).
- Multi-tenant workspaces with RBAC (built-in + custom roles), SSO/OIDC,
  magic-link auth, workspace export/import (full quality-asset round trip),
  soft-delete trash with 30-day purge, nightly log sweeps, weekly digests.
- 700+ hermetic tests across five apps, golden replay fixtures, and a
  tagged perf suite.
