# FluxCapacitor ↔ Dify Parity Gap Analysis

Date: 2026-07-25 · Reference: Dify v1.16.0 (`C:\Users\jpcre\GitHub\dify`) · Plan: `lets-create-a-detailed-piped-tide.md`

Scale context: Dify's production backend is ~368k LOC of Python (~840 HTTP routes,
~80 background tasks over ~25 queues), its workflow canvas alone is ~218k LOC of
TypeScript, and its workflow engine + model runtime live in the external `graphon`
PyPI package. FluxCapacitor today is roughly 4k LOC. By volume we are ~1–2% in;
by plan phases, P0 (foundation) is ~70% done and P1–P5 have not started.

Legend: ✅ done · 🟡 partial · ❌ missing · 🚫 deliberately not mirrored (per approved plan)

## 1. Identity, tenancy, teams

| Capability | Status | Notes |
|---|---|---|
| Accounts + magic-link/password auth | ✅ | pbkdf2 locally (no C toolchain); swap to bcrypt on Linux builds |
| Workspaces (tenants), roles owner/admin/editor/normal/dataset_operator | ✅ | single-owner enforced at DB level |
| Membership mgmt: invite (multi-email), role change, remove, owner transfer | ✅ | UI live at /console/members; owner-transfer has context fn but no UI |
| Scope threading + Repo tenant guard | ✅ | `UnscopedQueryError` tripwire; RLS hardening deferred to P5 |
| RBAC permission catalog (45 points from `api/core/rbac/entities.py`) | ✅ | built-in role sets; `can?/3` |
| RBAC enforcement wired everywhere | 🟡 | only Members screen checks today; every future context/LiveView/API must gate |
| Custom roles (per-workspace role/permission rows + UI) | ❌ | P5 |
| Workspace switcher UI | ❌ | backend `switch_workspace/2` exists; sidebar UI missing |
| Resource-level permissions (dataset partial access, credential permissions, app access modes) | ❌ | P2/P5 |
| SSO (OIDC, SAML, enforced, JIT provisioning) | ❌ | P5 (`openid_connect`, `samly`) |
| SCIM 2.0 provisioning | ❌ | P5 |
| Social OAuth login (GitHub/Google) | ❌ | low priority for enterprise; `assent` when needed |

## 2. Model runtime & providers (Dify: plugin-daemon-backed; ours: P1)

All ❌ — this is the P1 milestone:
- Provider/ProviderModel/ProviderCredential schemas + per-workspace encrypted credentials
- **Credential vault** (cloak_ecto KEK→workspace-DEK envelope) — prerequisite, still unbuilt
- ModelInstance/ModelManager facade; load balancing with cooldowns; TenantDefaultModel
- Invocation kinds: LLM (stream/blocking/structured output), embeddings, rerank; moderation hook
- 🚫 TTS/speech-to-text (API returns 501), LLM polling mode, hosted/system quota providers (quotas come via Features layer instead)
- First-party provider plugins: openai, anthropic, azure_openai, bedrock
- Credentials UI on the Plugins screen

## 3. Plugin system (Dify: Go daemon + Python SDK; ours: BEAM-native, P1+P4)

