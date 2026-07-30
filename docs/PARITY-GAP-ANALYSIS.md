# FluxCapacitor ↔ Dify Parity Gap Analysis

Date: 2026-07-30 rev 3 (verified against code, commit 8f2231c) · Reference: Dify v1.16.0 (`C:\Users\jpcre\GitHub\dify`) · Execution plan: `PARITY-PLAN.md`

Scale context: Dify's production backend is ~368k LOC of Python (~840 HTTP routes,
~80 background tasks over ~25 queues), its workflow canvas alone is ~218k LOC of
TypeScript, and its workflow engine + model runtime live in the external `graphon`
PyPI package. FluxCapacitor today is ~12.2k LOC of lib code + ~5.0k LOC of tests
(285 passing). By plan phases: **P0 done**, **P1 ~60%** (chat apps, 3 providers,
2 `/v1` routes, OTP release + local deploy), **P3 ~30% pulled forward** (engine
with 7 node types incl. tool, canvas editor, publish/versions/runs), **P4 ~15%
pulled forward** (OpenAPI custom tools with encrypted auth/variables), P2 RAG and
P5 enterprise not started. See `PARITY-PLAN.md` for the full scorecard and the
workstream/milestone plan.

Upstream is a moving target: the reference checkout is 197 commits past v1.16.0 and
has grown two new top-level components — `dify-agent` (Python agent SDK) and
`dify-agent-runtime` (Go runtime) — for Agent v2. Re-check the P4 agent plan against
these before building.

Legend: ✅ done · 🟡 partial · ❌ missing · 🚫 deliberately not mirrored (per approved plan)

## 1. Identity, tenancy, teams

| Capability | Status | Notes |
|---|---|---|
| Accounts + magic-link/password auth | ✅ | pbkdf2 locally (no C toolchain); swap to bcrypt on Linux builds |
| Workspaces (tenants), roles owner/admin/editor/normal/dataset_operator | ✅ | single-owner enforced at DB level |
| Membership mgmt: invite (multi-email), role change, remove, owner transfer | ✅ | UI live at /console/members; owner-transfer has context fn but no UI |
| Scope threading + Repo tenant guard | ✅ | `UnscopedQueryError` tripwire covers invitations, provider_credentials, apps, conversations, messages, api_tokens; RLS hardening deferred to P5 |
| RBAC permission catalog (45 points from `api/core/rbac/entities.py`) | ✅ | built-in role sets; `can?/3` |
| RBAC enforcement wired everywhere | 🟡 | Context-level: Providers, Chat, Workflows, Tools, **and Accounts member mutations (role change/remove/invite — fixed 07-27 with bypass tests)**. Still no router plug / on_mount hook; most of the 45 permission atoms unused until their features exist |
| Workspace switcher UI | ✅ | sidebar dropdown → `WorkspaceController.switch/2`; non-member rejection tested |
| Custom roles (per-workspace role/permission rows + UI) | ❌ | P5 |
| Resource-level permissions (dataset partial access, credential permissions, app access modes) | ❌ | P2/P5 |
| SSO (OIDC, SAML, enforced, JIT provisioning) | ❌ | P5 (`openid_connect`, `samly`) |
| SCIM 2.0 provisioning | ❌ | P5 |
| Social OAuth login (GitHub/Google) | ❌ | low priority for enterprise; `assent` when needed |

## 2. Model runtime & providers (Dify: plugin-daemon-backed; ours: P1)

| Capability | Status | Notes |
|---|---|---|
| Credential vault (cloak KEK→workspace-DEK envelope) | ✅ | AES-256-GCM per-workspace DEKs in `workspace_keys`, Cachex-cached (10 min TTL), `rotate_dek/2`; tests prove cross-workspace ciphertext fails to decrypt |
| Per-workspace encrypted provider credentials | ✅ | `Providers.upsert_credential/3` validates live against the provider before persisting; unique on (workspace, plugin, name) |
| Credentials UI on Plugins screen | ✅ | dynamic form generated from each plugin's `credential_schema` |
| First-party providers: openai, anthropic, gemini | ✅ | real HTTP + SSE streaming with usage parsing; supervised invocation (timeout + crash isolation). **Model catalogs hardcoded**, no retries/backoff; SSE parsing covered by Req.Test HTTP-mock suites |
| First-party providers: azure_openai, bedrock | ❌ | P1 remainder |
| Invocation kinds beyond streaming LLM | ❌ | no embeddings, rerank, structured output, tool calling, vision; no moderation hook |
| Default/system models (TenantDefaultModel, per-type defaults) | ❌ | P1 remainder |
| ModelInstance/ModelManager facade; load balancing + cooldowns | ❌ | schema supports named credentials (`name`, default `"default"`) but nothing uses more than one |
| 🚫 TTS/speech-to-text (API returns 501), LLM polling mode, hosted/system quota providers | 🚫 | quotas come via Features layer instead |

