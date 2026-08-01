# Service API (/v1)

Bearer-token HTTP API, wire-compatible with the upstream reference so
existing client SDKs work. The machine-readable contract is served at
`GET /v1/spec` (OpenAPI, strict schemas) and enforced by contract tests.

**Tokens** are minted in the console: `app-…` on an app's page, `flux-…`
in the flux editor's API modal. The token names the app/flux — no other
routing is needed. Requests are rate limited per principal (429 +
`Retry-After`).

## Chat & completion apps (`app-…` tokens)

| Endpoint | Purpose |
|---|---|
| `POST /v1/chat-messages` | Send a message. `response_mode`: `streaming` (SSE, default) or `blocking`. `conversation_id` continues a thread; `files` attaches image uploads for vision models |
| `POST /v1/completion-messages` | Run a completion app with `inputs` |
| `GET /v1/conversations` · `GET /v1/messages` | List threads / a thread's messages |
| `POST /v1/conversations/:id/name` · `DELETE /v1/conversations/:id` | Rename / delete |
| `POST /v1/chat-messages/:id/stop` | Stop a streaming reply (streamed prefix is kept) |
| `POST /v1/messages/:id/feedbacks` | Rate a reply (`like`/`dislike`/null) |
| `POST /v1/files/upload` | Multipart upload; returns the file id used by `files` |
| `GET /v1/parameters` · `GET /v1/meta` | App config for clients |

SSE frames are `data: {json}\n\n` with `event: "message"` deltas and a
final `message_end` carrying usage. Quota-exceeded apps return 429 with
`code: "quota_exceeded"`.

## Workflows (`flux-…` tokens)

| Endpoint | Purpose |
|---|---|
| `POST /v1/workflows/run` | Run the latest published version. SSE by default (`workflow_started`, `node_started`, `text_chunk`, `node_finished`, `agent_part`, `workflow_finished`) or `response_mode: "blocking"` |
| `POST /v1/workflows/runs/:id/resume` | Answer a paused `human_input` node with `input` |

## Knowledge (any valid token)

| Endpoint | Purpose |
|---|---|
| `GET/POST /v1/datasets` | List / create datasets |
| `DELETE /v1/datasets/:id` | Delete a dataset |
| `POST /v1/datasets/:id/document/create-by-text` | Add a document (`name`, `text`) |
| `POST /v1/datasets/:id/document/create-by-url` | Fetch a URL into a document (SSRF-guarded) |
| `GET /v1/datasets/:id/documents` · `DELETE …/documents/:document_id` | List / delete documents |
| `GET …/documents/:document_id/segments` | Browse indexed segments |
| `POST /v1/datasets/:id/retrieve` | Hybrid retrieval (`query`, optional `top_k`; defers to dataset settings) |

## Adjacent HTTP surfaces

- `POST /triggers/webhook/:token` — start a run from a webhook trigger;
  202 + run id. If the trigger has a shared secret, send it as
  `x-flux-token`.
- `/e/:installation-token/*path` — endpoint plugins (rate limited per
  token).
- `/scim/v2/Users` — IdP provisioning with the workspace SCIM bearer
  token.
- Failure-alert webhooks the platform *sends* are signed:
  `x-flux-signature: sha256=HMAC(body)` with the `whsec_` secret shown
  in workspace settings.

## Example

```bash
curl -N -X POST "$HOST/v1/chat-messages" \
  -H "Authorization: Bearer app-..." \
  -H "Content-Type: application/json" \
  -d '{"query": "How do refunds work?", "response_mode": "streaming"}'
```