All ❌ except the empty SDK package:
- SDK behaviours: `Flux.Plugin` + ModelProvider (P1); Tool, Datasource, Trigger, AgentStrategy, Endpoint (P4)
- Manifest + capability grants; network allowlist via SSRF-guarded Req
- Host capability struct (replaces Dify's 17 inner-API reverse-invocation endpoints)
- Runtime: catalog, capability broker, supervised invocations (max_heap/deadline/telemetry)
- Per-workspace `plugin_installations` rows, install permissions, auto-upgrade strategies
- Split plugin-runtime BEAM node + `:erpc` streaming (Phase B, P4)
- Private Hex registry (mini_repo) + plugin CI
- 🚫 .difypkg dynamic install, marketplace, signature daemon, remote-debug TCP listener

## 4. Apps & conversations (P1)

All ❌:
- App model (modes: chat, completion, advanced-chat, workflow; 🚫 legacy agent-chat), AppModelConfig, prompt assembly
- Conversations/Messages/feedback/annotations (🚫 annotation-reply ML), saved/pinned messages
- Generation pipeline: supervised task per generation, PubSub streaming, stop, blocking mode
- Site (published LiveView webapp) + JS embed slice; EndUser identity
- ApiToken issuance/hashing; per-app rate limits
- File upload + storage behaviour (S3/local) — storage behaviour itself is still unbuilt P0 work
- Tags, app duplicate/export, operation log
- 🚫 Explore/template gallery, trial apps, education

## 5. Workflow engine — the crown jewel (P3)

All ❌ (plus the critical de-risk item):
- `Flux.Engine`: graph builder/validator, gen_statem run coordinator, per-run Task.Supervisor
- ~20 node types (start/end/answer, llm, code via dify-sandbox, template-transform, http-request+SSRF guard, tool, agent, if-else, iteration, loop, question-classifier, parameter-extractor, variable aggregator/assigner, document-extractor, list-operator, knowledge-retrieval, human-input)
- Variable pool + >256KB object-storage offload; env/conversation variables
- Event stream (~30 engine events) → TaskPipeline translating to Dify's ~45 SSE event schema
- Pause/resume via versioned JSON snapshots; human-in-the-loop forms; timeout jobs
- Cross-node stop via PubSub; retries/error branches; per-workspace concurrency limits
- Run persistence (write-behind batching), run history/log UI, node-execution offload
- Draft debugging (single-node + full-draft, same code path)
- Versioning/publish, DSL YAML import/export (Dify-compatible import is the bar)
- **Golden test harness — NOT STARTED and on the critical path**: needs 15–20 real DSL exports + recorded run traces from a live Dify instance; engine work is supposed to be fixture-driven from day one
- React island canvas (ReactFlow, node panels, zustand+zundo, elkjs) — single biggest UI item; P1 spike still to schedule
- Collaboration: Presence soft-lock first; y_ex CRDT P5 (🚫 loro)
- Triggers: webhook/schedule/plugin trigger tables + dispatch (P4); Agent v2 (config revisions, runtime sessions, ReAct/function-calling strategies) (P4)
- Workflow comments/mentions, run archives (P5+)

## 6. RAG / Knowledge (P2)

All ❌:
- Dataset→Document→Segment→ChildChunk schemas, process rules, metadata
- Ingestion Oban pipeline: extract (Apache Tika container; floki for HTML; native text/md/csv) → clean → split → index processors (paragraph, QA-via-LLM, parent-child)
- Embedding cache table + Cachex; batched embeds
- VectorStore behaviour → **pgvector** (HNSW + tsvector/GIN: semantic, full-text, hybrid in one Postgres); Qdrant on demand; 🚫 other ~28 backends
- Retrieval: semantic/full_text/hybrid/keyword, weighted + model rerank, RRF, multi-dataset merge, citations
- Dataset UI: upload, indexing progress, segment editor, hit testing; batch document status ops (Dify parity)
- External knowledge API binding; datasource plugins (Notion/Firecrawl) when needed
- 🚫 summary index, jieba economy mode (Postgres FTS instead); RAG-pipeline-as-workflow P5

## 7. API surfaces

| Dify surface | Status | Plan |
|---|---|---|
| service API `/v1` (Dify-compatible subset + SSE + `open_api_spex` contract tests) | ❌ | P1 chat/completion/conversations/files → P2 datasets → P3 workflows/run |
| web API slice (passport JWT for embed widget) | ❌ | P1 |
| files (signed URLs) | ❌ | P1 |
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
| Oban queues + FLUX_ROLE role gating | ✅ |
| Quality gates (credo/sobelow/dialyxir/mix_audit) | ✅ local; **no CI pipeline yet** |
| `Flux.Storage` behaviour (S3/MinIO + local) | ❌ P0 remainder |
| Cloak vault + workspace DEKs | ❌ P0 remainder |
| Cachex, hammer rate limiting, SSRF-guard Req step | ❌ P0/P1 |
| PromEx + OpenTelemetry + logger_json (replaces Dify's OTEL + langfuse/langsmith seam) | ❌ P0 remainder |
| mix release + Dockerfile + 4-container compose (app, postgres+pgvector, minio, tika) | ❌ P1 |
| dify-sandbox container integration (code node) | ❌ P3 |
| i18n: gettext wired; second locale + island JSON export | 🟡 gettext default only |
| Email: dev mailbox only; prod adapter (SMTP/SendGrid via swoosh) unconfigured | 🟡 |
| Auth pages still wear generated Phoenix chrome | 🟡 cosmetic |
| Repo folder still `dify-elixir` | 🟡 rename blocked by external file handle |

## 11. Critical path & recommended order

1. **Golden test harness (start immediately, needs the live Dify install)** — export real workflow DSLs + record run traces + SSE snapshots; everything in P3 keys off this.
2. Finish P0: storage behaviour, Cloak vault, workspace switcher, PromEx/OTEL, CI pipeline.
3. P1: model plugin SDK v0 + provider credentials + chat apps + `/v1` SSE (first end-to-end product value).
4. Early spikes that size later phases: ReactFlow island round-trip; `:erpc` chunk streaming; Tika on the enterprise corpus; pgvector load test; Oban Pro decision.
5. P2 RAG → P3 engine+canvas → P4 plugin GA/tools/agents/triggers → P5 enterprise/bulk/SSO.

Remaining effort per the approved plan: ~54–66 engineer-months of the original 60–75
(P0 is most of the way through its 6–8u). The two highest-risk items remain engine
semantic parity (mitigated only by the golden suite) and the canvas port (~218k LOC
upstream; mitigated by the P1 spike deciding reuse vs rewrite).