## 3. Plugin system (Dify: Go daemon + Python SDK; ours: BEAM-native, P1+P4)

| Capability | Status | Notes |
|---|---|---|
| SDK: `Flux.Plugin` behaviour + Manifest/CredentialField structs | ✅ | category enum already spans model/tool/datasource/trigger/agent_strategy/extension |
| SDK: ModelProvider capability (`models/1`, `validate_credentials/1`, `invoke_llm/3` push-based) | ✅ | Spec/Request/Chunk/Result structs; **SDK package has zero tests** |
| SDK: Tool, Datasource, Trigger, AgentStrategy, Endpoint behaviours | ❌ | P4 |
| Runtime: catalog + supervised invocations | 🟡 | static `@builtin_plugins` list (config-overridable); `Task.Supervisor.async_nolink` with yield/brutal-kill timeouts. No max_heap, no telemetry, no capability broker |
| Network guard (SSRF) for plugin/toolset HTTP | ✅ | `Flux.SSRF` on provider base URLs, toolset calls, credential validation; `FLUX_SSRF_ALLOW` exemptions. Capability grants still ❌ |
| Host capability struct (replaces Dify's 17 inner-API reverse-invocation endpoints) | ❌ | P1/P4 |
| Per-workspace `plugin_installations`, install permissions, auto-upgrade | ❌ | P4 |
| Split plugin-runtime BEAM node + `:erpc` streaming (Phase B) | ❌ | P4 |
| Private Hex registry (mini_repo) + plugin CI | ❌ | P4 |
| 🚫 .difypkg dynamic install, marketplace, signature daemon, remote-debug TCP listener | 🚫 | |

## 4. Apps & conversations (P1)

| Capability | Status | Notes |
|---|---|---|
| App model — `chat` mode only | ✅ | provider_plugin_id + model + system_prompt + params (temperature/max_tokens/top_p whitelist) |
| App modes: completion, advanced-chat, workflow (🚫 legacy agent-chat) | ❌ | mode enum currently `[:chat]` |
| AppModelConfig / prompt templates + variables | ❌ | prompt assembly = system_prompt + history only |
| Conversations/Messages | ✅ | with status lifecycle (streaming/completed/stopped/error) and usage capture |
| Generation pipeline: supervised task, PubSub streaming, stop, blocking mode | ✅ | subscribe-before-spawn (no lost chunks); Registry-tracked pids; stop persists the streamed prefix via ETS stream buffers (fixed 07-27) |
| Message feedback (like/dislike via /v1) | ✅ | annotations, saved/pinned still ❌ (🚫 annotation-reply ML) |
| Console chat UI | ✅ | streaming, stop button, new-conversation, API-key panel (raw token shown once) |
| ApiToken issuance/hashing | ✅ | `app-` prefix, SHA-256 hash at rest, display prefix, last_used_at |
| Per-app rate limits | 🟡 | /v1 limited per token principal (120/min, hammer); per-app configurable limits still ❌ |
| Site (published LiveView webapp) + JS embed; EndUser identity | ❌ | P1 remainder (`end_user_ref` field exists on conversations) |
| File upload wired to storage; multimodal input | ❌ | storage behaviour exists but has zero callers |
| Tags, app duplicate/export, operation log | ❌ | |
| 🚫 Explore/template gallery, trial apps, education | 🚫 | |

## 5. Workflow engine — the crown jewel (P3)

**First vertical slice live (2026-07-26/27).** `Flux.Engine` is now a pure library (graph
build/validate: single start, acyclic, handle rules; host-injected LLM/tool invocation and
event emission) with 7 node types — start, llm, if_else, template, answer, end, and
**tool** (calls operations of imported OpenAPI toolsets: `Flux.Tools`, encrypted
auth + `{{vars.*}}` private variables, /console/tools UI) — plus
`Flux.Workflows` (draft CRUD, publish/version snapshots, supervised runs streaming over
PubSub, stop, `flux-…` API tokens) and a **LiveView-native canvas editor** at
`/console/fluxes/:id` (SVG edges, JS-hook drag & port-to-port connect, per-type config
panels, live-validation badge, streaming run drawer, publish + API key modal).
`POST /v1/workflows/run` executes the latest published snapshot with Dify-style SSE
events (workflow_started / node_started / text_chunk / node_finished / workflow_finished)
or blocking mode.

Still missing (unchanged from prior analysis):
- gen_statem run coordinator + per-run Task.Supervisor (today: one task under the shared GenerationSupervisor)
- The other ~12 node types (code via dify-sandbox, agent, iteration, loop, question-classifier, parameter-extractor, variable aggregator/assigner, document-extractor, list-operator, knowledge-retrieval, human-input) — http-request ✅ 07-30, tool ✅ (toolsets)
- Variable pool >256KB object-storage offload; env/conversation variables (today: in-memory pool, `{{node.field}}` templates)
- Full Dify SSE schema (~45 events; today: 5 core events)
- Pause/resume via versioned JSON snapshots; human-in-the-loop forms; timeout jobs
- Retries/error branches; per-workspace concurrency limits (stop via kill exists)
- Run history/log UI, node-execution offload (runs+traces persist; no browsing UI yet)
- Single-node draft debugging (full-draft run exists)
- DSL import ✅ + export ✅ (round-trip tested; editor Export button, Fluxes-page Import; Dify-importable JSON-as-YAML). Remaining bar: import coverage grows with node types
- **Golden test harness — phase 1 running**: DSL importer executes verbatim Dify fixtures with behavioral assertions in CI. Phase 2 (recorded run traces + SSE transcripts) needs a live Dify via Docker
- Canvas decision RESOLVED: LiveView-native (SVG + JS hook), not a ReactFlow island. Still missing vs Dify's editor: zoom/minimap, multi-select, undo/redo, auto-layout, copy/paste
- Collaboration: Presence soft-lock first; y_ex CRDT P5 (🚫 loro)
- Triggers: webhook/schedule/plugin trigger tables + dispatch (P4); Agent v2 (config revisions, runtime sessions, ReAct/function-calling strategies) (P4) — **note upstream Agent v2 now lives in `dify-agent`/`dify-agent-runtime`; re-validate scope**
- Workflow comments/mentions, run archives (P5+)

## 6. RAG / Knowledge (P2)

All ❌ — `apps/flux_rag` is still `mix new` output. Unchanged from prior analysis:
- Dataset→Document→Segment→ChildChunk schemas, process rules, metadata
- Ingestion Oban pipeline: extract (Apache Tika container; floki for HTML; native text/md/csv) → clean → split → index processors (paragraph, QA-via-LLM, parent-child)
- Embedding cache table + Cachex; batched embeds
- VectorStore behaviour → **pgvector** (HNSW + tsvector/GIN: semantic, full-text, hybrid in one Postgres); Qdrant on demand; 🚫 other ~28 backends
- Retrieval: semantic/full_text/hybrid/keyword, weighted + model rerank, RRF, multi-dataset merge, citations
- Dataset UI: upload, indexing progress, segment editor, hit testing; batch document status ops (Dify parity)
- External knowledge API binding; datasource plugins (Notion/Firecrawl) when needed
- 🚫 summary index, jieba economy mode (Postgres FTS instead); RAG-pipeline-as-workflow P5

Note: Oban is configured with 10 queues but **zero `Oban.Worker` modules exist** — the first real workers land here.

## 7. API surfaces

| Dify surface | Status | Plan |
|---|---|---|
| service API `/v1` | 🟡 | **7 routes live**: chat-messages + workflows/run (SSE + blocking), parameters, conversations, messages, stop, feedbacks — hashed bearer auth, rate-limited, cross-workspace rejection tested. Missing: conversation rename/delete, completion-messages, files upload, meta, audio; P2 datasets |
| `open_api_spex` contract tests | ❌ | no OpenAPI spec exists yet — add before the route count grows |
| web API slice (passport JWT for embed widget) | ❌ | P1 |
| files (signed URLs) | ❌ | P1 (S3 presign already implemented in storage adapter) |
| trigger webhooks `/triggers/webhook/:id` | ❌ | P4 |
| console API remnant (~30 routes for canvas island) | ❌ | P3 |
| inner API | 🚫 | in-process host struct replaces it |
| MCP server, OAuth device flow | 🚫 | P5+ candidates |

## 8. Bulk operations (greenfield differentiator)

All ❌: `Flux.Bulk.Operation` behaviour + tables (P2 core, first consumers = batch document ops), then catalog (P5): CredentialRotation, PluginUpgrade (canary), SettingsPropagation, DatasetReindex/ReEmbed, MetadataUpdate, AppModelSwap, AppBatchExport/Import, BatchRepublish, MemberProvision (CSV/SCIM), RoleChange. Oban Pro buy/no-buy decision still open (shapes the fan-out implementation).

## 9. Enterprise & platform

| Capability | Status |
|---|---|
| Audit log (`Flux.Audit` append-only + browser UI) | ❌ P5 (contexts should start calling it earlier) |
| License file (Ed25519) + Features/quota layer (FeatureService parity flags) | ❌ P5 |
| Branding/custom logo | ❌ P5 |
| Billing | 🚫 quotas only, no billing UI |
| Moderation (keyword + one provider hook) | ❌ P1/P2 |
| Importer `mix flux.import` from live Dify Postgres | ❌ P5 (credentials/vectors/plugins not importable by design) |

## 10. Infrastructure & operations

| Item | Status |
|---|---|
| Oban queues + FLUX_ROLE role gating | ✅ config + role gating; **no workers/jobs yet** |
| CI pipeline | ✅ GitHub Actions: format, compile -W, credo --strict, sobelow, deps.audit, tests vs postgres:16 |
| `Flux.Storage` behaviour (S3/MinIO + local) | ✅ env-toggled; local rejects path traversal; S3 presigned URLs; **zero callers so far** |
| Cloak vault + workspace DEKs | ✅ see §2 |
| Cachex | ✅ started; sole consumer is DEK cache |
| hammer rate limiting | ✅ /v1 per token principal (120/min), auth POSTs per IP (10/min) |
| SSRF-guard step | ✅ `Flux.SSRF` (see §3) |
| PromEx + OpenTelemetry + logger_json (replaces Dify's OTEL + langfuse/langsmith seam) | ❌ stock Phoenix telemetry only, no reporter started |
| mix release + local deploy (migrate/seed release tasks, FLUX_MAILBOX mailbox) | ✅ runs at localhost:4001 |
| Dockerfile + 4-container compose (app, postgres+pgvector, minio, tika) | ❌ pulled into RAG workstream (pgvector) |
| dify-sandbox container integration (code node) | ❌ P3 |
| i18n: gettext wired; second locale + island JSON export | 🟡 gettext default only |
| Email: dev mailbox only; prod adapter (SMTP/SendGrid via swoosh) unconfigured | 🟡 |
| Auth pages still wear generated Phoenix chrome | 🟡 cosmetic |
| Repo folder still `dify-elixir` | 🟡 rename blocked by external file handle |

## 11. Known defects & hardening debt

WS1 security sprint (2026-07-27) closed the original list: ~~stop-generation
prefix loss~~, ~~Accounts context RBAC~~, ~~/v1 + auth rate limiting~~,
~~provider SSRF~~, ~~untested provider SSE parsing~~ — all fixed with tests.

Still open:
1. Only stock telemetry; no metrics exporter — flying blind in any deployment (WS7).
2. No router-level RBAC plug / on_mount hook (fold into WS5).
3. Code still not pushed to a remote — `gh auth login` pending (WS0 tail).
4. Tool/toolset calls have no per-call timeout budget distinct from the 60s Req default; fine for now.

## 12. Critical path & recommended order

1. **Golden test harness (still item #1, still not started; needs the live Dify install)** — export real workflow DSLs + record run traces + SSE snapshots; everything in P3 keys off this.
2. Hardening pass: context-level RBAC in Accounts, hammer on `/v1`, SSRF-guarded Req, stop-generation fix (§11).
3. Finish P1: remaining `/v1` routes (conversations/messages/feedback/stop/files) + open_api_spex, site/embed + EndUser, file upload wired to storage, default models, azure/bedrock providers, embeddings invocation, Dockerfile/compose + mix release.
4. Early spikes that size later phases: ReactFlow island round-trip; `:erpc` chunk streaming; Tika on the enterprise corpus; pgvector load test; Oban Pro decision; **review upstream `dify-agent`/`dify-agent-runtime` for Agent v2 scope drift**.
5. P2 RAG → P3 engine+canvas → P4 plugin GA/tools/agents/triggers → P5 enterprise/bulk/SSO.

Remaining effort per the approved plan: ~52–64 engineer-months of the original 60–75
(P0 complete; P1 roughly a third done). The two highest-risk items remain engine
semantic parity (mitigated only by the golden suite) and the canvas port (~218k LOC
upstream; mitigated by the P1 spike deciding reuse vs rewrite).
