# Getting started

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
handbook, an agent with a scratch drive, and three published apps —
everything running on the built-in **echo provider**, which needs no API
key. Log in with the demo email via magic link (in development the mail
lands in the dev mailbox at `/dev/mailbox`).

## Manual path

1. **Register** at `/accounts/register` (magic-link login; the dev
   mailbox shows the email locally) and create a workspace.
2. **Plugins** → the echo provider is ready out of the box. To use real
   models, click *Configure* on OpenAI/Anthropic/Gemini (or *OpenAI
   compatible* for Grok/Together/Ollama/vLLM) and paste a key —
   credentials are validated against the provider and stored encrypted
   per workspace. Several named keys can coexist; the default one is
   what nodes resolve.
3. **Fluxes** → *New Flux* opens the canvas. Every flux starts with a
   `start → llm → answer` skeleton; bind the LLM node to a model and hit
   *Run*. Publish a version when it works — the API, sites, schedules,
   and chatflow apps always run the latest published version, never the
   draft.
4. **Apps** → create a chat, completion, or chatflow app. Publish it as
   a public site, embed it with the iframe/bubble snippets, or mint an
   API key and call `/v1` (see the [service API guide](service-api.md)).
5. **Knowledge** → create a dataset (echo embeddings work for trying it
   out), add documents by upload, paste, or URL, watch them index, and
   hit-test retrieval. Wire a `knowledge` node to the dataset in any
   flux.

## Where things live

| Area | Console page |
|---|---|
| Workflow canvas, runs, versions, triggers, variables | `/console/fluxes/:id` |
| Apps, chat settings, publishing, API keys | `/console/apps/:id` |
| Monitoring, feedback, annotations, search | `/console/apps/:id/monitor` |
| Datasets, documents, segments, hit testing | `/console/knowledge` |
| Providers, tool/datasource plugins, credentials | `/console/plugins` |
| API toolsets (OpenAPI imports) | `/console/tools` |
| Members, roles, invitations | `/console/members` |
| Audit trail | `/console/audit` |
| Workspace settings, SCIM, plan, export, retention | `/console/settings` |

## Production notes

Set `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, and `FLUX_MASTER_KEY`
(the root key for per-workspace credential encryption). Optional:
`STORAGE_BACKEND=s3` + `S3_*` for object storage, `FLUX_METRICS=1` for
Prometheus, `FLUX_LOG_JSON=1` for structured logs,
`OTEL_EXPORTER_OTLP_ENDPOINT` for traces, `FLUX_OIDC_*` for SSO, and
`FLUX_ROLE=web|worker` to split serving from queue processing.
