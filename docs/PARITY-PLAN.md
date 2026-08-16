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

### WS3 — RAG / Knowledge — **CORE SHIPPED WITHOUT DOCKER (2026-08-01)**

Datasets/documents/segments schemas, chunker, Oban ingestion (`:ingest`),
embeddings SDK (OpenAI/Gemini/openai_compatible/Echo), **Naive vector
backend** (exact Postgres cosine behind the `VectorStore` behaviour) +
Postgres full-text, hybrid RRF retrieval, Knowledge UI (upload/paste,
status, segments, hit testing), **knowledge-retrieval node → 20/20 node
types**, `/v1/datasets` subset. Still Docker-bound: ArangoDB backend
(same behaviour), Tika formats, compose stack, corpus-scale load test.

**2026-08-01 follow-on batch ✅:** citations flow onto chat answers
(console + site source footnotes); per-dataset chunk settings +
re-index; **rerank hook** (`invoke_rerank` SDK + optional retrieval
rerank, Echo lexical reranker for CI); per-app daily token quotas
(429 on the API); **tool plugins** (Flux.Plugin.Tool behaviour,
per-workspace installations, built-in Utilities plugin, `plugin:<id>`
pseudo-toolsets in tool/agent nodes — WS6 GA started); human-input
pause/resume on public flux sites; workspace settings page
(rename/default model/owner-only delete); RAG-chatflow harness fixture;
run-trace duration bars.

