# Getting started

![FluxCapacitor assistant](../images/flux-assistant.jpg)

FluxCapacitor runs as a single Elixir/Phoenix umbrella on Postgres. This
guide takes you from clone to a working workspace with a published app.

## Run it

```bash
mix setup            # deps, database, assets
mix phx.server       # console at http://localhost:4000
```

Or via Docker:

```bash
docker compose up -d                  # postgres + minio
docker compose --profile full up -d   # + the app
```

## Fastest path: the demo workspace

```bash
mix flux.demo
```

This seeds `demo@fluxcapacitor.local` with a **Demo Workspace**
containing a branching triage flux, a RAG chatflow over a seeded
handbook, an agent with a scratch drive, three published apps, and the
full **label → train loop**: a "Ticket intent" labeling project with a
head start of labeled examples (plus a couple left for you to tag) and
the Model trainer flux ready to consume the project's JSONL export —
everything running on the built-in **echo provider**, which needs no API
key. Log in with the demo email via magic link (in development the mail
lands in the dev mailbox at `/dev/mailbox`).

## Manual path

1. **Register** at `/accounts/register` (magic-link login; the dev
   mailbox shows the email locally) and create a workspace.
2. **Plugins** → the echo provider is ready out of the box. To use real
   models, click *Configure* on OpenAI/Anthropic/Gemini, *Azure OpenAI*
   (endpoint + deployment names), *Amazon Bedrock* (IAM keys + region,
   Claude models), or *OpenAI compatible* (Grok/Together/Ollama/vLLM)
   and paste a key — credentials are validated against the provider and
   stored encrypted per workspace. Several named keys can coexist; the
   default one is what nodes resolve. The dashboard's **Getting started
   checklist** tracks these first steps.
3. **Fluxes** → *New Flux* opens the canvas, or pick a card from the
   **template gallery** (triage, RAG answer, human review, model
   trainer, report writer, intent router — plus anything your team has
   promoted with **Save as template**) to start with a working graph.
   The canvas supports **sticky notes** (saved with the graph, undoable)
   for in-place documentation. Every blank flux starts with
   a `start → llm → answer` skeleton; bind the LLM node to a model and
   hit *Run*. Or skip the skeleton: describe what you want in **Draft
   with AI** and the helper generates the nodes and wiring through the
   workspace default model — every draft is engine-validated before it
   reaches the canvas, and nothing publishes without you. On an existing
   flux, **Edit with AI** revises the draft from an instruction — the
   result is validated first and lands as one undoable edit. From the run
   panel, **Batch runs** executes the draft *or any published version*
   over a CSV of inputs (send completed results to a labeling project, or
   save the row set as a **recurring cron batch**), and **Evals** scores
   it against a test-case set (exact, contains, regex, or LLM-as-judge
   with a selectable judge model; cases can carry weights) so draft and
   published versions compare side by side. Mark an eval set as a
   **gate** and publishing runs it automatically — a regression blocks
   the publish — or give it a **cron schedule** and it re-scores the
   latest published version on its own (drift detection between
   releases). Publish a version when it works — the API, sites,
   schedules, and chatflow apps always run the latest published version,
   never the draft — unless you configure an **A/B split** in the
   versions modal, which sends a share of live traffic to another
   published version and reports runs/success/tokens per arm.
4. **Apps** → create a chat, completion, or chatflow app. Publish it as
   a public site, embed it with the iframe/bubble snippets, or mint an
   API key and call `/v1` (see the [service API guide](service-api.md)).
5. **Knowledge** → create a dataset (echo embeddings work for trying it
   out), add documents by upload, paste, or URL, watch them index, and
   hit-test retrieval. Wire a `knowledge` node to the dataset in any
   flux. Per-dataset settings cover chunk size/overlap,
   **markdown-aware splitting** (chunks keep their headings), and
   **query expansion** (the workspace model rephrases each query and all
   rankings fuse — better recall for one extra model call), a
   **retrieval mode** (`hybrid` fuses semantic + keyword + entity
   rankings; `semantic`/`keyword` run one source alone) with an optional
   **semantic weight** skewing hybrid fusion, and
   **retrieval evals** score golden question → expected-passage cases
   (hit rate + MRR) so chunking/backend changes are measurable. Tag
   documents and the knowledge node can **filter retrieval by tag**
   (templatable, e.g. `{{start.category}}`). At corpus
   scale, set `FLUX_VECTOR_BACKEND=pgvector` (SQL-side similarity; add
   `FLUX_VECTOR_DIMS` for an HNSW approximate index) or
   `FLUX_VECTOR_BACKEND=arango` (AQL cosine next to the entity graph),
   and `FLUX_ARANGO_URL` (the `rag` profile) for deeper related-entity
   graph traversal.

