# Changelog

All notable changes to FluxCapacitor are recorded here. The format loosely
follows [Keep a Changelog](https://keepachangelog.com/); the project follows
semantic versioning once past 1.0. Detailed build history lives in the ledger
at `docs/PARITY-PLAN.md`.

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
