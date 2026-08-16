# Service API (/v1)

Bearer-token HTTP API, wire-compatible with the upstream reference so
existing client SDKs work. The machine-readable contract is served at
`GET /v1/spec` (OpenAPI, strict schemas) and enforced by contract tests;
a browsable **API reference** generated from that same spec lives in
the console at `/console/docs/api-reference`.

**Tokens** are minted in the console: `app-…` on an app's page, `flux-…`
in the flux editor's API modal. The token names the app/flux — no other
routing is needed. Requests are rate limited per principal (429 +
`Retry-After`); a key minted with its own requests/minute cap gets its
own bucket (key limit beats app limit beats the default). Workspaces
with an API IP allowlist configured answer 403 `ip_forbidden` to calls
from other addresses — even with a valid key.

## Chat & completion apps (`app-…` tokens)

| Endpoint | Purpose |
|---|---|
| `POST /v1/chat-messages` | Send a message. `response_mode`: `streaming` (SSE, default) or `blocking`. `conversation_id` continues a thread; `files` attaches image uploads for vision models. Replies carry `metadata.retriever_resources` (knowledge citations: `document_name`, `content`, `score`, ids) on the blocking document and the `message_end` SSE event |
| `POST /v1/completion-messages` | Run a completion app with `inputs` |
| `GET /v1/conversations` · `GET /v1/messages` | List threads / a thread's messages |
| `POST /v1/conversations/:id/name` · `DELETE /v1/conversations/:id` | Rename / delete |
| `POST /v1/chat-messages/:id/stop` | Stop a streaming reply (streamed prefix is kept) |
| `GET /v1/messages/:id/suggested` | Follow-up question suggestions after a reply (`{result, data: [q…]}`) |
| `POST /v1/messages/:id/feedbacks` | Rate a reply (`like`/`dislike`/null); optional `content` attaches a text comment |
| `POST /v1/files/upload` | Multipart upload; returns the file id used by `files` |
| `GET /v1/parameters` · `GET /v1/meta` | App config for clients |

SSE frames are `data: {json}\n\n` with `event: "message"` deltas and a
final `message_end` carrying usage. Quota-exceeded apps return 429 with
`code: "quota_exceeded"`.

## Workflows (`flux-…` tokens)

| Endpoint | Purpose |
|---|---|
| `POST /v1/workflows/run` | Run the latest published version. An optional `tags` array labels the run for the runs-page tag filter. SSE by default (`workflow_started`, `node_started`, `text_chunk`, `node_finished`, `agent_part`, `workflow_finished`) or `response_mode: "blocking"`. Finished payloads carry `total_tokens` (input + output across every model call in the run) |
| `POST /v1/workflows/runs/:id/resume` | Answer a paused `human_input` node with `input` |
| `POST /v1/workflows/batch` | Start a batch: `rows` (array of input objects, ≤ the CSV cap), optional `name` and `version` (defaults to the draft). 202 + `batch_id` |
| `GET /v1/batches/:id` | Batch progress; `?include_results=true` adds per-row inputs/outputs |
| `GET /v1/batches/:id/events` | SSE progress: `batch_progress` frames as rows land, a final `batch_completed` |
| `GET /v1/eval-runs/:id/events` | SSE progress for an eval run, ending in `eval_completed` |
| `GET /v1/eval-sets` | List the flux's eval sets (with their `gate` flag and cron `schedule`) |
| `POST /v1/eval-sets/:id/run` | Start an eval: optional `grader` (`exact`/`contains`/`regex`/`llm_judge`), `version`, `judge` (`"plugin|model"`). 202 + `eval_run_id`. Case weights (set via the console or a `weight` CSV column) scale each case's influence on `avg_score` |
| `GET /v1/eval-runs/:id` | Eval status, pass counts, `avg_score`, per-case results |

## Models, notifications, retrieval evals (any valid token)