## Testing

`mix test` at the umbrella root runs everything (~940 tests) with no
network — fake providers, injected converters, temp-dir storage. To run
a single app's tests, `cd` into the app first; `mix test apps/flux`
from the root silently runs nothing. Golden replay fixtures, `/v1`
contract tests, and reference-parity traces ride along in the same
suite; `coderunner/test_server.py` live-checks the code sandbox against
its running container. See the README's Testing section for the full
map.

## Where things live

| Area | Console page |
|---|---|
| Workflow canvas, runs, versions, triggers, variables | `/console/fluxes/:id` |
| Batch runs (CSV-driven), evaluations | `/console/fluxes/:id/batches` · `/console/fluxes/:id/evals` |
| Apps, chat settings, publishing, API keys | `/console/apps/:id` |
| Monitoring, feedback, annotations, search | `/console/apps/:id/monitor` |
| Datasets, documents, segments, hit testing | `/console/knowledge` |
| Data labeling: projects, tagging queue, consensus + agreement, gold standards + labeler accuracy, JSONL export | `/console/labeling` |
| Workspace-wide run history: filters, text search, cost totals, per-node drill-in with token attribution | `/console/runs` |
| Stored files, model registry, scheduled export archives | `/console/files` |
| Notification feed: failures, regressions, completions | `/console/notifications` |
| Providers, tool/datasource plugins, credentials | `/console/plugins` |
| API toolsets (OpenAPI imports) | `/console/tools` |
| Members, roles, invitations | `/console/members` |
| Audit trail | `/console/audit` |
| Workspace settings, SCIM, plan, export, retention, outgoing webhooks | `/console/settings` |

## Production notes

Set `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, and `FLUX_MASTER_KEY`
(the root key for per-workspace credential encryption). Optional:
`STORAGE_BACKEND=s3` + `S3_*` for object storage, `FLUX_METRICS=1` for
Prometheus, `FLUX_LOG_JSON=1` for structured logs,
`OTEL_EXPORTER_OTLP_ENDPOINT` for traces, `FLUX_OIDC_*` for SSO,
`FLUX_VECTOR_BACKEND=pgvector` for SQL-side similarity,
`FLUX_ARANGO_URL` for the entity-graph backend, and
`FLUX_ROLE=web|worker` to split serving from queue processing. Workspace
settings can schedule **automatic export archives** (cron) that land on
the Files page as backups, set a **monthly token budget** (warns at 80%,
refuses runs past the cap), and enable the **LLM response cache**
(identical prompts within the TTL answer from memory, billed at zero).
**Guardrails** (regex deny patterns, one per line) block or flag chat
and run inputs and always flag outputs, raising routable `guardrail`
notifications. A **concurrent-run cap** refuses interactive runs past
the limit (batches/evals exempt — they serialize anyway). Outgoing webhooks keep a
**delivery log** (status, attempts, manual retry) in settings, and
endpoints can subscribe to **`notification.*` events** to route exactly
the console notifications they care about. `FLUX_ADMIN_EMAILS` unlocks
the **instance admin panel** (`/console/admin`): every workspace on the
deployment with plan control and 30-day volume. Workspace exports carry
the **whole quality loop** — eval sets, labeling projects (labels and
gold standards included), and retrieval cases restore with the archive.

## Localization

The web UI resolves its locale per request: an explicit `?locale=xx`
query parameter wins (and is remembered in the session), then the
session, then the browser's `Accept-Language` header. Unknown locales
fall back to English.

To add a language, from `apps/flux_web` run
`mix gettext.merge priv/gettext --locale <code>` (e.g. `fr`), translate
the strings in `priv/gettext/<code>/LC_MESSAGES/default.po`, and
recompile. New translatable strings are wrapped with `gettext("...")`
in the templates and collected with `mix gettext.extract --merge`. The
account and landing pages, the console shell (sidebar and navigation),
and the dashboard are wrapped today; the rest of the console is wrapped
incrementally. **French (`fr`) and Spanish (`es`) catalogs ship
translated** — try `/console?locale=fr` or `?locale=es` — and are the
reference for adding further languages.
