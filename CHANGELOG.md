# Changelog

All notable changes to FluxCapacitor are recorded here. The format loosely
follows [Keep a Changelog](https://keepachangelog.com/); the project follows
semantic versioning once past 1.0. Detailed build history lives in the ledger
at `docs/PARITY-PLAN.md`.

## Unreleased

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
