# FluxCapacitor → Reference Parity: Analysis & Execution Plan

> "Reference" = the upstream platform we measure parity against (checkout: `C:\Users\jpcre\GitHub\dify`).

Date: 2026-07-30 (rev 4 — tool calling, completion+files, triggers; WS3 backend decision; Agent-v2 re-scope) · Companion: `PARITY-GAP-ANALYSIS.md` · Reference: Reference v1.16.0+197 commits

## 1. Where we actually are

Verified against code (commit 544e50a, clean tree, 16 commits on `main`):

| Metric | Value |
|---|---|
| Lib code | ~12,156 LOC |
| Test code | ~5,300 LOC, 293 tests, 0 failures |
| Reference reference | ~368k LOC Python API + ~218k LOC TS canvas + graphon engine pkg |
| Volume parity | ~3% — but the built slices are complete verticals, not scaffolds |

**Works end-to-end today:** auth/workspaces/members/RBAC → provider credentials
(OpenAI, Anthropic, Gemini; encrypted per-workspace) → chat apps with streaming +
stop → visual workflow builder (8 node types incl. http-request, multi-select canvas, undo/redo,
zoom/pan, run drawer, run history, publish/versioning) → OpenAPI custom tools with
encrypted auth/private variables → Reference-compatible `/v1` chat + workflow-run APIs
with hashed tokens → local production release (OTP release + migrations + seeds).

### Scorecard by area (share of Reference capability, judged by feature, not LOC)

| Area | ~% | Have | Biggest absences |
|---|---|---|---|
| Identity/tenancy/teams | 75% | auth, workspaces, roles, invites, switcher, tenant guard | SSO/SAML/SCIM, custom roles, resource-level perms |
| Model runtime | 45% | 3 real providers, streaming LLM, **tool calling (all 3 providers, streamed accumulation)**, encrypted creds, validation | embeddings/rerank, structured output, default models, load balancing, azure/bedrock |
| Apps & conversations | 45% | chat + completion modes, prompt templates + input_form, file upload, API tokens, feedback | advanced-chat/workflow modes, **site publishing/embed**, multimodal input |
| Workflow engine | 40% | 8/20 nodes (incl. http-request), branch exec, publish/versions, runs+traces, draft debug, **DSL import + export (round-trip tested)** | iteration/loop, code, classifiers/extractors, aggregators, human-input, pause/resume, retries/error branches, conversation vars |
| Canvas | 40% | drag/connect, multi-select+marquee, group move, undo/redo, zoom/pan, history | minimap, copy/paste, node search palette, per-node debug run, variable picker UI, autolayout |
| Tools | 55% | **OpenAPI import → callable ops, encrypted auth + private vars, tool node** | built-in tool catalog, tool plugins, agent tool-calling |
| RAG / Knowledge | **0%** | — | everything: datasets, ingestion, pgvector, retrieval, UI, API, knowledge node |
| API surfaces | 50% | 9 `/v1` routes (+completion-messages, files/upload) + public webhook triggers | conversation rename/delete, meta, web/embed API, datasets API, OpenAPI contract tests |
| Plugin system | 20% | SDK ModelProvider behaviour, supervised invocation | Tool/Datasource/Trigger/Endpoint behaviours, install flow, registry |
| Agents | 30% | agent node v1: tool loop + iteration cap + canvas panel | structured final_output, deferred-tool HITL, shell/drive capabilities (v2 scope) |
| Enterprise | 5% | RBAC catalog, vault | audit log, SSO, licensing/features, bulk ops, importer |
| Infra/ops | 60% | CI, gates, OTP release + local deploy, storage (now consumed), vault, rate limiting, SSRF guard, **first Oban worker (schedule triggers)** | **Dockerfile/compose**, PromEx/OTEL |

### Standing debt — status after the WS0/WS1 sprint (2026-07-27)

