# Node reference

A flux is a directed acyclic graph. Nodes read from the **variable
pool** with `{{node_id.key}}` templates; the reserved namespaces are
`{{sys.*}}` (query, history, item/index in sub-fluxes), `{{env.*}}`
(per-flux environment), `{{conversation.*}}` (chatflow variables), and
each node's own outputs. Unresolvable references render empty and the
editor warns about them.

**Branching & fan-out:** `if_else` and `question_classifier` leave on
named handles. Any handle with *several* outgoing edges fans out into
**parallel branches** that reconverge at the first shared join node.
Every failable node may also route an `error` handle; downstream nodes
then see `%{"error", "is_error"}` as its outputs. Retries are per-node
(`retry.max_retries` ≤ 5).

| Node | What it does | Key config | Outputs |
|---|---|---|---|
| `start` | Validates run inputs against declared variables | `variables` (name/label/type/required) | one key per variable |
| `llm` | Calls a model, streaming | provider+model, `system_prompt`, `prompt`, optional `output_schema`, optional fallback model | `text`, `usage`, `model_used`, `fallback_used`, `output` (with schema) |
| `agent` | Autonomous tool loop with an iteration cap | provider+model, `instructions`, `query`, `max_iterations`, `tools`, `output_schema`, `enable_drive`, deferred tools | `text`, `output`, `status`, `iterations`, `tool_calls`, `files` |
| `if_else` | Case chain (if/elif/else) | `cases` with conditions | handle per case + `false` |
| `question_classifier` | LLM-forced classification | provider+model, `classes` | handle per class, `class` |
| `parameter_extractor` | LLM-forced structured extraction | provider+model, `parameters` | one key per parameter |
| `template` | Renders a template | `template` | `output` |
| `variable_aggregator` | First non-empty of several sources | `variables` (selector list) | `output` |
| `variable_assigner` | Writes conversation variables | `assignments` | assigned keys (persisted per conversation) |
| `list_operator` | Filter/sort/slice a list | `variable`, operations | `output`, `count` |
| `code` | Runs code via the sandboxed runner | `language`, `code`, `dependencies` | `result` keys, `stdout` |
| `http_request` | SSRF-guarded HTTP call | method/url/headers/body | `status`, `body`, `text` |
| `tool` | Calls one operation of a toolset or tool plugin | `toolset_id`, `operation_id`, args | `status`, `body`, `text` |
| `knowledge_retrieval` | Hybrid retrieval across datasets | `dataset_ids`, `query`, `top_k` (blank = dataset default) | `result`, `citations`, `count` |
| `document_extractor` | Uploaded file → text | `variable` (file id) | `text`, `name`, `size` |
| `iteration` | Runs a published sub-flux once per list item | `variable`, `workflow_id`, `max_items` | `output` (list), `count` |
| `loop` | Bounded while over a published sub-flux | `workflow_id`, `initial`, `max_loops`, break `conditions` | `output`, `rounds`, `condition_met`, `history` |
| `human_input` | Pauses the run for a person | `prompt`, `options` | `output` (the reply, after resume) |
| `answer` | Streams/records the user-facing answer | `answer` template | `answer` |
| `end` | Maps run outputs explicitly | `outputs` (key/value) | the mapped keys |

## Sub-fluxes (iteration & loop)

Both compose over a *published* flux rather than inline scopes (see
`docs/ITERATION-DESIGN.md` for why). The sub-flux receives
`{{sys.item}}` / `{{sys.index}}` plus `item`/`index` start inputs; loop
feeds each round's outputs in as the next round's item and evaluates its
break condition against them (`{{<loop_node_id>.<key>}}`). Sub-fluxes
cannot pause or start their own sub-fluxes.

## Runs

Runs stream events live to the editor, public sites, and `/v1` SSE.
They end `succeeded`/`failed`/`stopped` — or `paused` on `human_input`,
resumable from the console, a site, or
`POST /v1/workflows/runs/:id/resume`. Per-node traces (status, outputs,
timing) are stored on every run and browsable in the editor's history.
