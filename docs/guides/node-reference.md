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

## Nodes in detail

### `start`

Every flux begins here. Declare the run's input variables
(name/label/type/required); the node validates incoming inputs against
them and exposes each as `{{start.<name>}}`. Chatflows also get
`{{sys.query}}` and `{{sys.history}}` without declaring anything.

### `llm`

Calls a chat model and streams the reply. Pick a provider+model, write
a `system_prompt` and `prompt` (both templated), optionally attach an
`output_schema` for structured JSON output (`{{node.output}}`) and a
fallback model that takes over when the primary errors. Outputs `text`,
`usage`, `model_used`, `fallback_used`.

### `agent`

An autonomous tool-calling loop: the model decides which of the
attached toolsets to call, up to `max_iterations` rounds.
`enable_drive` gives it a sandboxed scratch drive (`files` output);
`output_schema` forces a final structured answer; deferred tools pause
the run for outside execution. Outputs `text`, `output`, `status`,
`iterations`, `tool_calls`.

### `if_else`

A case chain (if / elif / else). Each case is a condition set over
variable-pool references; the run leaves on the matching case's handle,
or `false` when nothing matches. Several edges on one handle fan out
into parallel branches.

### `question_classifier`

Forces an LLM to sort the input into one of your `classes`; the run
continues on that class's handle. Use it to route support questions,
detect intent, or triage. Outputs `class`.

### `parameter_extractor`

Forces an LLM to extract the `parameters` you declare (name, type,
description, required) from free text into structured pool values —
one output key per parameter.

### `template`

Renders text from the variable pool. The `simple` engine substitutes
`{{refs}}`; the `jinja` engine adds filters (`{{ name|upper }}`),
`{% if %}` chains, and `{% for %}` loops. Or pick a saved doc template
from the workspace library. Outputs `output`.

### `variable_aggregator`

Takes the first non-empty of several source references — the way to
merge branches (e.g. either classifier path) back into one variable.
Outputs `output`.

### `variable_assigner`

Writes values into `{{conversation.*}}` variables that persist across a
chatflow conversation — remember a user's name, accumulate state,
build multi-turn forms.

### `list_operator`

Filters, sorts, and slices a list from the pool without code. Outputs
the transformed `output` plus `count`.

### `code`

Runs a code snippet in the sandboxed runner (Elixir today; more via the
coderunner container). The returned map's keys become outputs, plus
`stdout`.

### `http_request`

Calls an external HTTP API — method, URL, headers, and body are all
templated, and the URL is SSRF-guarded. Outputs `status`, `body`
(parsed JSON when possible), and raw `text`.

### `tool`

Calls one operation of an imported OpenAPI toolset or an installed tool
plugin, with templated arguments. Outputs `status`, `body`, `text`.

### `knowledge_retrieval`

Hybrid (keyword + vector + entity) retrieval across the datasets you
check, using RRF ranking. `top_k` left blank defers to each dataset's
own retrieval settings. Outputs `result` (joined passages),
`citations`, `count`.

### `document_extractor`

Turns an uploaded file (from a file-type start variable) into plain
text — native for text/HTML formats. Outputs `text`, `name`, `size`.

### `iteration`

Runs a *published* sub-flux once per item of a list, in order, and
collects the results. The sub-flux sees `{{sys.item}}` /
`{{sys.index}}`. `max_items` caps the fan-out. Outputs `output` (list)
and `count`.

### `loop`

A bounded while: runs a published sub-flux repeatedly, feeding each
round's outputs in as the next round's input, until the break
`conditions` match or `max_loops` (≤ 100) is reached. Outputs `output`,
`rounds`, `condition_met`, `history`.

### `human_input`

Pauses the run and asks a person. Configure the `prompt` and optional
choice `options`; the run parks as `paused` and resumes from the
console, a public site, or `POST /v1/workflows/runs/:id/resume`. The
reply lands in `output`.

### `answer`

Streams the user-facing reply in chat contexts (and records it on the
run). The `answer` template is where you interpolate whatever the flux
computed. A flux may answer several times.

### `end`

Declares the run's final outputs explicitly as key → templated value
mappings — what `/v1` callers and parent fluxes receive.

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