1. ~~Uncommitted~~ → **committed as 8 logical commits on `main`**; push still blocked on `gh auth login` (no remote yet — the one remaining WS0 item).
2. ~~SSRF~~ → **fixed**: `Flux.SSRF` guards provider + toolset + validation calls; `FLUX_SSRF_ALLOW` for exemptions.
3. ~~No rate limiting~~ → **fixed**: hammer on `/v1` (120/min per token principal) and auth POSTs (10/min per IP).
4. ~~Accounts RBAC~~ → **fixed** at the context level, with bypass tests.
5. **Golden harness: phase 1 done** — DSL importer runs verbatim Reference fixtures (from `dify/api/tests/fixtures/workflow`) through the engine with behavioral assertions. Phase 2 (recorded run traces + SSE transcripts from a live Reference) needs Docker Desktop installed.
6. ~~Stop prefix loss / untested providers~~ → **fixed** (ETS stream buffers; 10 Req.Test provider suites). Remaining from this list: no metrics exporter (WS7).

## 2. The plan

Eight workstreams. WS0/WS1/WS2 are immediate; WS3–WS7 sequence after.

### WS0 — Ship hygiene ✅ (2026-07-27, push pending)
- ✅ 8 logical commits on `main` (renamed from master to match CI trigger); digest artifacts cleaned + gitignored.
- ⏳ Remaining: `gh auth login` (user), then create GitHub repo, push, confirm CI green.

### WS1 — Security & correctness sprint ✅ (2026-07-27)
- ✅ `Flux.SSRF` guard on providers, toolsets, credential validation (private/loopback/link-local/CGNAT/metadata blocked both IP families; per-env config + `FLUX_SSRF_ALLOW`).
- ✅ hammer rate limiting (`/v1` 120/min per principal; auth POSTs 10/min per IP; 429 + Retry-After).
- ✅ Context-level RBAC in `Flux.Accounts` member mutations (+ bypass tests). Router-level RBAC plug still open (small, fold into WS5).
- ✅ Stop-generation prefix preserved via ETS stream buffers.
- ✅ Req.Test HTTP-mock suites for all three providers (SSE parsing, malformed frames, error paths).
- ✅ Tool body args coerce to spec-declared JSON types.