| Endpoint | Purpose |
|---|---|
| `POST /v1/messages` | Anthropic-compatible completion on `app-` tokens (blocking + streaming, text-only) |
| `POST /v1/audio/transcriptions` · `POST /v1/audio/speech` | OpenAI-shaped speech-to-text (multipart) / text-to-speech via the workspace default provider |
| `GET /v1/workflows/runs/:id` · `POST /v1/workflows/runs/:id/stop` | Run status (`?trace=true` adds per-node executions) / stop a running run (`flux-` token) |
| `GET /v1/models` | OpenAI-compatible model list (provider models; an `app-` token's bound model first) — SDK autodiscovery |
| `POST /v1/moderations` | OpenAI-compatible moderation judged by the workspace guardrails (deny patterns + LLM policy); categories are `pattern` and `policy` |
| `POST /v1/images/generations` | OpenAI-compatible image generation via the workspace default model's provider; `prompt` required, `model`/`size` optional, answers `b64_json` |
| `POST /v1/responses` | OpenAI Responses API (the endpoint new OpenAI SDKs default to): `input` (string or message array) + `instructions`, blocking or SSE (`response.created` / `response.output_text.delta` / `response.completed`); tools/state extras unsupported |
| `GET /v1/registry/models` · `POST /v1/registry/models` | List / register model-registry entries (`name`, `file_id`, optional `metrics`; versions auto-increment). **Moved from `/v1/models` in v0.5.0** |
| `GET /v1/notifications` | The workspace notification feed (`?limit=`) |
| `GET /v1/usage` | Daily token/cost totals over `?days=` (default 30): runs + chat replies per UTC day, newest first |

Token kinds: `app-` (one chat app), `flux-` (one workflow), `ws-`
(workspace-wide datasets/quality/models), and `ds-` — a dataset key
minted from the knowledge page that opens exactly
`/v1/datasets/<its-id>/…` and nothing else (share a KB without
workspace-wide power).
| `GET /v1/conversation-evals` | The app's scripted-dialogue evals with last scores (`app-` token) |
| `POST /v1/conversation-evals/:id/run` | Replay and judge one dialogue, blocking (`app-` token) |
| `GET /v1/visitors` | Per-visitor rollup: conversations, messages, tokens, feedback (`app-` token) |
| `GET /v1/ab-stats` | Model A/B per-variant replies, feedback, tokens (`app-` token) |
| `GET/POST /v1/datasets/:id/retrieval-cases` | List / add golden retrieval cases (`question`, `expected`) |
| `POST /v1/datasets/:id/retrieval-eval` | Score retrieval: hit rate, MRR, per-case ranks |

## Labeling (any valid token)

| Endpoint | Purpose |
|---|---|
| `GET /v1/labeling/projects` | List projects with label schema and counts |
| `POST /v1/labeling/projects/:id/tasks` | Push up to 100 `items` (strings or objects) as tasks |
| `GET /v1/labeling/projects/:id/next` | Claim the next unlabeled task (or `task: null`) |
| `POST /v1/labeling/tasks/:id/label` | Submit a `label`; 422 `invalid_label` if it doesn't match the project schema |
| `GET /v1/labeling/projects/:id/export` | Labeled tasks as JSONL (`{"data": …, "label": …}` per line) |

## Knowledge (any valid token)

| Endpoint | Purpose |
|---|---|
| `GET/POST /v1/datasets` | List / create datasets |
| `DELETE /v1/datasets/:id` | Delete a dataset |
| `PATCH /v1/datasets/:id` | Update dataset settings: chunking, retrieval mode/weight, Q&A indexing, thresholds (embedding model changes need the console's guarded switch) |
| `POST /v1/datasets/:id/document/create-by-text` | Add a document (`name`, `text`) |
| `POST /v1/datasets/:id/document/create-by-url` | Fetch a URL into a document (SSRF-guarded) |
| `GET /v1/datasets/:id/documents` · `DELETE …/documents/:document_id` | List / delete documents |
| `GET …/documents/:document_id/segments` | Browse indexed segments |
| `POST /v1/datasets/:id/retrieve` | Hybrid retrieval (`query`, optional `top_k`; defers to dataset settings) |
| `GET /v1/datasets/:id/export` · `POST /v1/datasets/import` | Portable `flux-dataset/v1` archive out / rebuild a dataset from one (201 + counts) |

## Adjacent HTTP surfaces

- `POST /triggers/webhook/:token` — start a run from a webhook trigger;
  202 + run id. If the trigger has a shared secret, send it as
  `x-flux-token`.
- `POST /triggers/email/:token` — inbound-mail trigger: point a
  Mailgun route / SES / Postmark inbound webhook here. `from`/`sender`,
  `subject`, and `body-plain`/`stripped-text`/`text` become run inputs
  (the body doubles as `query`). Same 202 + run id contract.
- `/e/:installation-token/*path` — endpoint plugins (rate limited per
  token).
- `/scim/v2/Users` — IdP provisioning with the workspace SCIM bearer
  token.
- `/scim/v2/Groups` — group→role mapping over the same token: group id
  = role (`admin`, `editor`, `normal`, `dataset_operator`); PATCH
  add/replace/remove members sets roles (Okta value lists and Entra
  `members[value eq "…"]` paths both work; owners never move).
- Failure-alert webhooks the platform *sends* are signed:
  `x-flux-signature: sha256=HMAC(body)` with the `whsec_` secret shown
  in workspace settings. Subscribable events: `run.*` lifecycle,
  `batch.completed`, `eval.completed`, `feedback.created`,
  `labeling.task_labeled`, and `labeling.project_completed`.

## Example

```bash
curl -N -X POST "$HOST/v1/chat-messages" \
  -H "Authorization: Bearer app-..." \
  -H "Content-Type: application/json" \
  -d '{"query": "How do refunds work?", "response_mode": "streaming"}'
```
