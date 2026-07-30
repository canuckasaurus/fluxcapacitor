# FluxCapacitor → Dify Parity: Analysis & Execution Plan

Date: 2026-07-27 · Companion to `PARITY-GAP-ANALYSIS.md` (status detail) · Reference: Dify v1.16.0+197 commits

## 1. Where we actually are

Verified against code (commit f1bf749 + 44 uncommitted files):

| Metric | Value |
|---|---|
| Lib code | ~10,829 LOC (was 6,328 at last analysis — +71%) |
| Test code | ~4,400 LOC, 258 tests, 0 failures |
| Dify reference | ~368k LOC Python API + ~218k LOC TS canvas + graphon engine pkg |
| Volume parity | ~3% — but the built slices are complete verticals, not scaffolds |

**Works end-to-end today:** auth/workspaces/members/RBAC → provider credentials
(OpenAI, Anthropic, Gemini; encrypted per-workspace) → chat apps with streaming +
stop → visual workflow builder (7 node types, multi-select canvas, undo/redo,
zoom/pan, run drawer, run history, publish/versioning) → OpenAPI custom tools with
encrypted auth/private variables → Dify-compatible `/v1` chat + workflow-run APIs
with hashed tokens → local production release (OTP release + migrations + seeds).

### Scorecard by area (share of Dify capability, judged by feature, not LOC)

| Area | ~% | Have | Biggest absences |
|---|---|---|---|
| Identity/tenancy/teams | 75% | auth, workspaces, roles, invites, switcher, tenant guard | SSO/SAML/SCIM, custom roles, resource-level perms |
| Model runtime | 35% | 3 real providers, streaming LLM, encrypted creds, validation | embeddings/rerank, **tool calling**, structured output, default models, load balancing, azure/bedrock |
| Apps & conversations | 30% | chat mode end-to-end, API tokens | completion/advanced-chat/workflow modes, **site publishing/embed**, feedback, file input, prompt variables |
| Workflow engine | 30% | 7/20 nodes, branch exec, publish/versions, runs+traces, draft debug | iteration/loop, code, http-request, classifiers/extractors, aggregators, human-input, pause/resume, retries/error branches, **DSL import/export**, conversation vars |
| Canvas | 40% | drag/connect, multi-select+marquee, group move, undo/redo, zoom/pan, history | minimap, copy/paste, node search palette, per-node debug run, variable picker UI, autolayout |
| Tools | 55% | **OpenAPI import → callable ops, encrypted auth + private vars, tool node** | built-in tool catalog, tool plugins, agent tool-calling |
| RAG / Knowledge | **0%** | — | everything: datasets, ingestion, pgvector, retrieval, UI, API, knowledge node |
| API surfaces | 15% | `/v1` chat-messages + workflows/run (SSE+blocking) | ~13 more `/v1` routes, files, web/embed API, datasets API, OpenAPI contract tests |
| Plugin system | 20% | SDK ModelProvider behaviour, supervised invocation | Tool/Datasource/Trigger/Endpoint behaviours, install flow, registry |
| Agents | 0% | — | agent node, strategies; upstream moved to `dify-agent` + Go runtime — re-scope before building |
| Enterprise | 5% | RBAC catalog, vault | audit log, SSO, licensing/features, bulk ops, importer |
| Infra/ops | 50% | CI, quality gates, OTP release + local deploy, storage, vault, Oban config | **Dockerfile/compose**, PromEx/OTEL, rate limiting, SSRF guard, zero Oban workers |

### Standing debt (gets more expensive every week it waits)

1. **Not pushed anywhere** — no git remote; 44 files uncommitted; CI has never run. One disk failure loses the project.
2. **SSRF** — three features now make arbitrary user-directed HTTP calls (provider `base_url`, tool base URLs, future http-request node) with no private-IP guard.
3. **No rate limiting** on `/v1` or auth.
4. `Flux.Accounts` member mutations lack context-level RBAC (UI-only guard).
5. **Golden test harness still not started** — engine semantics are now being invented feature-by-feature with nothing to check them against Dify. This risk *compounds*: every node type added pre-harness may need re-work.
6. Stop-generation loses streamed prefix; providers have no HTTP-mocked tests; no metrics exporter.

## 2. The plan

Eight workstreams. WS0/WS1/WS2 are immediate; WS3–WS7 sequence after.

### WS0 — Ship hygiene (days) ← do first
- Commit the session's work as logical commits; create GitHub repo; push; make CI green remotely.
- Keep the local release deploy as the smoke environment.

### WS1 — Security & correctness sprint (~1–2 weeks)
- Shared **SSRF-guarded Req step** (deny private/link-local IPs + metadata endpoints, per-workspace allowlist) applied to providers, tools, and every future outbound call.
- **hammer** rate limiting: `/v1` per-token, auth endpoints per-IP.
- Push RBAC into `Flux.Accounts` member functions; add the router-level RBAC plug the moduledoc promises.
- Fix stop-generation prefix loss (accumulate in-process, persist on kill).
- `Req.Test` HTTP-mock suites for OpenAI/Anthropic/Gemini SSE parsing (incl. malformed frames).
- Typed coercion for tool body args from spec schemas.

### WS2 — Golden test harness (~2–3 weeks, start in parallel with WS1)
- Run a live Dify via docker locally. Author 15–20 workflows covering node semantics
  (branching, variable scoping, error paths, streaming order); export DSL YAML;
  record run traces + SSE transcripts as fixtures.