### WS3 (original plan, for reference) — (~8–12 weeks)

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
- Plugin SDK ✅ COMPLETE (2026-08-01): ModelProvider + Tool + Datasource + Trigger + Endpoint behaviours with per-workspace installations, credentials, and endpoint tokens.

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
11a. ~~2026-08-01 batch~~ ✅: multi-case if-else (elif chains, per-case handles/ports, DSL both ways); chatflow memory ({{sys.history}}/{{sys.turns}}); LLM structured output (output_schema → {{node.output}}); public-site conversation persistence (signed-session visitor ref + start-over); **cron schedule triggers** (Oban.Cron.Expression validation + minute-tick matching — Oban is the platform scheduler, no external orchestrator); audit coverage for members/roles/tokens/triggers; canvas **minimap + auto-layout**; per-app usage metering (daily token rollups on the monitor page); **OpenAPI contract published at GET /v1/spec**.
11. ~~Third 2026-07-31 batch~~ ✅: harness fixtures for the new nodes (classifier routing, extractor+list-op+env); per-node debug run (`Workflows.debug_node` + Test-this-node panel); clickable variable picker; **document-extractor** (native text/HTML, Tika deferred); **iteration node v1** (map list through a published sub-flux — see docs/ITERATION-DESIGN.md; loop/while deferred with rationale); **human-input + run pause/resume** (snapshot on the run row, editor resume form, `POST /v1/workflows/runs/:id/resume`); app monitoring console (`/console/apps/:id/monitor`); opening statement + suggested questions (console, public site, `/v1/parameters`); **custom roles** (roles table, exact-subset grants, Members-page editor). Engine at **19/20 node types** (only knowledge-retrieval remains — RAG/Docker-blocked).
12. ~~2026-08-01 batch (#56–64)~~ ✅: **Dockerfile + compose stack authored** (multi-stage release image; postgres/minio base, `rag` profile adds arangodb+tika, `full` runs the app — verification still Docker-blocked); **version browser + rollback** (editor Versions modal, restore goes through undo history); **URL ingestion** (`add_document_from_url`: SSRF-guarded fetch, HTML→text, 5MB cap); **multi-dataset retrieval** (`retrieve_many` merge + knowledge node `dataset_ids` checkboxes); **run retention** (per-workspace `retention_days`, nightly CleanupWorker prunes runs/messages, paused/streaming survive); **failure alerting** (per-workspace `alert_url` webhook, SSRF-validated, AlertWorker with retries); **public-site theming** (accent/title/logo URL, strict hex validation before the inline style block); **conversation switcher** on public sites (visitor's last 10 threads, ownership-checked); **datasource plugin behaviour** (`Flux.Plugin.Datasource` SDK + runtime hosting, built-in RSS feed plugin, `RAG.sync_datasource` Oban sync with name-dedupe, Knowledge-page sync form, datasources install/configure through the existing plugin + credential stores).

13. ~~Second 2026-08-01 batch (#65–73)~~ ✅: **README** (architecture diagram + platform overview); **trigger plugin behaviour** (`Flux.Plugin.Trigger` — cursor-based polling on the minute tick, one run per event, RSS doubles as the built-in trigger source); **endpoint plugin behaviour** (`Flux.Plugin.Endpoint` — installations serve HTTP at `/e/:token/*path`, Utilities plugin serves /time + /calculate; **plugin SDK behaviour set now complete**: ModelProvider/Tool/Datasource/Trigger/Endpoint); **flux-site theming** (accent/title/logo on public form pages); **datasource auto-sync** (per-dataset interval, 5-minute cron sweep); **segment editor** (edit + re-embed in place, disable from retrieval, delete with honest counts); **dataset retrieval settings** (per-dataset top_k default + score threshold, knowledge node defers); **`/v1/datasets` expansion** (create-by-url, segment browsing, document/dataset deletes — standalone knowledge API); **vision inputs** (`files` on /v1/chat-messages → base64 image parts in all three real providers + echo acknowledgment); **feedback review** (monitor page lists rated replies with their questions, like/dislike filter).

14. ~~Third 2026-08-01 batch (#74–79)~~ ✅: **agent scratch drive** (`enable_drive` → drive_write/read/list tools in loop state — sandboxed by construction, snapshot-safe, `files` output); **GraphRAG groundwork** (deterministic entity extraction into `rag_entities`/`rag_entity_mentions`, entity mentions as a third RRF retrieval source, `related_entities` co-occurrence — Arango traversal slots in on the same tables); **OIDC SSO** (env-configured, local JWKS verification via jose, accounts provisioned confirmed; forged-key/audience/state rejections tested); **bulk operations** (multi-select fluxes: delete + multi-document YAML export); **hardening** (endpoint-plugin 120/min per-token limit + 1MB response cap, RSS feed/poll caps, audit for segment mutations + auto-sync config); **annotation replies** (liked answers promoted to canonical responses, normalized matching short-circuits the model with hit counts). Plus a correctness fix: messages order by a DB-assigned `seq` (UUIDv7 ids tie within a millisecond).

15. ~~Fourth 2026-08-01 batch (#80–84)~~ ✅: **SCIM 2.0 provisioning** (workspace bearer token from settings; /scim/v2/Users list/filter/create/patch-active/delete; provisioned accounts arrive confirmed as normal members; deprovision removes membership only, owner refused; speaks application/scim+json); **LLM entity extraction** (dataset-bound chat model, extract-to-JSON prompt, heuristic default + fallback); **annotation fuzzy matching** (questions embedded at creation, per-app similarity threshold, exact match stays first/free); **workspace usage dashboard** (`Flux.Usage`: tokens/replies across apps + daily breakdown + top apps, runs by status, storage, knowledge size); **licensing layer** (`Flux.Features`: free/team/enterprise plans, self-hosted default enterprise, gates on custom roles/annotations/datasource sync/SCIM/LLM extraction, owner-set + audited — the hook a license validator plugs into). WS7 enterprise scope (SSO, SCIM, custom roles, licensing, audit, bulk ops) is now **complete except prod-email + bcrypt (blocked)**.

16. ~~Fifth 2026-08-01 batch (#85–96)~~ ✅: **parallel branch execution** (multi-edge handles fan out into concurrent tasks, pools merge at the shared join — real wall-clock wins for independent model calls); **loop node** (21st node type: bounded while over a published sub-flux, if_else-style break condition, cap 100); **model fallback chains** (LLM nodes try a configured backup on primary error, model_used/fallback_used in the trace); **named provider credentials** (several keys per provider with a default flag — rotation without downtime); **graph reference linting** (`Flux.Engine.Lint` warns on {{refs}} to missing/non-upstream nodes in the editor issue badge); **conversation auto-titling** (first question, rename-safe); **conversation search** (monitor page, wildcard-escaped ilike); **soft-delete trash** (fluxes/apps stamp deleted_at, everything excludes them, restore/purge UI, 30-day nightly purge); **workspace export** (one JSON archive of all DSL + dataset docs + scrubbed settings); **webhook signing** (outgoing alerts HMAC-signed with a minted whsec_ secret; incoming triggers optionally require x-flux-token); **datasets in the OpenAPI contract** (strict schemas + contract tests over the whole knowledge surface; multi-method paths). Item "/v1 workflow streaming" turned out already shipped (SSE has been the run default since the /v1 batch) — verified, no change.

17. ~~Quality batch (#97–102, 2026-08-01)~~ ✅: **hardening sweep** (trashed workflows refused by chatflow turns + sub-flux calls; fluxes-page version N+1 → one query; feedback question lookups batched; covering indexes on the hot listing paths); **`mix flux.demo`** (showcase workspace on the echo provider: triage flux, RAG chatflow over a seeded handbook, agent with drive, three apps + live site — end-to-end tested); **docs** (docs/guides: getting started, node reference, plugin SDK, service API — linked from README); **workspace import** (Flux.Import restores an export archive with per-entry warnings; upload form in settings; round-trip tested); **perf guard** (opt-in 10k-segment/1k-conversation suite; measured: hybrid retrieval 250ms Naive, monitor 15ms, usage rollup 29ms); **golden run recorder** (finished runs export as replay fixtures from run history; committed fixtures re-run on echo in CI, outputs + node-status set pinned).

18. ~~Polish batch (#103–110, 2026-08-01)~~ ✅: **Jinja templating** (`Flux.Engine.Jinja`, a dependency-free subset — {{ var|filter }} pipelines, if/elif/else, for with loop.*, comments; template nodes pick simple vs jinja per node); **doc template library** (`/console/templates`: workspace-scoped Jinja documents validated at save, live preview against a sample context, template nodes reference them through a host capability — deleting one fails the node honestly); **in-app docs viewer** (`/console/docs`: the four guides compiled into the release and rendered in the console); **OUTATIME polish** (themed empty states, 88-mph run spinner); **editor UX** (branch labels on non-default wires: case handles, error routes); **quality analytics** (monitor page: per-day replies/likes/dislikes/annotation hits with sentiment bars); **responsive console** (drawer sidebar below lg with a hamburger topbar; desktop unchanged); **i18n groundwork** (locale plug — ?locale= → session → Accept-Language — with a LiveView on_mount hook, auth/landing pages gettext-wrapped as the exemplar, POT/en PO catalogs, localization how-to in the getting-started guide).

19. ~~Docassemble batch (#113–119, 2026-08-02)~~ ✅: **DOCX render engine** (`Flux.Engine.Docx`: run-split tag repair, curly-quote straightening, {%p %}/{%tr %} block tags, whole-XML Jinja render with escaped interpolation — pure, :zip only); **Word doc templates** (.docx uploads validated + variables discovered at upload, test render downloads a filled copy); **document node** (22nd type: fills a template mid-run, outputs a tokenized `/files/:token` download URL working from console/sites/API); **interview scaffold** (one click on a docx template generates form → document → end); **interview definitions** (`Flux.Interviews`: reusable question sets, `/console/interviews` builder, single validate_answers path); **interview node** (23rd type: pauses presenting the question set as one form on console + sites + /v1 resume, 422 with per-question errors); **PDF output** (Flux.Pdf → Gotenberg via FLUX_PDF_URL, `documents` compose profile, fake-converter tested — live conversion Docker-blocked).

20. ~~Docassemble round 2 (#120–125, 2026-08-02)~~ ✅: **canonical templates** (content immutable after upload; revisions fork with parent_id lineage, metadata-only update, adopt = rebind draft nodes, doc_template.fork/rebind audited); **native docx extraction** (document_extractor reads Word files without Tika); **date/email/regex questions** (compile-checked patterns, custom hint messages); **run-output retention** (filled documents age out with the workspace window, storage object + row + token); **template usage view** (cards show binding fluxes/nodes); **interview progress** (Step X of Y stepper on console + sites); **chat reply attachments** (chatflow document-node files as download chips in console/site chat + /v1 messages files array, contract updated).

### Blocked — external unblocks required
| Item | Blocked on |
|---|---|
| ~~Push to GitHub~~ ✅ (2026-07-31: `canuckasaurus/fluxcapacitor`, folder renamed too — WS0 complete) | CI-green confirmation still needs `gh auth login` (token stale) |
| ~~flux-coderunner container~~ ✅ (2026-08-02: see batch 21) | — |
| ~~Tika office formats~~ ✅ (2026-08-02); ArangoDB backend remains | BUSL-1.1 decision, then implementation |
| Golden harness phase 2 — recorder + parity replay **authored 2026-08-02**; recording needs the Reference stack booted | permission to run the third-party compose stack (or user boots it) |
| Code node phase 2 hardening (network-namespace split) | phase 1 ✅ — buildable now |
| ArangoDB BUSL-1.1 license acceptability review | user/legal decision |
| Prod email adapter (magic links beyond the local mailbox) | choice of SMTP/API provider + credentials |
| bcrypt swap (currently pbkdf2) | Linux/CI build (no local C toolchain) |

21. ~~Docker batch (#126–130, 2026-08-02)~~ ✅ — Docker Desktop live (WSL2 installed):
**compose stack verified** (postgres on host port 5433, minio, gotenberg, tika all
healthy); **live PDF conversion** (Jinja-rendered docx → Gotenberg → real PDF; Tika
round-tripped the interpolated text back out); **Tika wiring** (`Flux.Tika` client,
document-extractor falls back for xlsx/pptx/.doc/PDF, FLUX_TIKA_URL all envs);
**flux-coderunner shipped** (stdlib-only HTTP service: uv-cached venvs for python
deps, permissionless Deno for JS, rlimits + throwaway dirs + process-group kill,
10/10 live sandbox checks incl. blocked network + memory bomb; CODE_RUNNER_URL now
selects the Sandbox backend); **full app image built & booted** (vendored deps
dodge WSL2 hex stalls, docs compiled in; release migrated the compose DB and
serves landing/login/v1); **harness phase 2 authored** (recorder script + parity
replay test, activates when traces land — Reference stack boot itself was blocked
by the session's permission layer).

22. ~~ML toolkit + AI flux drafting (#132-133, 2026-08-02)~~ ✅: **pre-installed ML
toolkit** (24 pinned libraries baked into the coderunner image — numpy/pandas/
polars/scipy, scikit-learn/xgboost/lightgbm/statsmodels, nltk/rapidfuzz/tiktoken,
matplotlib/pillow/opencv, bs4/lxml/openpyxl… — zero-install imports, reported at
GET /libraries; hardening fallout fixed en route: RLIMIT_DATA instead of
RLIMIT_AS so loaded libraries don't count against the cap, BLAS/OpenMP pools
pinned to 1, NPROC raised for the shared WSL2 kernel, libgomp/libglib added);
**AI flux drafting** (`Flux.Workflows.Copilot`: description → workspace default
model → graph JSON → `Engine.build` validation with one corrective retry →
draft; node catalog embedded from the node-reference guide, auto layout,
reference-lint warnings surfaced, "Draft with AI" in the New Flux flow; 7 tests
via injected fake model).

23. ~~LlamaIndex plugin + brand art + docs refresh (2026-08-02)~~ ✅: **LlamaIndex
tool plugin** (`llama_index` built-in: LlamaCloud managed-index `retrieve` with
per-call or default pipeline, llama_deploy `run_workflow` as an in-flux function,
`list_pipelines`; SSRF-guarded, bearer auth, validation falls back from the
pipelines route to the deployments route for self-hosted servers; 8 Req.Test
tests); **brand art placed** (AI-helper mascot → static assets + Draft-with-AI
card, FLUX ASSISTANT banner compressed 2.6MB→226KB → docs/images + getting
-started, docs viewer rewrites relative image paths so guides render on GitHub
and in-console alike); **docs refresh** (plugin-sdk LlamaIndex section, stale
code-node section rewritten for the coderunner + ML toolkit, getting-started
covers Draft with AI, README plugins bullet).

24. ~~The octet: cost, webhooks, fine-tune, batches, evals, datasources,
labeling, netns (#134-141, 2026-08-02)~~ DONE: **run usage + cost** (every
model call counted at the host invoke_llm boundary; per-model breakdown,
Flux.Pricing longest-prefix estimates with config override, dashboard rollup,
/v1 total_tokens); **outgoing webhooks** (workspace endpoints with event
filters, HMAC-signed via AlertWorker, settings card); **fine-tune JSONL**
(liked replies + annotations in OpenAI chat format, monitor download);
**batch runs** (CSV upload -> one run per row via Oban, live counters,
results CSV, dependency-free RFC-4180 codec in Flux.CSV); **evaluations**
(eval sets/cases from forms, CSV, or runs; exact/contains/LLM-judge graders;
draft-vs-version comparison; eval executions are ordinary runs with usage);
**Notion + S3 datasources** (integration-token page sync; S3-compatible
buckets over the ExAws/Req stack, UTF-8-only fetches); **Label Studio
connector** (compose sidecar on 8085, tool ops list_projects/create_tasks/
export_annotations, labeled tasks as a datasource, "Send to labeling" on
monitor feedback, Apache-2.0 -- the label->train->serve loop with the
coderunner ML toolkit); **coderunner phase 2** (python user code under
unshare in an empty netns; boot probe with loud fallback, custom seccomp
profile = Docker default + unprivileged unshare, live-verified: 12/12
checks incl. python network denial while uv installs stay networked).

25. ~~Batch 2: the loop closes (#142, 2026-08-02)~~ DONE: **train->serve**
(coderunner gains input files + ./artifacts output, both base64 over the
existing contract; Sandbox/Local mirror it; the code node stores artifacts
as run-output files and resolves attachment file ids workspace-scoped
before execution; editor attachments field; live-verified 14/14 incl. an
artifact round trip); **capture run as eval case** (evals page dropdown of
recent succeeded runs); **chat cost estimates** (app monitor prices tokens
against the bound model); **webhook events** batch.completed /
eval.completed / feedback.created; **Google Drive datasource** (service
account JWT-bearer, hand-rolled RS256 on :public_key, Docs->text,
Sheets->CSV, tests verify a real signature); **JS npm dependencies**
(deno cache outside the sandbox, import map + --cached-only inside,
exact versions). History scrub + stale-folder delete handed to the user
as ! commands (classifier-blocked).

26. ~~Native labeling replaces the sidecar (#143, 2026-08-02)~~ DONE: the
Label Studio sidecar (shipped in #140) is REMOVED on the user's call --
"integrated properly" beats a second auth/tenancy surface. **Native
labeling**: labeling_projects (choice/multi/text schemas) + labeling_tasks
under the tenancy guard; /console/labeling tagging GUI (one-task queue,
choice buttons / multi checkboxes / free-text with answer prefill, skip,
relabel from the labeled list, live counts); intake from monitor feedback
("Label in <project>" per rated reply), CSV rows, or add_task; labeled
sets export as JSONL for training code nodes -- label->train->serve with
zero external services. Also: **batch runs target published versions**
(graph snapshot per target, badge in the list) and **evals pick a judge
model** ("plugin|model" per pass, workspace default otherwise, via the
new Workflows.invoke_model_for_workspace). LS plugin/compose/bridge
deleted; plugin count back to 9.

27. ~~Batch 3: the quality loop, wall to wall (#144, 2026-08-02)~~ DONE —
all twelve: **labeling node** (24th node type: queues a task and pauses
the run; the submitted label resumes it as choice/choices/text outputs —
human review as a graph step, reusing the pause/resume machinery via a
queue_label_task host capability); **batch → labeling** ("To labeling" on
completed batches fans succeeded rows into a project); **labeling UX**
(keyboard shortcuts 1-9/s via a colocated hook, per-labeler stat badges);
**multi-labeler claims** (soft 10-minute claims on next_task so parallel
labelers don't collide); **demo loop** (mix flux.demo seeds a Ticket
intent project — 5 labeled BTTF-flavored examples + 2 to tag — and the
Model trainer flux); **eval regression gates** (gate flag per set; publish
runs gated sets and blocks on regression; score-delta badges + webhook
previous_avg_score/regressed); **workspace runs page** (/console/runs:
filter by flux/source/status, token + est-cost totals); **template
gallery** (triage / RAG answer / human review / model trainer cards on
the fluxes page, engine-validated graphs with layout); **artifact picker**
(code-node attachments pick from recent runs' output files); **/v1
quality API** (batches, eval sets/runs, labeling projects/tasks/next/
label/export — CI can drive the whole loop; ServiceAuth editor scope
reused); **console i18n increment** (sidebar + dashboard gettext-wrapped;
French catalog fully translated and shipped — /console?locale=fr —
Locale on_mount added to the console live_session); **perf suite** (new
quality_load_test: 5k runs / 5k tasks seeded, real 200-row batch + 100-
case eval on echo; measured: runs page 11ms, batch 16.2s, eval 6.3s,
labeling next 6ms).

28. ~~Batch 4: quality hardening + the file-output node (#145, 2026-08-02)~~
DONE: **file_output node** (25th node type, user-requested: templated
content → downloadable HTML / PDF / Markdown / text / CSV / JSON run
file; HTML/PDF auto-wrap into a styled page, PDF rides Gotenberg's
chromium route via new Flux.Pdf.convert_html, content types per
extension, engine + core + editor panel + golden fixture);
**/v1 quality contract** (9 new OpenAPI schemas + 10 paths incl. 202/201
statuses; quality errors now carry the shared Error shape; contract test
walks batch → eval → labeling end to end); **inter-labeler consensus**
(projects take required_labels 1-5; labeling_task_votes under the
tenancy guard; one vote per account, repeat votes replace, majority
label at quorum with earliest-vote tie-break; next_task never re-serves
a task you voted on; agreement_stats = avg share of votes matching the
final label + unanimity, badges in the console header);
**labeling webhooks** (labeling.task_labeled + labeling.project_completed
on the signed pipeline); **scheduled evals** (cron expression per set —
Oban's parser — swept on the minute tick against the latest published
version, once-per-minute suppression, schedule form on the evals page,
schedule in /v1 eval-sets); **runs drill-in** (click a row on
/console/runs → inputs/outputs/error + per-node trace table, no editor
required); **i18n increment** (Apps/Fluxes/Knowledge/Docs/Doc templates/
Tools/Runs/Audit/Plugins/Workspace settings headings wrapped; fr catalog
extended, still fully translated); **2 new gallery templates** (report
writer — showcases file_output; intent router — classifier fan-out,
6 total); **golden fixture** for file_output (deterministic outputs
only); **full image rebuilt & booted** (migrations applied, landing 200).
Mid-batch a PowerShell array-flattening bug replaced every `<` with `h`
in six LiveView files — caught immediately, restored from git, edits
re-applied with the Edit tool; scripted multi-file source edits are
retired.

29. ~~Batch 5: labeler trust, recurring batches, files, quality panel
(#146, 2026-08-02)~~ DONE: **gold-standard QC** (labeled tasks promote
to honeypots — the label becomes gold_label, the task re-enters the
queue, votes/labels score per-labeler accuracy shown as ★ badges;
consensus projects score every vote, single-label projects the applied
label); **scheduled batches** (batch_schedules table + Repeat button on
completed batches: the row set re-runs on a cron against draft or the
pinned version, pause/resume/delete, minute-tick sweep with last_run_at
suppression); **/console/files** (workspace file browser: run outputs,
artifacts, uploads, tokenized downloads — sidebar Operate section);
**dashboard Quality panel** (Usage.quality_summary: gate/schedule
counts, last 5 eval scores, labeling queue depth, avg agreement);
**regex grader + case weights** (weights scale avg_score; `weight` CSV
column handled at import; invalid patterns fail cases honestly);
**file_output chat chips** (already worked by output-shape matching —
now pinned by a chatflow test); **Edit with AI** (Copilot.revise sends
the current graph + instruction, validated like a draft, applied as one
undoable edit via a toolbar modal); **i18n** (5 more page headings +
**Spanish catalog fully translated** — /console?locale=es; the fuzzy
"Files"→"Fluxes" mistranslation caught and fixed); **2 golden fixtures**
(classifier routing on echo's text-match fallback; llm → file_output —
echo's streamed trailing space pinned in expectations).

30. ~~Batch 6: RAG backends, registry, notifications, approvals, ops
(#147, 2026-08-02)~~ DONE — ArangoDB BUSL-1.1 accepted by the user, so
both graph items shipped: **pgvector backend** (guarded migration adds
embedding_vec when the extension exists; FLUX_VECTOR_BACKEND=pgvector
ranks cosine in SQL; compose Postgres now pgvector/pgvector:pg16 — the
alpine→debian volume carried over, extension 0.8.6 live-verified);
**ArangoDB entity graph** (Flux.RAG.ArangoGraph: lazy database/collection
setup, NDJSON bulk import of co-occurrence vertices/edges, 1..2-hop
weighted AQL traversal; related_entities prefers it and falls back to
SQL; live-verified against arangodb 3.12.9 — found a depth-2 neighbor
SQL can't see); **markdown-aware chunking** (per-dataset toggle, chunks
carry their headings); **model registry** (model_artifacts: name +
auto-incrementing version over stored files, register from the Files
page, ★ entries lead the editor's attachment picker); **version
comparison matrix** (latest score per set × target on the evals page,
best cell highlighted); **in-console notifications** (workspace feed +
sidebar unread badge; emitted on run failure, eval regression, labeling
completion, export ready); **agent tool approval** (approval_tools on
the agent node; flagged calls pause the run — a new rerun resume mode
re-enters the agent loop; approve executes, deny feeds the model a
refusal; Approve/Deny buttons in the run panel); **cost surface**
(Usage.flux_costs + card on /console/runs + CSV download);
**pagination + date filters** (runs & files Load more; from/to date
range); **scheduled workspace exports** (cron in workspace settings →
archive stored with a download token, appears on Files, export_ready
notification); **/v1 SSE for batches and evals** (:id/events endpoints
streaming progress frames, contract-consistent payloads).

31. ~~Batch 7: cost controls, measurable retrieval, serve-by-name
(#148, 2026-08-03)~~ DONE: **registry-by-name serving** (code-node
attachments accept registry:<name> — resolved to the LATEST registered
version at run time, so promoting a model updates every serving flux;
the picker offers ★ latest entries for space-free names, pinned ids
otherwise); **retrieval evals** (retrieval_cases per dataset:
question → expected-passage golden cases scored on hit rate + MRR from
the knowledge page — chunking/backend changes become measurable);
**LLM response cache** (ETS via Flux.LLMCache at the invoke_llm
boundary; workspace TTL setting; hits replay content as one chunk and
bill zero tokens); **monthly token budgets** (workspace setting; 80%
warning notification once per month, runs refuse with
:budget_exhausted past the cap; Usage.month_tokens counts runs + chat);
**version diff** (Workflows.diff_graphs — nodes added/removed/changed
with touched config keys, position moves ignored, edges by
source/handle/target — rendered in the versions modal per version);
**one-click re-run** (runs drill-in button re-runs with the same inputs
against the current draft); **pgvector HNSW** (FLUX_VECTOR_DIMS types
the column and builds the index at boot, best-effort);
**Arango vector backend** (FLUX_VECTOR_BACKEND=arango: embeddings
mirror into a segments collection, COSINE_SIMILARITY ranking in AQL —
live-verified ordering + drop against arangodb 3.12.9).

32. ~~Batch 8: operate and measure (#149, 2026-08-03)~~ DONE:
**/v1 parity for the quality tooling** (GET/POST /v1/models,
GET /v1/notifications, GET/POST /v1/datasets/:id/retrieval-cases,
POST .../retrieval-eval — six routes, six strict OpenAPI schemas,
contract-tested end to end); **timeline waterfall** (per-node duration
bars in the runs drill-in, scaled to the slowest node, failure bars in
red); **query expansion** (per-dataset toggle: the workspace model
rephrases each query, every variant contributes rankings to the RRF
fusion; injectable expander for tests, best-effort in production);
**webhook delivery log** (webhook_deliveries rows per dispatch,
AlertWorker records status/attempts/error per attempt, settings shows
the log with manual retry); **A/B version routing** (ab_version_b +
ab_split on workflows; serving_version routes chatflow/site/trigger/API
traffic — split% to B, rest to latest — with per-arm run/success/token
stats in the versions modal); **instance admin panel**
(FLUX_ADMIN_EMAILS → /console/admin: every workspace with plan
selector, members, 30-day volume; set_plan_for_workspace);
**retrieval bench** (perf-suite: 10k embedded segments, same query
against Naive/PgVector/Arango — backends auto-skip where absent; naive
measured at 97ms locally).

33. ~~Batch 9: the everyday-team batch (#150, 2026-08-03)~~ DONE:
**export completeness** (workspace archives carry eval sets + weighted
cases + gate/schedule flags, labeling projects with tasks/labels/gold
standards restored via quiet direct inserts, retrieval cases, and the
markdown/expansion dataset settings; import counts + settings flash
report them; round-trip tested); **custom template gallery**
(workflow_templates: Save-as-template on any flux, ★ cards next to the
built-ins, delete, create-from); **document tags** (per-document tags on
the Knowledge page; knowledge node `tags` config — templatable — filters
retrieval via array-overlap on the document join; RAG.retrieve/
retrieve_many take :tags); **concurrent-run cap** (max_concurrent_runs
workspace setting; interactive runs refuse with :concurrency_limit,
batch/eval sources exempt); **notification routing** (every notify also
dispatches notification.<kind> — endpoints subscribe per kind, event
vocabulary extends automatically); **topic clusters** (deterministic
Jaccard clustering of recent user questions on the app monitor — no
model calls, provider-agnostic); **canvas sticky notes** (graph-stored
notes list, rendered as draggable warning-tinted cards reusing the
node-drag hook via note: id prefixes; add/edit/delete all undoable
through the normal graph history).

34. ~~Batch 10: hardening (#151, 2026-08-03)~~ DONE: **per-node token
attribution** (the engine stamps the executing node id in the process
dictionary — branch-safe, each parallel task owns its own — and the
invoke_llm wrapper accumulates usage["by_node"] alongside by_model;
the runs waterfall shows tokens per node); **guardrails**
(Flux.Guardrails: newline-separated case-insensitive regexes in
settings, action block|flag; inputs gate chat + runs — chat UIs flash,
/v1 answers 403 guardrail — outputs always flag; every match raises a
routable guardrail notification; invalid patterns refused at save);
**run text search** (ILIKE over inputs/outputs ::text with a debounced
search box); **cleanup sweeps** (notifications >90d and webhook
deliveries >30d age out nightly for everyone); **trash parity**
(datasets + labeling projects soft-delete with 30-day purge — dataset
purge drops the vector index via a runtime-resolved backend to keep
flux free of flux_rag compile deps — restore UIs on both pages;
labeling queue_from_run refuses trashed projects); **weekly digest**
(Monday 08:00 UTC minute-tick: workspaces with 7-day run activity get
one digest notification with runs/failures/tokens/cost; ISO-week marker
prevents repeats); bulk re-index turned out already shipped (dataset
settings card) — verified rather than duplicated, my redundant copy
removed before commit.

35. ~~Batch 11: providers, polish, and the first live QA pass (#152, 2026-08-03)~~
DONE: **Azure OpenAI provider** (per-deployment routing with api-key
auth and api-version query; delegates the chat-completions wire
protocol to the OpenAI plugin; GA api-versions omit stream_options, so
missing usage falls back to a bytes/4 estimate; optional embedding
deployments) and **Amazon Bedrock provider** (Claude through the
runtime invoke endpoint with the anthropic bedrock-2023-05-31 payload;
SigV4 signed by hand — ExAws has no Bedrock module — session-token
aware, non-streaming reply emitted as one chunk, anthropic.* ids only,
honest errors otherwise); **chat markdown** (FluxWeb.Markdown: an
escape-first renderer — headings, lists, quotes, fences, inline
code/bold/italic, http(s)-only links; raw HTML can never pass — used
for assistant bubbles in console chat and public sites); **regenerate**
(Chat.regenerate discards the last completed reply and streams a fresh
one from the same user message; button on the last assistant bubble);
**sub-flux version pinning** (iteration/loop accept subflux_version
"v3"/3; the runner resolves that exact version or fails with an honest
"does not exist"; blank = latest as before; pin inputs in both editor
panels); **onboarding checklist** (Flux.Usage.onboarding: provider
beyond echo, first flux, publish, dataset, first run/reply, invite —
dashboard card with progress bar, struck-through done steps, links on
the pending ones; hides itself when complete); **demo refresh**
(mix flux.demo now seeds the quality loop too: a gated eval set with
routing cases, retrieval goldens, flag-mode guardrails, a v2 refund
desk behind a 50% A/B split, a canvas note, a workspace template, and
a registered ticket-intent model artifact); **v0.1.0** (CHANGELOG.md
distilled from this ledger; umbrella already versioned 0.1.0; tag
v0.1.0 on main — the GitHub release draft still waits on gh auth);
and a **live QA sweep** — the first time this console was actually
clicked through end to end (dev server + browser automation): caught
and fixed a real editor bug (the canvas drag hook preventDefault-ed
pointerdown on note textareas, making notes impossible to type into —
interactive elements now win over dragging), chat bubbles bloated by
HEEx indentation rendered under whitespace-pre-wrap (pre-wrap now
scoped to content spans in console chat, site chat, and streaming
bubbles), a missing empty state on Knowledge (OUTATIME plate added),
and a11y labels on the note-delete and regenerate icon buttons.
Verified live along the way: template gallery → canvas → keyboard
delete → publish → run (echo fallback, per-node waterfall tokens),
markdown + regenerate in a real conversation, dark mode, and the
checklist advancing 0/6 → 3/6. Lesson repeated: data-confirm dialogs
freeze browser automation — the node Delete button is confirm-guarded,
the Del key path is not.

36. ~~Batch 12: console hardening out of the QA sweep (#153, 2026-08-07)~~
DONE: **console conversation history** (Chat.console_conversations —
end_user_ref-nil threads, newest first; the app chat mounts resumed on
the latest conversation with a switcher select, exactly the courtesy
sites already paid visitors); **streaming markdown** (the streaming
bubble renders FluxWeb.Markdown per chunk, so replies format as they
arrive instead of snapping at the end); **themed confirm modals** (a
capture-phase click interceptor in app.js swaps every [data-confirm]
native window.confirm for a DaisyUI <dialog> — on OK the attribute is
lifted for one synchronous re-click so neither phoenix_html nor
LiveView re-confirms; keyboard/backdrop cancel; kills the batch-11
automation freezer for good); **QA regression tests** (markdown +
tight-bubble markup, conversation resume/switch, Knowledge OUTATIME
empty state, API-reference render, palette JSON — the sweep's findings
can't quietly return); **in-console API reference**
(/console/docs/api-reference generated from the live OpenAPI spec via
a JSON round-trip — endpoints table with method/path/summary/response
links, per-schema field tables with types and required badges, cached
in persistent_term — it can never drift from GET /v1/spec); **command
palette** (Ctrl/Cmd+K dialog fed by GET /console/palette — pages plus
fluxes/apps/datasets/labeling projects/doc templates — client-side
filtering, arrow/enter navigation; the fetch sends no accept header
because the :browser pipeline negotiates html only, found live);
**responsive console** (the drawer layout already existed —
lg:drawer-open with a hamburger header — verified off-canvas behavior
at narrow widths rather than rebuilt); and **metrics profile**
(compose prometheus + grafana with a provisioned datasource and a
hand-authored 8-panel FluxCapacitor dashboard — HTTP rate/latency,
run counts/duration, Ecto p95, Oban queues, BEAM memory/processes —
against verified PromEx metric names; found live that prod force_ssl
301-bounced the in-network scrape of http://app:4000/metrics to
https, so "app" joined the exclude hosts). Verification was
DOM-behavioral this round (the browser window sat minimized at 0x0 —
screenshots impossible): palette open/fetch, confirm-intercept
before/after semantics, drawer state, API reference content all
asserted via injected JS against the dev server.

37. ~~Batch 13: the chat experience finished + shop-window refresh (#154, 2026-08-07)~~
DONE: **image uploads in chat** (LiveView allow_upload on console chat
and public sites — paperclip, entry chips with cancel, 3×15MB images;
consume → Chat.create_upload → send_message files:, riding the
load_images vision path that only the API could reach before; user
bubbles show attachment chips); **conversation management** (rename
pencil → inline form, themed-confirm delete that falls back to the
next thread — both console-side over the pre-existing context
functions); **chat polish** (a Copy button on every completed reply —
delegated JS writing the bubble's rendered text to the clipboard —
and opt-in **follow-up suggestion chips**: apps.suggest_followups
migration + checkbox, Chat.follow_up_suggestions makes one extra
model call over the last six turns — the app's model or the workspace
default — parses up to three lines, chips send on click; wired into
console and site after every finished reply); **token/cost metrics**
(the run-finished telemetry now carries input/output tokens and cost
in micro-USD; PromEx sums by source and two new Grafana panels chart
tokens/h and estimated USD/h); **curl examples** (every endpoint row
in the API reference grew a details-toggled, copy-pasteable curl —
canned bodies for the well-known POSTs, generic elsewhere);
**run comparison** (pick any two runs on the Runs page via a
stop-propagation checkbox column → side-by-side status/version/IO
panels plus a per-node table aligned on the union of node ids in
first-appearance order); **canvas align/distribute** (a join-toolbar
appears at 2+ selected nodes: align left/top, distribute h/v keeping
the outermost pair — position math server-side through update_graph,
so it's undoable like any other edit); **URL crawl** (RAG.crawl_from_url:
depth-1 same-host links from the fetched page — fragments stripped,
offsite and self dropped, 25-page hard cap — each page SSRF-checked
and ingested individually, failures skip not abort; "crawl links"
checkbox on the knowledge URL form); and the **shop windows**: the
landing page's four stale feature cards became eight that actually
describe the platform (creator, apps/sites, knowledge, quality loop,
operations, observability, plugins, enterprise), and the README picked
up uploads/follow-ups/copy, comparison, crawl, align, curl, and the
token/cost panels. Note for the ledger's conscience: API token hygiene
has now been passed over eight times.

38. ~~Batch 14, the twenty-item mega-batch (#155, 2026-08-07)~~ DONE:
**API token hygiene, at last** (expires_at on api_tokens — NULL is a
first-class perpetual choice, per the user; create forms offer
never/30/90/365 days on both app keys and flux keys; tables show
expiry + last-used badges; expired tokens answer 401 token_expired on
/v1 while perpetual ones outlive time itself); **node replay**
(Workflows.replay_run: a finished run re-executes from any node in a
NEW run — recorded outputs seed the pool for everything outside the
target's descendant set, the engine's rerun-resume path does the rest;
per-node replay buttons in the runs drill-in; chatflow sys context is
honestly not reconstructed); **batch retry** (retry_failed_rows maps
failed runs back to their rows by order and starts a "(retry)" batch
against the same target); **remembered URL sources** (dataset_url_sources
table + "re-fetch nightly" checkbox — the 03:00 UTC tick re-fetches
each source through a synthetic editor scope, and URL ingestion now
replaces same-named documents instead of duplicating); **published-site
meta** (root layout renders page_meta description/OG/favicon; app
sites fill it from theme + description so shared links unfurl);
**palette verbs** (workspace-switch entries POST through a CSRF'd
form the palette JS builds); **flux health badges** (7-day
runs/success/tokens per flux via one grouped query, warning-tinted
when anything failed); **German** (full de catalog hand-translated,
picked up automatically by Gettext.known_locales — and de-DE promptly
broke the locale fallback test exactly like es did in batch 3;
pt-BR is the new "unknown"); **PDF/Office uploads** (knowledge accepts
pdf/docx/doc/xlsx/pptx; Flux.Documents.extract_binary reuses the
native-or-Tika pipeline; per-file failures flash instead of aborting);
**prompt library** (prompt_snippets table, Flux.Prompts upsert-by-name,
a Tools-page card, and an insert picker on the LLM panel that copies
the snippet into the system prompt at insert time — no dangling
references); **per-node output caching** (nodes opting in via
cache_minutes memoize outputs+branch through a new host node_cache
capability riding the LLMCache ETS, keyed on config + pool minus sys —
conservative by design; cache input on the http_request panel;
node_cache_hit event emitted); **canvas presence** (Phoenix.Presence
child; the editor tracks per-canvas and renders avatar chips when 2+
people share a graph); **provider health** (ETS call/error counters
recorded at both LLM invoke sites, per-provider table with error rate
on the admin panel — in-memory since boot, honestly labeled);
**runs JSONL export** (runs-export streams 500 runs with full
per-node traces); **dashboard activity feed** (Audit.list distilled to
a card) and **live cards** (30s interval refresh while open);
**conversation search** (titles OR message bodies via ILIKE subquery,
debounced box beside the switcher). Two items turned out to already
exist and were verified, not rebuilt: **OpenAPI tool import** IS
Flux.Tools (spec to operations with encrypted auth, since the tools
epic) and the **segment browser** (list/edit/re-embed/enable-disable
with retrieval honoring the flag) shipped with the knowledge epic.
QA round 2 ran DOM-behavioral against the dev server (window still
0x0): activity feed, prompt library, compare + JSONL, flux health
badges, and conversation search all verified in rendered HTML; the
admin health card hides behind FLUX_ADMIN_EMAILS as designed. The
demo now enables follow-ups on Support Echo and seeds a bttf-tone
snippet. 720 tests.

39. ~~Batch 15, the closing ten (#156, 2026-08-07)~~ DONE: **health
probes** (GET /health liveness + /health/ready readiness with
database/storage checks and 503-with-detail; probe with Host:
localhost past prod force_ssl); **mix flux.doctor** (Flux.Doctor runs
one check per configured service — database, storage, Oban, Tika,
Gotenberg, coderunner, vector backend, metrics — optional services
report skipped, never failure; the task exits non-zero on FAIL for
deploy scripts; verified live: all systems go); **webhook test
button** (Webhooks.send_test posts a signed webhook.test event
synchronously and flashes the HTTP status — receiver debugging
without waiting for a real run); **notification filters** (kind
chips, per-item mark-read, explicit Mark-all — the page no longer
force-reads everything on open); **cron previews**
(FluxWeb.CronPreview scans minute-by-minute through Oban's own parser
so the preview can never disagree with the scheduler; "next … UTC"
badges on batch schedules and schedule triggers — a HEEx lesson
retaught: bindings inside `x && (y = …)` don't leak, top-level
`y = x && …` does); **eval results CSV** (per-case download on every
completed eval run); **flux-site meta** (published flux sites carry
the same OG/meta/favicon treatment app sites got in batch 14);
**rate-limit headers** (x-ratelimit-limit/-remaining on every allowed
and denied /v1 response, Retry-After on 429s); **operations guide**
(docs/guides/operations.md — cost controls, guardrails, probes,
doctor, metrics, backups, and a table of everything scheduled —
registered in the console docs); and **v0.2.0** (umbrella + apps
bumped, CHANGELOG section distilled from entries 35–38, tag pushed).
Postscript: the readiness probe paid for itself within minutes of
boot — /health/ready reported storage unreachable in the compose
stack, and mc confirmed the flux bucket had NEVER existed: S3-backed
uploads in the container had been silently broken since the stack was
born, undetected because every prior live verification exercised pages
and runs, not file writes. The S3 adapter now self-provisions the
bucket on first write (create + retry on 404). v0.2.0 was re-tagged to
include the fix — it was minutes old and part of this same batch.

**40. Batch 16 — the hardening ten (all ten picked).** Static
analysis (sobelow can't fingerprint on Windows — Path.absname crash —
so it ran in a Linux hexpm/elixir container against the mounted repo;
one real finding fixed: the plugin endpoint controller now allowlists
response content-types instead of echoing whatever the plugin claims;
the Plug.Upload traversal flag is annotated as a false positive;
credo --only warning,consistency and deps.audit joined the precommit
alias); **SMTP delivery** (gen_smtp adapter behind FLUX_SMTP_HOST/
PORT/USERNAME/PASSWORD/SSL with FLUX_MAIL_FROM feeding the notifier —
production email is off the blocked list; a runtime.exs lesson: the
HEEx binding rule applies to plain Elixir too, `cond and (x = ...)`
doesn't leak into the block); **backup restore drill** (live
export→import round trip through bin/flux rpc in the running
container: seeded content, exported the archive, imported into a
fresh workspace, counts and contents matched, drill artifacts cleaned
up; restore runbook now in the operations guide. The drill earned its
keep twice: the demo seeder's inline indexing had crashed on a
cold-start race — fine on retry — and the retrieval verification hit
a REAL production bug: pgvector search crashed in the release because
Postgrex can't bind a `vector`-typed parameter; `$1::vector` became
`$1::text::vector` and the fixed SQL verified against the live
container. Prod-only code paths stay broken until something walks
them — the MinIO bucket lesson, retaught by retrieval); **workspace
API keys** (ws- prefixed tokens bound to the workspace alone — the
binding check constraint now allows app-less flux-less rows, dropped
by migration with a data-safe down; same perpetual/expiring lifetimes
as every other kind, minted and revoked on a new settings card,
resolved by ServiceAuth with the same 401 token_expired honesty);
**session management** (account settings lists every session token
with its signed-in date, marks the current device, revokes single
sessions, and logs out everywhere — which also ends the current
session and redirects to login); **duplicate** (one-click copies of
fluxes — draft graph included, editor opens on the copy — and apps —
full configuration, publish state reset, new site token); 
**conversation export** (any conversation downloads as Markdown or
JSON from the chat header); **audit export + filter** (from/to date
window on the audit page, CSV download honoring the same window,
metadata quoted RFC-4180 style); **perf round 2** (50 concurrent
chat sessions stream to completion in ~350ms wall — ~6ms amortized —
and a 100-row batch sustains ~13.5 rows/s through the full engine
path; numbers recorded in the operations guide beside the round-1
corpus baselines); and **dialyzer** (mix + ex_unit in the PLT, the
one over-narrowed engine pattern documented in .dialyzer_ignore.exs,
and the fresh warnings it surfaced all fixed for real: a dead
String.slice fallback in the chunker, a dead Cachex 3-tuple clause in
crypto, a covered format_number clause in the utility plugin, and
missing t() types on the three schemas Scope references). 93 flux +
50 targeted web tests green along the way; full suite, format, and
image rebuild close the batch.

**41. Batch 17 — expansion ten, honestly reconciled.** The proposal
listed ten items; recon showed three already shipped in earlier batches
(email invitations with magic-link acceptance, the embeddable
iframe/floating-bubble widget with /embed.js, and signed inbound
webhook triggers) and three more existed at the engine layer needing
round-outs. What actually got built: **MCP consumption** (Flux.MCP —
mcp_servers table, per-workspace encrypted auth headers, a minimal
Streamable-HTTP JSON-RPC client speaking initialize/initialized/
tools-list/tools-call with session echo and SSE-framed response
parsing; registered servers surface in the tool picker as
"Name (MCP)" toolsets and tool/agent nodes call them through the same
invoke path as OpenAPI toolsets — gated by the mcp_manage permission
that had been waiting in RBAC); **MCP serving** (POST /mcp: a
workspace ws- key names the workspace, every published flux is
advertised as a tool with an input schema derived from its start
variables — slug names, id-suffixed on collision — and tools/call
executes synchronously through a new Workflows.run_published_sync that
shares the normal run lifecycle: budget, guardrails, usage, webhooks);
**parent-child chunking** (dataset toggle; children at a quarter of
chunk_size embed for precision, each remembering its parent section;
retrieval promotes hits to the parent and dedupes by section, so the
model sees context, not fragments; round-trips through workspace
export); **structured-output validation** (Flux.Engine.SchemaCheck —
type/required/properties/items/enum with path-qualified errors; an
invalid respond call gets exactly one corrective retry with the errors
quoted back, usage summed across both calls, then fails honestly);
**app-level model fallback** (chat apps name a backup provider/model —
one retry on primary error, provider health recording both sides,
fallback_used/model_used stamped on the reply's usage, copied by
duplicate_app); **conversation-variable inspector** (the console chat
reloads the conversation after each turn and shows chatflow-written
variables in a details block); and the **background jobs panel**
(Flux.Jobs over Oban's own tables: queue depths by state, retryable/
discarded jobs with their last error, retry and cancel wired to
Oban.retry_job/cancel_job, admin-gated). Three migrations (apps
fallback columns, dataset/segment parent-child, mcp_servers). The
lesson written down: propose from the codebase, not from memory — the
batch's first hour was spent discovering a third of it already
existed.

**42. Batch 18 — the conversational round-out, and v0.3.0.** Eight
picks (custom domains and Japanese deferred): **OpenAI compatibility**
(POST /v1/chat/completions on app- tokens speaks the OpenAI wire
format both blocking and streaming — chunk frames, [DONE] sentinel,
usage object; stateless by design with the request's model field
ignored, the app deciding model and fallback; quota, guardrails, and
moderation all gate it — any OpenAI SDK now reaches an app with a
base-URL swap. /v1/models stayed the registry's — the compat surface
is completions-only and documented as such); **model-backed
moderation** (a policy textarea beside the regex guardrails; the
workspace default model answers ALLOW or DENY-with-reason, block
refuses inputs, flag and all outputs notify only, judge failures
allow — the product never goes down because the moderator did;
:moderation_judge injection keeps tests deterministic); **agent
multi-toolset** (agent_toolset_ids replaces the single id — multi-
select with a hidden-input clear trick, snapshots union across
toolsets with colliding names suffixed, old single-id graphs read
compatibly; the engine needed nothing: it always routed per-tool);
**rolling conversation memory** (past a 6k-token budget the oldest
turns summarize into the conversation row — incremental via
summarized_seq, reused without re-summarizing, degrading to full
history if the summarizer errors; the summary rides as a second
system message); **voice** (an optional invoke_transcription
capability on the provider behaviour, Whisper-shaped multipart in the
OpenAI and OpenAI-compatible plugins, hand-rolled boundary — no new
deps; push-to-talk MicRecorder hook uploads through LiveView's own
file pipeline and the transcript lands in the input box; read-aloud
uses the browser's speechSynthesis, zero provider involvement, on
console and site alike); **MCP phase 2** (prompts/list+get serve the
prompt library, resources/list+read serve dataset documents under
flux:// URIs — the /mcp endpoint now advertises all three
capabilities); **notification emails** (per-account kind opt-in on
account settings, fan-out inside Notifications.notify to subscribed
workspace members through the SMTP relay, unknown kinds dropped at
save; PHX_HOST builds the console links); and **v0.3.0** (umbrella
and apps bumped, CHANGELOG distilled from entries 40–42, tagged, image
rebuilt). One migration pair (conversation summary columns, account
email-kinds column). The runtime.exs binding lesson from batch 16 was
nearly repeated and caught in review — `and (x = ...)` still doesn't
leak.

**43. Batch 19 — the leverage eight (custom domains and Japanese
deferred again).** One item dissolved on contact: version restore
already shipped inside the editor (restore_version routes through
update_graph, so undo brings the old draft back) — the pre-proposal
grep checked the context module, not the LiveView; the codebase-first
rule now means grepping BOTH layers. What got built: **chatflow
OpenAI bridging** (advanced_chat apps stopped 400ing on
/v1/chat/completions — the bound flux's serving version runs with the
last user message as query and prior turns as {{sys.history}},
streaming node chunks as OpenAI frames; model reads "flux/<name>");
**provider TTS** (an invoke_speech capability — OpenAI /audio/speech
shape in the OpenAI and compatible plugins — with the console Listen
button preferring real model voices and push-eventing base64 audio;
browser speechSynthesis stays as the fallback and the public-site
default); **workspace price overrides** (Settings → Cost controls
takes "model-prefix $in $out" lines; longest-prefix match beats the
built-in table, flows through run rollups via cost_for/2 with the
run's workspace, and finally prices self-hosted models above $0);
**replace-by-re-upload** (add_document grew a replace: option — the
console upload path swaps same-named documents in place, URL-source
refresh now shares the same code path, pasted text keeps append
semantics); **per-app rate limits** (a rate_limit_per_minute column
consulted by the RateLimit plug when the service principal is an app —
the x-ratelimit-limit header honestly reports the override);
**per-flux budgets** (monthly_token_budget on workflows, gated in
start_run and run_published_sync beside the workspace budget,
80%-once-per-month warning tracked via budget_warned_month, distinct
:flux_budget_exhausted refusal, set from the editor's API panel); and
**Prometheus alert rules** (ops/alerts.yml — app down, 5xx ratio, run
failures, Oban backlog, BEAM memory — mounted into the compose
Prometheus via rule_files, with every metric name verified against
the live /metrics scrape rather than guessed; the first draft's
guessed names lasted four minutes). One migration (two workflow
columns, one app column).

**44. Batch 20 — the mega eighteen (everything but custom domains and
Japanese).** One dissolved on contact again: public-site flood
protection already existed (FluxWeb.SiteRateLimit, per-site and
per-visitor buckets inside the LiveView — the both-layers grep rule
now includes "protection that lives beside the feature, not in the
router"). Built: **model playground** (/console/playground races one
prompt across ≤4 models in parallel tasks — reply, latency, tokens,
cost per column, one click to workspace default); **image documents**
(knowledge uploads accept images; describe_image_for_workspace runs
the workspace vision model with a transcribe-then-describe prompt and
the description indexes like text); **document metadata** (typed
key-values, JSONB-containment retrieval filter, template-capable
metadata_filter on the knowledge node, editor beside tags); **flux
over dataset** (every document becomes a batch row — query/content/
name — one button from the dataset panel to the Batches page);
**human handoff** ("Talk to a human" on sites flags the conversation,
notifies as a new handoff kind, queues on the monitor page; a console
reply inserts a human-marked assistant message and broadcasts on a
new conversation topic the site subscribes to — the loop closes live);
**conversation labels** (chips + monitor filter, comma-edited);
**Ollama provider** (auto-discovering /api/tags, chat over the
OpenAI-compatible /v1 surface — SSRF note: local hosts need
FLUX_SSRF_ALLOW in prod); **guardrail redact** (third action beside
block/flag: sanitize_input masks stored chat messages and the model's
view, finalize masks replies, maybe_redact_inputs masks run input
strings — notify-always, refuse-never); **shareable run traces**
(Phoenix.Token-signed /share/runs/:token, 30-day expiry, dead-view
read-only trace — zero migrations); **canvas SVG export**
(server-rendered boxes and arrows from graph coordinates; the ~s()
paren-nesting sigil trap from batch 12 struck again and lasted one
compile); **Slack webhooks** (a format column; the AlertWorker wraps
payload scalars in Block Kit when "slack"); **workspace archive** (the
dormant archived status surfaced: owner archives from the danger
zone, resolution skips archived workspaces, instance admins restore);
**cache observability** (hit/miss/entry counters in the cache ETS
table, hit-rate line on the cost card); **status page** (public
/status + /status/json from the doctor checks with an admin-editable
incident note in a new instance_settings table; per the user's
uptime-kuma suggestion an optional --profile uptime ships Kuma
pointed at the health probes — native page first, sidecar optional);
**monthly cost report** (1st-of-month 08:00 tick beside the weekly
digest; a new cost_report notification kind rides the batch-18 email
fan-out for free); **API reference completeness** (ChatCompletion
schema + /chat/completions in the OpenAPI spec, ws- tokens, /mcp and
webhook triggers named in the spec description); and **monitor CSVs**
(feedback-with-questions and 90-day daily usage). One migration
(labels/handoff on conversations, metadata on documents, format on
webhook endpoints, instance_settings).

**45. Batch 21 — the leverage seven (custom domains, Japanese, and
SAML left on the table).** **Chatflow rolling memory** (the
{{sys.history}} text now folds through the same summary machinery
direct-model apps got in v0.3.0 — summarize falls back to the
workspace default model since chatflows bind no provider);
**OpenAI-compatible embeddings** (POST /v1/embeddings resolves the
named embedding model across configured providers and answers in
OpenAI's list shape — external RAG pipelines point at FluxCapacitor
with a base-URL swap); **batch concurrency** (a per-batch 1/2/4/8
selector; perform_batch fans rows through Task.async_stream, every
row still its own run with the same counters and broadcasts);
**audio documents** (mp3/wav/webm uploads transcribe through the
workspace default provider's speech endpoint and index as
"[audio: name]" documents); **extract-to-flux** (a multi-selection
plus one button copies nodes and internal edges into a new flux;
template references leaving the selection — including the parent's
start — rewrite to start variables of the extracted graph, verified
by a live-view test asserting {{start.query}} became
{{start.start_query}}; the honest scope note: no automatic call-site
replacement — iteration and loop nodes are the wiring, and the flash
says so); **conversations in backups** (workspace exports carry up to
500 conversations per app with titles, labels, and completed turns;
import restores them — the archive finally holds the chat history the
restore drill couldn't see); and **per-node timeouts** (any node may
carry timeout_ms — runner wraps execution in a supervised task,
brutal-kills past the deadline, and fails with "timed out after Nms";
seconds in the editor beside the retries field). One migration
(workflow_batches.concurrency).

**46. Batch 22 — enterprise sign-on and self-watching evals (v0.4.0).**
**SAML 2.0 SSO** (native via Samly/esaml, no proxy sidecar:
SAML_IDP_METADATA_FILE arms a conditional Samly.Provider child and the
/sso forward; assertions land on /auth/saml/complete where the email
attribute — email/mail/OID/XML-SOAP claim, subject as fallback —
provisions accounts through the same get_or_register_sso_account as
OIDC; SAML_SP_KEY/CERT sign requests when the IdP demands it);
**delay node** (seconds or until an ISO-8601 time, template-capable,
300s cap with an error pointing longer waits at schedule triggers;
outputs waited_ms); **canvas find** (Ctrl/Cmd-F focuses a filter box,
matches ring in warning yellow, the canvas scrolls to the first hit);
**chat-app model A/B** (challenger plugin/model/split columns on apps;
phash2(conversation_id) rem 100 keeps each conversation on its
variant; variant-b replies stamp usage and the monitor compares
replies/likes/dislikes/tokens per variant); **scheduled retrieval
evals** (a cron on the dataset re-runs evaluate_retrieval on the
minute tick, persists last hit rate/MRR, and a drop raises
eval_regressed — the batch-7 golden cases now watch themselves);
**conversation-level evals** (scripted user turns replay through the
app's stateless completion — chatflows included — and the whole
transcript goes to the LLM judge shared with eval sets via the newly
public judge_llm/parse_judge_reply; score drops notify; card on the
app monitor with transcript drill-in); **session device info**
(accounts_tokens carry ip + user-agent captured at login; settings
sessions list shows IP and a browser label); and the **v0.4.0 cut**
(all six mix.exs plus both MCP version strings bumped, CHANGELOG
distilled, tag pushed). Lesson recorded once more: when an Edit
restructures a call, replace the whole expression — patching its tail
left an orphaned case head in save_chat_settings that a follow-up edit
had to remove. Four migrations (accounts_tokens
device info, apps A/B columns, datasets retrieval-eval columns,
conversation_evals). Custom domains and
the Japanese locale stay on the table.

**47. Batch 23 — composition, sight, and pictures.** **Sub-flux call
node** (the call-site extract-to-flux always apologized for: a
"subflux" node runs any published flux as one step — the runner's
request grew an inputs variant beside iteration's item/index, templates
map the child's start variables, its end outputs come back as the
node's outputs, version pin included; verified end-to-end by a
published Greeter sub-flux answering "hello Marty" through a Caller
parent); **LLM node vision** (a vision_variable resolves an uploaded
image's file id through a new read_image host capability — base64 via
Flux.Documents.fetch_image, refusing non-images — and rides the last
user message exactly like chat uploads; missing capability or
unreadable file fails the node honestly); **image generation**
(optional invoke_image on the provider behaviour, OpenAI
/images/generations b64_json shape shared with the compatible plugin,
FAKE-PNG fakes; a builtin:images toolset appears in every tool/agent
picker with one generate_image operation that stores the PNG through
store_run_output onto Files); **GET /v1/models** (OpenAI list shape —
provider models with an app- token's bound model first — so SDKs
autodiscover; the model REGISTRY moved to /v1/registry/models, a
documented breaking change reversing batch 18's "completions-only"
stance now that the user asked for autodiscovery; spec, contract
tests, and guide updated); **conversation-eval crons** (the batch-22
scripted dialogues take a schedule column with the standard
Oban-parsed cron + minute-start dedupe, run from the schedule worker
tick; score drops notify as before); **bulk document operations**
(documents gain an enabled flag cascading to their segments — what
retrieval actually filters on, and re-indexing a disabled document
stays disabled; multi-select bar in the dataset browser
enables/disables/tags/deletes at once); and the **instance
announcement banner** (an "announcement" key in instance_settings, an
admin-panel form beside the status note, and a warning bar atop the
console layout). Two migrations (conversation_evals.schedule,
rag_documents.enabled — the banner needed none). Correction mid-batch: the
LLM-node edit initially left a stray brace block — the batch-22
"replace the whole expression" lesson applied within the hour.

**48. Batch 24 — the surface grows sideways.** **OpenAI-compat tool
calling** (the plugin layer always spoke tools — ToolDefs in, ToolCalls
out — so /v1/chat/completions now normalizes OpenAI function
definitions, tool-role messages, and replayed assistant tool_calls
(JSON-string arguments decoded), passes them through
stateless_completion's new opts, and answers finish_reason
"tool_calls" blocking or as one whole delta in a stream; chatflows
refuse tools with a 400 that says why — they run their own; the echo
plugin and FakeRuntime answer a deterministic call when the prompt
literally asks to "call the tool"); **workspace environment
variables** (workspace_env_vars table, values encrypted with the
workspace DEK, secrets write-only in the listing; the runner merges
the resolved map UNDER the flux's own graph env, so {{env.NAME}}
reaches every template with flux-local values winning; the round-trip
test caught two real bugs — the `&& nil ||` masking idiom fell
through to decrypt, and blanks weren't trimmed); **dataset content
search** (escaped-ILIKE over segments joined to documents, a search
box atop the Documents card); **annotation import/export** (a CSV
kind on the monitor-export controller and a paste-box import through
create_annotation, malformed rows skipping); **knowledge webhook
events** (document.indexed / document.failed on the index worker's
two exits, dataset.synced after datasource sync — and the endpoint
event whitelist had to learn them, which the test caught);
**editor shortcuts overlay** (a "?" keypress or toolbar button flips
a modal listing palette/find/undo/copy/zoom bindings that all
predate their discoverability); and the **quality API round-out**
(GET /v1/conversation-evals, POST .../:id/run blocking, GET
/v1/ab-stats on app- tokens with spec schemas — CI can now drive the
batch-22 dialogue evals and read A/B verdicts). One migration
(workspace_env_vars). Custom domains, Japanese, and 2FA remain the
standing bench.

**49. Batch 25 — polish with teeth.** **Compat structured outputs**
(response_format json_schema on /v1/chat/completions forces the same
respond-tool machinery the LLM node uses — SchemaCheck validation, one
corrective retry quoting the errors back, honest 502 when the model
still can't; json_object injects an instruction; combining with tools
or chatflows refuses with a 400 that says why; streaming delivers the
validated JSON as one delta); **conversation trash** (the last
hard-deleting object gains deleted_at + restore + the cleanup worker's
30-day purge; every visitor/console listing filters it, a Trash card
on monitoring restores); **embedding cache** (per-text sha keys over
{plugin, model, text}, always on with a 24h TTL, partial hits — only
misses reach the provider; stats beside the LLM cache's on settings);
**visitor analytics** (one grouped query rolls conversations,
messages, tokens — jsonb sums via fragment — likes/dislikes with
filtered counts, and last-seen per end_user_ref); **publish notes**
(workflow_versions.note through a publish-button dropdown form,
italicized beside each version row); **URL fetch-now** (the nightly
sweep's per-source body extracted into fetch_url_source_now behind a
button); and **prompt snippet versioning** (edits archive the previous
content into prompt_snippet_versions, history + restore in the tools
page — and the fix that mattered: the upsert's on_conflict insert
returned a phantom id until returning: true, which the round-trip test
caught, along with a batch-24-style `&& nil ||` near-miss avoided by
inspection). Three migrations (conversations.deleted_at,
workflow_versions.note, prompt_snippet_versions). The bench holds:
custom domains, Japanese, 2FA.

**50. Batch 26 — two more dialects and the missing knobs.**
**Anthropic-compatible /v1/messages** (a second wire format beside the
OpenAI one: content blocks in, content blocks out, msg_ ids,
end_turn stop reasons, and the full streaming event sequence
message_start → content_block_delta → message_stop; text-only by
design, chatflows bridge the same way); **OpenAI-compat audio**
(multipart /v1/audio/transcriptions and JSON /v1/audio/speech through
the workspace default provider via a new Providers.speak beside
transcribe — the capabilities existed since v0.3.0, only the HTTP
shape was missing); **run API round-out** (GET
/v1/workflows/runs/:id with ?trace=true exposing node_executions, and
POST .../stop reusing the console's stop_run — runs could start and
resume over the API but never be watched or killed); **dataset
export/import** (a flux-dataset/v1 JSON archive of settings,
documents with tags/metadata/enabled, retrieval cases, and URL
sources; import rebuilds and re-indexes — embeddings deliberately
stay out); **site visitor feedback** (👍/👎 on public chat through
the unauthenticated site scope — the people actually using the apps
finally feed the loop; toggling the active rating clears it);
**editor input presets** (workflows.input_presets jsonb, save/load/
delete on the run panel, 20 cap — the daily retype gone); and **cost
spike alerts** (a grouped-by-day jsonb token sum over runs and
messages, yesterday vs the trailing 7-day average, 2x + 100k floor →
budget_warning at the 08:10 tick; the sum needed a ::bigint cast —
Postgres sums bigints into numerics, which the test caught as a
Decimal arithmetic crash). Two @doc-splitting near-repeats caught at
compile time — the batch-19 lesson earns its ledger space annually.
One migration (workflows.input_presets). The bench holds: custom
domains, Japanese, 2FA.

**51. Batch 27 — the operator's batch.** **Schedule watchdog** (daily
08:20: enabled schedule triggers whose last_run_at predates twice
their expected period notify run_failed; interval triggers read the
period directly, cron triggers estimate it by scanning the next two
fires with the preview's minute-scan; the test's first draft backdated
against real time while faking the tick hour — relative to the fake
now is the honest clock); **chunk preview** (the Chunker dry-runs
paste-in text with the dataset's live settings — parent-child shows
the child chunks that would embed); **batch outputs → dataset**
(export_batch_to_dataset walks the batch's succeeded runs oldest
first, picks answer/text/result/output or the first binary output,
and add_documents with replace into the chosen dataset — the reverse
of run-a-flux-over-a-dataset closes the generate→index circle);
**provider call log** (a 100-entry newest-first ring in the
ProviderHealth GenServer, fed by a :timer.tc wrap in
PluginRuntime.invoke_llm so every provider path is timed at the one
choke point; an expandable table under the admin health counters);
**rolling summary in the monitor** (drill-ins show conversation.summary
— operators finally see what the model believes the thread is about);
**sub-flux navigation** ("Open flux ↗" on subflux/iteration/loop
panels); and **GET /v1/visitors** (the batch-25 rollup on app-
tokens with a spec schema). Also flushed out: batch 26's duplicate
"/messages" spec key (GET list vs POST Anthropic) had silently
overridden under incremental compile — merged into a method list the
moment a clean build surfaced the warning. No migrations. The bench
holds: custom domains, Japanese, 2FA.

**52. Batch 28 — control levers.** **Serving pin**
(workflows.pinned_version resolves first in serving_version — before
the A/B split — so a pin is an honest rollback lever that survives
new publishes; pin/unpin buttons on the versions modal with a
serving-pinned badge; the first validate_pin draft trusted
get_version's truthiness and an error TUPLE passed for a version —
the struct match the test forced is the honest check); **paused-run
reminders** (08:30 daily: one notification per workspace counting
runs paused >24h — human-input work stops waiting in silence);
**visitor forget** (hard-deletes a ref's conversations with message
cascade, chases message-attached uploads into storage, audits
visitor.forget — the GDPR answer, wired to a Forget button with a
no-undo confirm on the visitors table); **dataset archives over the
API** (GET /v1/datasets/:id/export + POST /v1/datasets/import with
spec schemas — batch 26's portability, scriptable); **latency
percentiles** (nearest-rank p50/p95 over the last 100 timed runs on
the fluxes-index health badges — averages hide the tail); **bulk
conversation ops** (multi-select label/delete on monitoring, riding
the existing per-conversation functions); and **watchdog mute**
(workflow_triggers.watchdog_muted filters the batch-27 sweep, toggle
+ badge on the triggers panel — a known-stalled schedule stops
crying wolf daily). One migration (workflows.pinned_version +
workflow_triggers.watchdog_muted). The bench holds: custom domains,
Japanese, 2FA.

**53. Batch 29 — the once-per-org batch.** **Workspace system prompt**
(a custom_config entry combined ahead of each app's own prompt in
build_prompt and stateless_completion — compliance boilerplate written
once; a settings card manages it; verified end-to-end by a capturing
fake runtime asserting the joined system message); **mix flux.backup**
(iterates every workspace with a synthetic owner scope through
Export.workspace, one JSON per workspace named slug+id-prefix,
non-zero exit on any failure — the instance-wide disaster-recovery
dump the per-workspace console button couldn't be); **citation
deep-links** (knowledge_retrieval citations now carry dataset_id +
document_id, console chat sources render as links, and the knowledge
LiveView grew handle_params for ?dataset&document — inserted mid-group
at first, the perennial clause-grouping warning caught at compile);
**cost forecast** (straight-line month-end projection beside the usage
stats, red past 100% of the budget); **visitor transcript** (a public
/site/:token/transcript/:id route reusing the console's Markdown
renderer, authorized by site token + session visitor ref — and the
controller's module-level RequirePermission plug had to learn an
`action not in` exemption, which the 302-to-console test caught);
**credential re-validate** (decrypt → validate_with_plugin → refresh
validated_at behind a Test button — expired keys stop masquerading as
run failures); and **trash purge parity** (purge_dataset +
purge_conversation with purge-now buttons — every trashed object can
now leave early). No migrations. The bench holds: custom domains,
Japanese, 2FA.

**54. Batch 30 — seven features and a new engine block.** **Model
params round-out** (the whitelist grows stop/frequency_penalty/
presence_penalty/top_k/seed; OpenAI-shape plugins pass them through,
Anthropic maps stop → stop_sequences and takes top_k — verified by a
params-capturing fake); **failed-run auto-retry** (workflows.auto_retry
+ workflow_runs.retry_of_id; maybe_auto_retry wraps the executor —
one second attempt, never for batches, never for a retry; the test
learned the retry broadcasts on its own run topic and polls the DB
instead); **audit webhook events** (audit.recorded on every
Audit.record — the SIEM feed); **storage rollup** (a bigint-cast sum
of uploaded_files per workspace on the admin table, human-formatted);
**eval set copy** (set + cases + weights onto another flux);
**single-run JSON export** (a download beside Share trace);
**site maintenance page** (get_app_by_site_token returns
{:maintenance, app} for disabled-not-trashed and the site LiveView
renders a friendly back-soon page — the old hard-404 test updated
deliberately). Then the **toolchain**: every dependency updated
(Phoenix 1.8.10, LiveView 1.1→1.2 with the colocated_js →
colocated_assets rename, Req 0.5→0.7, Oban, Sobelow, Swoosh), the
LiveView bump surfacing one real latent bug (`nil and` in a new :if —
BadBooleanError under 1.2's stricter diffing) — and the release image
moves from Elixir 1.16.2/OTP 26 to **1.20.3/OTP 28.5**. The local
Windows toolchain stays 1.16 (installer-based, needs the GUI
installer — flagged blocked-on-user); mix.exs keeps ~> 1.16 so both
build. One migration (auto_retry + retry_of_id). The bench holds:
custom domains, Japanese, 2FA.

**55. Batch 31 — retrieval dials and the security batch.** Two
proposal items dissolved on grep contact — hybrid retrieval and
annotation auto-reply both already existed (keyword_hits was
full-text ts_rank all along; match_annotation already
embedding-matches) — so the real gaps shipped instead. **Retrieval
modes** (datasets pick hybrid/semantic/keyword; hybrid takes a
semantic_weight that scales RRF contributions ×2w vs ×2(1−w) — 0.5 is
plain RRF — and the full-text source got a GIN expression index
matching keyword_hits exactly); **TOTP 2FA** (NimbleTOTP + eqrcode:
settings-page enrollment with QR + manual key, confirm-to-enable,
eight hashed one-time recovery codes, password logins park in the
session as totp_pending and detour through /accounts/totp — magic
link and SSO stay direct); **site passcodes** (sha256 hash on the
app, a locked LiveView gate posting to a session-setting controller,
asked once per browser session); **conversation auto-titles** (after
the first exchange the workspace model writes 3-6 words; update_all
guarded on title == derived so manual renames win; tests inject
:title_generator); **/v1/moderations** (OpenAI shape over
Guardrails.review — patterns + LLM policy as the category set);
**per-key rate limits** (api_tokens.rate_limit_per_minute, its own
token: bucket, key > app > pipeline default precedence, input on all
three mint forms); **run comments** (run_comments tenant table,
author-or-owner delete, inline on the runs drill-in); **workspace IP
allowlist** (Flux.IPAllowlist parses CIDRs natively with Bitwise
prefix compare; ServiceAuth 403s ip_forbidden and audits
api.ip_rejected; configure refuses any unparseable line — a typo
that allowed nobody would be a lockout). One migration (datasets
mode/weight, accounts totp trio, apps passcode, api_tokens limit,
run_comments, the GIN index). 940 tests. The bench holds: custom
domains, Japanese locale.

**56. Batch 32 — nine from the deep bench.** Two more proposal items
dissolved on inspection (JS code nodes — the Deno runner had them all
along; document metadata editing) and were re-scoped before selection.
Shipped: **Q&A-format indexing** (dataset toggle; qa_pairs/2 turns each
chunk into up to three model-written questions riding the
parent-promotion rails — question embedded and full-text searched,
passage returned; empty generation keeps the chunk; tests inject
:qa_generator); **app icons** (apps.icon emoji on cards and the site
header when no logo); **conversations CSV** (monitor kind=conversations
— 10k-row flattened export); **run tags** (workflow_runs.tags + GIN,
API tags param, drill-in editor, runs-page filter with `^tag in
r.tags`); **bubble theming** (embed.js reads data-flux-color/icon/
position/greeting; the snippet renders them from the app theme —
greeting is a one-time tooltip); **inbound email trigger** (:email
type, emt_ tokens, POST /triggers/email/:token maps Mailgun/SES field
names to from/subject/body/query inputs; webhook tokens 404 on the
email route); **canvas frames** ("frames" beside "notes" in the graph
— named, movable via the frame: drag prefix, ±80px resize buttons,
pointer-events-none body so nodes inside stay clickable); **message
pinning** (messages.pinned, toggle + strip above the console thread);
**workspace default model params** (custom_config default_params
merged UNDER app/node params at all three request-build sites — a
node's own value always wins). Also fixed batch 28's paused-run test:
it backdated from the real clock against the fake-8:30 cutoff, so it
only failed after 14:30 UTC — the batch-27 clock-drift lesson,
recurring. One migration (qa_indexing, icon, tags+GIN, pinned). 952
tests. The bench holds: custom domains, Japanese locale, and batch
32's unpicked #20 (key-expiry warnings).

**57. Batch 33 — the standing list, finally picked.** Seven from the
twice-deferred first list. **/v1/images/generations** (OpenAI shape
over Providers.generate_image — workspace default provider, b64_json
always, ImageList in the spec); **run attribution**
(workflow_runs.started_by set at every creation site: account email,
api:<key prefix> from the service token, trigger:webhook/email,
"mcp", "batch", "replay", "retry" — surfaced in the drill-in);
**dataset duplicate** (settings + documents + tags/metadata through
the normal pipeline; sync schedules and eval history deliberately
stay); **embedding model switch** (update + full re-index in one
audited move — mixed-vintage vectors in one index is silent
poisoning); **site custom CSS** (site_theme custom_css, </style>
stripped, 4k cap, rendered before the accent block); **audit
retention** (sweep_audit_trails in the nightly worker keyed on
custom_config audit_retention_days, min 30 — the ? \? ? jsonb
fragment claimed its python-escaping victim again); **configurable
session lifetime** (@session_validity_in_days becomes
session_validity_in_days/0 reading :session_validity_days, wired to
FLUX_SESSION_VALIDITY_DAYS — instance-wide, not per-workspace,
because sessions belong to accounts). One migration (started_by). 963
tests. The bench holds: custom domains, Japanese locale, require-2FA
policy, key-expiry warnings.

**58. Batch 34 — closing the feedback loop.** Six picked. **API-key
expiry warnings** (a daily tick in the ScheduleWorker chain:
seven-day horizon, expiry_warned_at gates the repeat, api_key_expiring
joins the notification kinds — and therefore the webhook fan-out for
free); **feedback comments** (messages.feedback_comment; site shows an
inline "tell us more" form once rated, the /v1 feedbacks endpoint
takes `content`, clearing the rating clears the text, re-rating keeps
it; monitor review and feedback CSV grew the column); **annotation
editing** (update_annotation re-embeds a changed question — stale
vectors silently mis-match — plus enable/disable from the monitor);
**batch cancel** (:canceled joins the batch enum; the row loop checks
the DB between rows so a cancel lands mid-flight; the completed flip
is now guarded `where status == :running`, and the batch.completed
webhook only fires for genuine completions); **flux-site parity**
(workflows.site_passcode_hash + custom_css in the theme whitelist; the
locked page posts to /site/flux/:token/passcode; app sites and form
pages now gate identically); **PATCH /v1/datasets/:id** (a
settings-params whitelist, Result shape for the contract tests;
embedding model changes deliberately excluded — they belong to the
guarded switch). One migration (expiry_warned_at, feedback_comment,
workflows passcode). 972 tests. The bench holds: custom domains,
Japanese locale, require-2FA policy, member suspension.

**59. Batch 35 — people, timing, and finding things.** Five picked.
**Visitor identity** (apps.collect_visitor_info + conversation
visitor_name/email; an optional pre-chat form on the site — submitting
creates the conversation early if needed; bad emails are ignored, not
stored; monitor rows and the handoff queue show the identity);
**scheduled publish** (workflows.publish_at, a one-shot tick in the
scheduler chain that clears the timestamp BEFORE publishing so a crash
can't machine-gun versions; synthetic editor scope; gates still run;
failures notify run_failed); **document expiry**
(rag_documents.expires_at + disable_expired_documents in the nightly
rag tick — disable-not-delete, segments cascade, re-enabling is a
human decision); **handoff assignment**
(conversations.assigned_account_id, claim/release buttons, assignee
badge — the two-agents-one-visitor race closed); **palette deep
search** (a ?q= lane on /console/palette: conversation titles via a
new workspace-wide ILIKE search and runs via the existing
list_workspace_runs q filter; the JS debounces 250ms and rides remote
results below local matches; monitor and runs pages grew handle_params
deep links — ?conversation= selects, ?run= expands). One migration
(collect flag, identity columns, assigned_account_id, publish_at,
expires_at). 981 tests. The bench holds: custom domains, Japanese
locale, require-2FA policy, member suspension.

**60. Batch 36 (mega) — thirteen from the twenty-list.** The biggest
selection yet. **Webhook secret rotation** (rotate_secret, audited,
flash-once); **app snapshots** (app_snapshots tenant table, a
@snapshot_fields whitelist captured/restored through update_app —
apps finally have undo); **document revisions**
(rag_document_revisions, retire_document on replace keeps five per
name, restore is replace-mode so it stacks rather than destroys —
and taught the one-second-timestamp-tie lesson: order by inserted_at
AND id); **quiet hours** (accounts.quiet_hours_start/end, notify's
fan-out defers in-window emails as EmailWorker Oban jobs scheduled at
the window's end); **prompt A/B** (prompt_b/prompt_split, an
independent phash2 salt so model and prompt arms don't correlate,
usage records prompt_variant, prompt_ab_stats mirrors the model
table); **favorites** (account_favorites, stars sort fluxes/apps
first per account); **fallback chains** (apps.fallbacks list behind
the legacy single fallback, try_fallbacks walks in order);
**conversation cost** (conversation_usage sums assistant usage +
Pricing.estimate on model_used); **handoff SLA**
(handoff_first_reply_seconds recorded once in human_reply before the
flag clears, median-over-30-days badge on the queue); **URL DSL
import** (SSRF-guarded Req fetch into the existing import path);
**console branding** (console_logo_url swaps the sidebar wordmark);
**embedding meter** (datasets.embedded_tokens, chars/4 estimate per
indexing pass — labeled as the estimate it is); **digest frequency**
(weekly/daily/off; daily covers one day and fires any morning, weekly
keeps Mondays; the sent-marker became period-keyed). One migration
(three tables + seven columns). 995 tests. The bench holds: custom
domains, Japanese locale, require-2FA, member suspension, visitor
blocklist, API citations, /v1/usage.

**61. Batch 37 (mega) — thirteen picked, one dissolved honestly.**
The datasource "Sync now" item dissolved on implementation contact —
knowledge.ex has had a manual sync_datasource form since the
datasource batch; proposal grep missed it (the lesson from batch 31
recurs: verify against *both* naming layers before proposing).
Twelve items shipped. **API citations** (chat_message_controller maps
message.citations into metadata.retriever_resources on blocking and
message_end responses — position/dataset_id/document_id/document_name/
content/score, the reference shape); **GET /v1/usage**
(Usage.daily_usage buckets runs + assistant messages by UTC day,
reusing the run usage maps and the console's Pricing.estimate for
chat; UsageList joined the spec); **new-device login alerts**
(generate_account_session_token compares the incoming ip/user_agent
pair against every prior session token and mails
deliver_new_device_alert on a miss — first sessions stay silent);
**message edit & retry** (Chat.edit_message guards last-user-message
+ not-streaming, deletes later turns, re-runs guardrails, spawns the
same generation path; app_chat grew an inline edit form on the last
user bubble); **trigger fire-now** (Workflows.fire_trigger reuses
run_from_trigger so attribution stays "trigger:<type>"; works on
disabled triggers — that's the point of a dry fire); **document
download** (RAG.download_document behind dataset_document_download —
a permission that had sat unused for twenty batches);
**audit actor filter** (Audit.list actor_id option + a member select
that rides the CSV export querystring too); **workspace default
locale** (custom_config "locale"; the Locale plug moved *after* the
scope fetch in the browser pipeline and slots the workspace default
between session and Accept-Language, so explicit choices still win);
**web push** (native Flux.WebPush: RFC 8291 aes128gcm encryption and
RFC 8292 VAPID ES256 on bare :crypto — no push SDK, per the
no-sidecars rule; instance keypair lazily minted into
InstanceSettings, push_subscriptions per account, delivery as Oban
jobs that drop 404/410-gone endpoints; notify() fans out handoff +
run_failed only; sw.js + a WebPush hook + settings toggle complete
the loop. Req lesson: its test-plug adapter eats the
content-encoding request header while decompress-probing, so the
test asserts the rest of the wire format); **transcript email**
(Chat.email_transcript requires the batch-35 visitor_email, renders
speaker-labeled text, mails via the account notifier; an envelope
button on the site); **snippet picker** (app_chat had *no* system
prompt editor at all — the picker item grew into a System prompt
card with draft state and an append-from-library select);
**SCIM Groups** (/scim/v2/Groups where group id = role;
add/replace/remove Operations in both Okta value-list and Entra
filtered-path styles via scim_set_member_role — owners never move,
mirroring the Users deprovision rule). One migration
(push_subscriptions). 1020 tests. The bench holds: custom domains,
Japanese locale, require-2FA, member suspension, visitor blocklist,
trusted 2FA devices, site localization.

**62. Batch 38 — twelve picked, two honest reshapes.** The "login
throttling" item turned out half-built (a per-IP auth limiter had
covered the login POST since batch 15), so it landed as the additive
half: a per-*email* bucket across IPs (15/15min, audited
account.login_throttled) that distributed guessers can't rotate out
of. And "plugin install from URL" hit an architectural wall — plugins
are compiled BEAM modules with no package system — so it landed as
the data-shaped equivalent: OpenAPI toolset import by URL
(SSRF-guarded, same parse path as paste). The other ten as scoped:
**site localization** (every visitor string through gettext; the
public_site live_session grew the Locale on_mount; de/es/fr
translated — 33 strings each, including a few older console strays);
**idle timeout** (accounts_tokens.last_used_at, verify-query filter
via coalesce(last_used_at, inserted_at), touch throttled to
once-per-5-min so it isn't a write per request;
FLUX_SESSION_IDLE_MINUTES); **/v1/responses** (input/instructions →
the same stateless completion as /chat/completions; response.created
/ output_text.delta / response.completed SSE events; new SDKs
autodiscover now); **chat document uploads** (extraction happens ONCE
at store time into uploaded_files.extracted_text via
Documents.extract_binary; build_prompt appends per-doc-capped text
blocks so history replays don't re-extract; image/audio/video pass
through to their own paths; the /v1 files param takes documents too);
**site voice** (the console's MicRecorder loop verbatim: upload
:audio, provider transcription, transcript lands client-side);
**GET /v1/messages/:id/suggested** (reference shape over the
existing follow_up_suggestions); **ds- keys** (api_tokens.dataset_id,
ServiceAuth confines the token to /v1/datasets/<its-id>/* by path —
everything else 403s; minted from the knowledge page, shown once;
workspace-token listing filters them out); **flux/app tags**
(tags columns + changeset cast, chips + filter + inline per-card
editors on both index pages — HEEx :for takes no comprehension
filters, hence filter_by_tag/2); **OIDC claim→role**
(exchange_code now surfaces claims; apply_oidc_roles syncs roles per
login for workspaces with a custom_config mapping; owners and
unmatched members never move — removal is a human decision);
**scheduled backups** (Flux.Backup wraps the mix flux.backup logic
for Storage.put under backups/<date>/, gated once-a-day through
InstanceSettings so restarts don't double-run; scheduler tick calls
it). One migration (five columns). 1039 tests. The bench holds:
custom domains, Japanese locale, require-2FA, member suspension,
visitor blocklist, trusted 2FA devices, CSAT surveys, site share QR.