### WS2 — Golden test harness (phase 1 ✅; phase 2 needs Docker)
- ✅ **DSL importer v0** (`Flux.Workflows.DSL`): workflow/advanced-chat exports → flux graphs; selector/Jinja conversion; unsupported nodes dropped with warnings; Import DSL UI on the Fluxes page.
- ✅ Conformance tests over **verbatim Reference fixtures** (copied from `dify/api/tests/fixtures/workflow`) including behavioral runs (if-else routing matches the fixture's documented semantics).
- ⏳ Phase 2: run live Reference via Docker; record run traces + SSE transcripts for 15–20 workflows; extend the runner to compare traces, not just outputs. Gate stands: every WS4 engine feature lands with harness fixtures.

### WS3 — RAG / Knowledge, the missing pillar (~8–12 weeks)

**Backend decision (2026-07-30): ArangoDB-first behind a `Flux.RAG.VectorStore`
behaviour.** Postgres stays the system of record (datasets/documents/segments,
tenancy-guarded) — the vector store is a replaceable index, exactly the Reference's own
pattern for its ~28 backends. Arango (≥3.12.4) supplies vectors (FAISS index,
APPROX_NEAR_COSINE), BM25 full-text (ArangoSearch), and — the differentiator —
graphs for a later GraphRAG phase (entity/relation edges + traversal-augmented
retrieval, which Reference lacks). Client = thin Req HTTP layer (~200 LOC; no
official Elixir driver — arangox is aging). A `Naive` backend (exact cosine in
Postgres) keeps CI hermetic. Open items before build: BUSL-1.1 license
acceptability; Arango is Docker-only on Windows (same blocker as pgvector);
pgvector remains a cheap second backend if Arango disappoints.

Order inside the workstream:
1. **docker-compose** (app, postgres, arangodb, minio, tika) — Docker Desktop is the unblock.
2. Embeddings invocation kind in the plugin SDK + OpenAI/Gemini embedding models.
3. Dataset→Document→Segment schemas; upload wired to `Flux.Storage` (first real consumer).
4. Ingestion pipeline as the **first real Oban workers**: extract (native text/md/csv + floki HTML; Tika for office docs) → clean → split → embed (cached) → index.
5. `VectorStore` behaviour → Arango backend (vector index + ArangoSearch view) + Naive test backend; semantic/full-text/hybrid via app-side RRF; rerank hook.
6. Knowledge UI: upload, indexing progress, segment editor, hit testing.
7. `knowledge-retrieval` engine node + citations into chat; `/v1/datasets` subset.

### WS4 — Engine depth to parity (~6–10 weeks, fixture-driven)
- ✅ http-request node (2026-07-30): host-injected + SSRF-guarded; editor panel; DSL import maps Reference http-request cleanly.
- question-classifier + parameter-extractor (needs structured-output support in providers).
- variable aggregator/assigner; list-operator; document-extractor.
- **iteration/loop** — do a design spike first: allowing cycles inside loop scopes
  touches the validator and runner; biggest structural risk in the engine.
- **Code node with per-block dependencies — decision 2026-07-31: our own `flux-coderunner`, NOT dify-sandbox** (its fixed dependency set can't do per-block libraries; ours is a Reference superset).
  - Contract mirrors Reference exactly (`main(**variables) -> dict`) so imported DSL code nodes run unchanged; adds `dependencies: [{name, version}]`.
  - Engine `code` node → host capability `run_code` → `Flux.CodeRunner` behaviour with `Sandbox` (HTTP to runner container), `Local` (dev-only, opt-in, unsafe), `Fake` (CI) backends.
  - **Multi-language via adapters (rev 2026-07-31)**: one runner, one protocol (POST /run {language, code, dependencies, inputs, timeout_ms}; GET /languages feeds the editor dropdown); per-language adapter = prepare(deps)→cached env_ref + execute(env, code, inputs, limits) + wrapper. Line-up: python3 (uv venv cache by depset hash), **typescript/javascript via Deno** (npm: import maps, no install step, built-in --deny-net sandbox at execution — closes the network gap for JS from day one), bash (allowlisted binaries), ruby via bundler/inline later. Result channel = /workdir/__result__.json (stdout kept separate as {{code_x.stdout}}); rlimits + wall timeout (30s/120s cap) + 256KB output cap; internal-network only + API-key auth. Adding a language touches only the runner.
  - Phases: **P0 ✅ (2026-07-31)** — engine code node + run_code capability, CodeRunner behaviour (Sandbox HTTP client/Local dev subprocess/Fake CI), editor panel, DSL import/export mapping, Reference code fixture imports clean; engine now at **10/20 node types**. → P1 (runner container in the WS3 compose, ~2–3d) → P2 (hardening: install/execute network split, per-workspace dep allowlist, single-node test-run button ≈ WS4 draft debugging, ~2–3d).
  - Known gap until P2: network reachable during code execution (documented, not hidden).
- Retries + error branches; env/conversation variables; human-input + pause/resume snapshots.
- DSL import hardening (harness fixtures); export ✅ (2026-07-30, JSON-as-YAML, round-trip tested, editor Export button).
- advanced-chat (chatflow) app mode: conversations backed by the engine.

### WS5 — Product surface (~4–6 weeks, parallelizable with WS4)
- `/v1` completion: ✅ conversations list, messages, feedback, stop, parameters (2026-07-30).
  Remaining: conversation rename/delete, files upload, meta, completion-messages, `open_api_spex` contract tests.
- **Site publishing**: app sites ✅ (2026-07-31, chat + completion + iframe embed + EndUser refs); workflow form page per flux + JS bubble embed still open.
- Completion app mode; app-of-mode-workflow binding (app ↔ flux).
- Default/system model config; azure_openai + bedrock providers.

### WS6 — Agents & plugin GA (~8–10 weeks)
- ✅ **Tool calling in the ModelProvider SDK** (2026-07-30): ToolDef/ToolCall, tool-result message encoding, streamed tool-call parsing in OpenAI/Anthropic/Gemini, finish_reason :tool_calls.
- ✅ **Triggers** (2026-07-30): webhook `POST /triggers/webhook/:token` (202 + run id) and interval schedules via `Flux.Workflows.ScheduleWorker` on an Oban minute-cron. Console trigger UI still pending.
- **Agent node — re-scope DONE (2026-07-30), key findings from reading `dify-agent`/`dify-agent-runtime`:**
  - There are **no strategies and no hand-rolled loop to port**: Agent v2 delegates the loop to pydantic-ai; termination is a `final_output` tool + structured output, HITL is a run that *ends* with `deferred_tool_call` and resumes as a new run with `deferred_tool_results` + an opaque `session_snapshot` (no server-side session, no pause state). Notably there is **no max-iteration guard upstream** — we should add one.
  - `dify-agent-runtime` (Go) is not an agent runtime; it's a Landlock/tmux **shell-sandbox job server** for the agent's shell tool. The tiny gRPC proto is only the sandbox→host file-transfer callback. Skip unless/until we ship a shell tool.
  - Worth mirroring: composition-as-data (layers with type-id allowlist ≈ our host capabilities, made declarative), snapshot-out resumability, deferred-tool-call HITL, terminal-event-carries-everything, and the event vocabulary (`run_started/…/run_succeeded`; inner `part_start/part_delta/function_tool_call/function_tool_result`, `part_kind: thinking`) if we want frontend wire compat.
  - Collapse into OTP: the whole HTTP+SSE+Redis-stream transport and the service split exist to escape Python's process model — our supervised runs + PubSub already provide it; keep the cursor/replay property.
  - Scope warning: v2 "agent parity" also includes shell/drive/config-asset ("Agent Soul") capabilities with no v1 analogue — far beyond the loop. Phase those separately.
  - ✅ **Agent node v1 shipped (2026-07-31)**: engine loop (LLM↔toolset tools, role:tool history, agent_tool_call events), max-iteration guard, editor panel snapshotting toolset ops into JSON-schema tool defs. Engine at **11/20 node types**. Remaining for v2: final_output structured output, deferred-tool HITL, streaming thought vocabulary.
- Plugin SDK: Tool/Datasource/Trigger/Endpoint behaviours; per-workspace installations.

### WS7 — Ops & enterprise (ongoing → P5)
- Near-term: PromEx + OpenTelemetry + logger_json; audit-log context (`Flux.Audit`) so
  contexts start recording now even before the browsing UI.
- Later (P5 proper): SSO (OIDC/SAML) + SCIM, custom roles, licensing/features layer,
  bulk-operations framework, `mix flux.import` from live Reference.

## 3. Milestones

| Milestone | Target | Definition of done |
|---|---|---|
| M0 | +1 week | Pushed to GitHub, CI green, WS1 hardening merged — **hardening ✅, commits ✅; push pending gh auth** |
| M1 | +3 weeks | Harness runs ≥10 Reference fixtures incl. recorded traces; DSL import passes them — **4 fixtures + importer ✅; traces need Docker** |
| M2 | +9 weeks | RAG MVP: upload → index → hybrid retrieve → knowledge node in a flux → cited answer; compose stack |
| M3 | +14 weeks | Engine core parity (http/code/classifier/extractor/aggregator/loop), DSL import green on full fixture set |
| M4 | +18 weeks | `/v1` subset complete + contract tests; site publishing + embed live |
| M5 | +26 weeks | Agent node, plugin behaviours — **tool calling ✅ and triggers ✅ pulled forward to 07-30** |
| M6 | — | Enterprise: SSO/SCIM, audit UI, custom roles, licensing, bulk ops |

Effort remaining vs the approved plan: roughly **46–58 engineer-months** of the
original 60–75 (P0 done; P1 ~60%; P3 ~30% pulled forward; P4 ~15% pulled forward).
Timeline above assumes ~2–3 engineers; single-engineer pace ≈ 2.5× the durations.

## 4. Top risks & mitigations

1. **Engine semantic drift** (high → medium) — structural/behavioral fixtures now run in CI; trace-level comparison still missing until a live Reference records them (Docker). Keep the freeze on new node types until phase 2 lands.
2. **Iteration/loop graph-model change** (medium) — cycles-in-scope may force validator/runner refactor. Mitigation: design spike at WS4 start, before more nodes stack on the current walker.
3. **RAG scale unknowns** (medium) — Tika throughput, embedding costs, pgvector at enterprise corpus size. Mitigation: load-test spike with a real corpus in WS3 step 5.
4. **Upstream drift** (medium) — Agent v2 externalized upstream. Mitigation: WS6 starts with a re-scoping read of `dify-agent`/`dify-agent-runtime`.
5. **Single-machine, uncommitted code** (high, trivial to fix) — WS0 this week.
6. **Oban Pro buy/no-buy** still open — decide during WS3 (first heavy queue user).

## 5. Ledger: unblocked backlog vs blocked items (2026-07-31)

### Unblocked (buildable now, in priority order)
1. ~~Console UI for triggers~~ ✅ (2026-07-31): editor Triggers modal — list/create webhook+schedule, webhook URL shown, enable/disable, delete, static-inputs JSON.
2. ~~Console UI for completion apps~~ ✅ (2026-07-31): mode select + template on create, variables editor + run panel on the app page, `/v1/parameters` now serves the real `user_input_form`.
3. ~~Site publishing~~ ✅ (2026-07-31, complete): app sites (`/site/:token`) AND flux form pages (`/site/flux/:token`, runs the published version), anonymous `web_…` end-user refs, publish/unpublish console UIs, iframe + JS bubble embeds (`/embed.js`), hammer rate limiting on public LiveView events (120/min per site, 15/min per visitor IP).
4. ~~`open_api_spex` contract tests~~ ✅ (2026-07-31): strict schemas (additionalProperties: false) + tests over all 12 `/v1` routes.
5. ~~Agent v2 features~~ ✅ (2026-07-31): `output_schema` → synthetic `final_output` tool → structured `"output"`; deferred tools → `status=deferred` + `session_snapshot` resume with `deferred_tool_results`; `agent_part` events (part_start/part_delta thinking, function_tool_call/result) incl. `/v1` SSE.
6. azure_openai + bedrock providers (default/system model config ✅ 2026-07-31 — workspace default in custom_config, Host.resolve_llm fallback, Plugins-page selector).
7. ~~Router-level RBAC plug~~ ✅ (RequirePermission plug, DSL export gated on app_import_export_dsl); ~~PromEx + logger_json + audit context~~ ✅ (2026-07-31: /metrics behind FLUX_METRICS, FLUX_LOG_JSON structured logs, `Flux.Audit` recording app/site/publish/credential mutations); ~~OTEL traces~~ ✅ (Phoenix/Bandit/Ecto + flux.workflow.run span, OTLP via standard env vars); ~~audit browsing UI~~ ✅ (/console/audit, owner/admin).
8. ~~Engine depth batch~~ ✅ (2026-07-31): variable aggregator + assigner, list-operator, **question-classifier + parameter-extractor** (forced tool calls; per-class branch handles), **retries + error branches** (retry.max_retries ≤5; "error" handle routes failures), **env + conversation variables** ({{env.*}}/{{conversation.*}}/{{sys.*}}, Variables modal, DSL round-trip). Engine at **15/20 node types**. Iteration/loop spike still waits for the harness (Docker).
9. ~~advanced-chat (chatflow) app mode~~ ✅ (2026-07-31): apps bound to a flux; each turn runs the published version with {{sys.query}}, streams through the chat pipeline, persists conversation variables. Console/site/v1 all work through send_message.
10. ~~Canvas copy/paste + searchable node palette~~ ✅ (2026-07-31).
11. ~~Third 2026-07-31 batch~~ ✅: harness fixtures for the new nodes (classifier routing, extractor+list-op+env); per-node debug run (`Workflows.debug_node` + Test-this-node panel); clickable variable picker; **document-extractor** (native text/HTML, Tika deferred); **iteration node v1** (map list through a published sub-flux — see docs/ITERATION-DESIGN.md; loop/while deferred with rationale); **human-input + run pause/resume** (snapshot on the run row, editor resume form, `POST /v1/workflows/runs/:id/resume`); app monitoring console (`/console/apps/:id/monitor`); opening statement + suggested questions (console, public site, `/v1/parameters`); **custom roles** (roles table, exact-subset grants, Members-page editor). Engine at **19/20 node types** (only knowledge-retrieval remains — RAG/Docker-blocked).

### Blocked — external unblocks required
| Item | Blocked on |
|---|---|
| ~~Push to GitHub~~ ✅ (2026-07-31: `canuckasaurus/fluxcapacitor`, folder renamed too — WS0 complete) | CI-green confirmation still needs `gh auth login` (token stale) |
| flux-coderunner container (code node phase 1: real deps + sandbox) | Docker Desktop |
| RAG workstream WS3 (ArangoDB + compose stack: postgres/arango/minio/tika) | Docker Desktop |
| Golden harness phase 2 (recorded run traces + SSE transcripts) | Docker Desktop (live Reference instance) |
| Code node phase 2 hardening (network-namespace split) | phase 1 (Docker) |
| ArangoDB BUSL-1.1 license acceptability review | user/legal decision |
| Prod email adapter (magic links beyond the local mailbox) | choice of SMTP/API provider + credentials |
| bcrypt swap (currently pbkdf2) | Linux/CI build (no local C toolchain) |