- Build the conformance runner: DSL import → `Flux.Engine` run → compare outputs/trace shape.
- This *is* the DSL importer v0 — the mapping table grows fixture by fixture.
- Gate: every WS4 engine feature lands with harness fixtures, not hand-written expectations.

### WS3 — RAG / Knowledge, the missing pillar (~8–12 weeks)
Order inside the workstream:
1. **docker-compose** (app, postgres+pgvector, minio, tika) — pulled forward from infra because pgvector needs it.
2. Embeddings invocation kind in the plugin SDK + OpenAI/Gemini embedding models.
3. Dataset→Document→Segment schemas; upload wired to `Flux.Storage` (first real consumer).
4. Ingestion pipeline as the **first real Oban workers**: extract (native text/md/csv + floki HTML; Tika for office docs) → clean → split → embed (cached) → index.
5. `VectorStore` behaviour → pgvector (HNSW) + tsvector/GIN; semantic/full-text/hybrid + RRF; rerank hook.
6. Knowledge UI: upload, indexing progress, segment editor, hit testing.
7. `knowledge-retrieval` engine node + citations into chat; `/v1/datasets` subset.

### WS4 — Engine depth to parity (~6–10 weeks, fixture-driven)
- http-request node (WS1's SSRF guard is the prerequisite).
- question-classifier + parameter-extractor (needs structured-output support in providers).
- variable aggregator/assigner; list-operator; document-extractor.
- **iteration/loop** — do a design spike first: allowing cycles inside loop scopes
  touches the validator and runner; biggest structural risk in the engine.
- code node via dify-sandbox container (compose already present from WS3).
- Retries + error branches; env/conversation variables; human-input + pause/resume snapshots.
- DSL import hardening (harness fixtures) + export.
- advanced-chat (chatflow) app mode: conversations backed by the engine.

### WS5 — Product surface (~4–6 weeks, parallelizable with WS4)
- `/v1` completion: conversations list/rename/delete, messages, feedback, stop,
  files upload, parameters, meta, completion-messages + `open_api_spex` contract tests.
- **Site publishing**: public chat page + workflow form page per app/flux, EndUser identity, JS embed snippet.
- Completion app mode; app-of-mode-workflow binding (app ↔ flux).
- Default/system model config; azure_openai + bedrock providers.

### WS6 — Agents & plugin GA (~8–10 weeks, after tool calling)
- **Tool calling in the ModelProvider SDK** + provider implementations (prerequisite for everything agentic).
- Agent node: function-calling strategy first; ReAct later.
  ⚠ Re-scope against upstream first — Dify's Agent v2 now lives in `dify-agent` (Python SDK) + `dify-agent-runtime` (Go); copying the v1.16 in-process design may be building yesterday's architecture.
- Plugin SDK: Tool/Datasource/Trigger/Endpoint behaviours; per-workspace installations.
- Triggers: webhook (`/triggers/webhook/:id`) + schedules on Oban.

### WS7 — Ops & enterprise (ongoing → P5)
- Near-term: PromEx + OpenTelemetry + logger_json; audit-log context (`Flux.Audit`) so
  contexts start recording now even before the browsing UI.
- Later (P5 proper): SSO (OIDC/SAML) + SCIM, custom roles, licensing/features layer,
  bulk-operations framework, `mix flux.import` from live Dify.

## 3. Milestones

| Milestone | Target | Definition of done |
|---|---|---|
| M0 | +1 week | Pushed to GitHub, CI green, WS1 hardening merged |
| M1 | +3 weeks | Harness runs ≥10 Dify fixtures; DSL import v0 passes them |
| M2 | +9 weeks | RAG MVP: upload → index → hybrid retrieve → knowledge node in a flux → cited answer; compose stack |
| M3 | +14 weeks | Engine core parity (http/code/classifier/extractor/aggregator/loop), DSL import green on full fixture set |
| M4 | +18 weeks | `/v1` subset complete + contract tests; site publishing + embed live |
| M5 | +26 weeks | Tool calling, agent node, plugin behaviours, webhook/schedule triggers |
| M6 | — | Enterprise: SSO/SCIM, audit UI, custom roles, licensing, bulk ops |

Effort remaining vs the approved plan: roughly **46–58 engineer-months** of the
original 60–75 (P0 done; P1 ~60%; P3 ~30% pulled forward; P4 ~15% pulled forward).
Timeline above assumes ~2–3 engineers; single-engineer pace ≈ 2.5× the durations.

## 4. Top risks & mitigations

1. **Engine semantic drift** (high, compounding) — no fixtures yet. Mitigation: WS2 immediately; freeze new node types until the harness runs.
2. **Iteration/loop graph-model change** (medium) — cycles-in-scope may force validator/runner refactor. Mitigation: design spike at WS4 start, before more nodes stack on the current walker.
3. **RAG scale unknowns** (medium) — Tika throughput, embedding costs, pgvector at enterprise corpus size. Mitigation: load-test spike with a real corpus in WS3 step 5.
4. **Upstream drift** (medium) — Agent v2 externalized upstream. Mitigation: WS6 starts with a re-scoping read of `dify-agent`/`dify-agent-runtime`.
5. **Single-machine, uncommitted code** (high, trivial to fix) — WS0 this week.
6. **Oban Pro buy/no-buy** still open — decide during WS3 (first heavy queue user).
