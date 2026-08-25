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
| `agent` | Autonomous tool loop with an iteration cap | provider+model, `instructions`, `query`, `max_iterations`, `tools`, `output_schema`, `enable_drive`, `approval_tools`, deferred tools | `text`, `output`, `status`, `iterations`, `tool_calls`, `files` |
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
| `iteration` | Runs a published sub-flux once per list item | `variable`, `workflow_id`, `max_items`, `subflux_version` | `output` (list), `count` |
| `loop` | Bounded while over a published sub-flux | `workflow_id`, `initial`, `max_loops`, break `conditions`, `subflux_version` | `output`, `rounds`, `condition_met`, `history` |
| `human_input` | Pauses the run for a person | `prompt`, `options` | `output` (the reply, after resume) |
| `labeling` | Queues a task in a labeling project and pauses until it's labeled | `project_id`, `data` (name/value rows) | `choice` / `choices` / `text`, `output` |
| `document` | Fills a Word doc template into a downloadable file | `template_id`, `output_name` | `url`, `name`, `file_id`, `size` |
| `file_output` | Writes templated content to a downloadable file (HTML, PDF, Markdown, text, CSV, JSON) | `format`, `content`, `output_name` | `url`, `name`, `file_id`, `size`, `format` |
| `interview` | Pauses the run and asks a stored question set as one form | `interview_id`, `intro` | one key per question + `output` |
| `answer` | Streams/records the user-facing answer | `answer` template | `answer` |
| `end` | Maps run outputs explicitly | `outputs` (key/value) | the mapped keys |

## Nodes in detail

### `start`

Every flux begins here. Declare the run's input variables
(name/label/type/required); the node validates incoming inputs against
them and exposes each as `{{start.<name>}}`. Chatflows also get
`{{sys.query}}` and `{{sys.history}}` without declaring anything.

**Example**: declare `ticket` (paragraph, required) and `priority`
(select: low/high) — API callers then POST
`{"inputs": {"ticket": "…", "priority": "high"}}` and downstream
nodes read `{{start.ticket}}`.

### `llm`

Calls a chat model and streams the reply. Pick a provider+model, write
a `system_prompt` and `prompt` (both templated), optionally attach an
`output_schema` for structured JSON output (`{{node.output}}`), a
`vision_variable` (a file variable holding an uploaded image — it rides
the user message to vision-capable models), and a
fallback model that takes over when the primary errors. Outputs `text`,
`usage`, `model_used`, `fallback_used`.

**Example**: prompt `Summarize in three bullets:\n{{start.ticket}}`
with an output schema `{"summary": "string", "sentiment": "string"}`
— downstream nodes read `{{llm.output.summary}}` instead of parsing
prose.

### `agent`

An autonomous tool-calling loop: the model decides which of the
attached toolsets to call, up to `max_iterations` rounds.
`enable_drive` gives it a sandboxed scratch drive (`files` output);
`output_schema` forces a final structured answer; deferred tools pause
the run for outside execution. Tools listed in `approval_tools` pause
the run for a **human approve/deny** before executing — approval runs
the call and the loop continues in the same run; denial feeds the model
a refusal it can adapt to. Outputs `text`, `output`, `status`,
`iterations`, `tool_calls`.

**Example**: instructions `Research the company and draft an intro
email`, tools = a search toolset + the CRM toolset,
`max_iterations: 6`, `approval_tools: ["crm_create_contact"]` — the
agent searches freely but pauses for a human before touching the CRM.

### `if_else`

A case chain (if / elif / else). Each case is a condition set over
variable-pool references; the run leaves on the matching case's handle,
or `false` when nothing matches. Several edges on one handle fan out
into parallel branches.

**Example**: case 1 `{{classifier.class}} equals "refund"` → the
refund branch; case 2 `{{start.amount}} greater than 1000` → the
escalation branch; `false` → the default answer.

### `question_classifier`

Forces an LLM to sort the input into one of your `classes`; the run
continues on that class's handle. Use it to route support questions,
detect intent, or triage. Outputs `class`.

**Example**: classes `billing`, `technical`, `feedback` over
`{{sys.query}}` — three handles, three specialist branches, and
`{{classifier.class}}` available downstream for logging.

### `parameter_extractor`

Forces an LLM to extract the `parameters` you declare (name, type,
description, required) from free text into structured pool values —
one output key per parameter.

**Example**: parameters `name` (string), `order_id` (string,
required), `refund_amount` (number) over `{{start.email_body}}` —
downstream nodes read `{{extractor.order_id}}` directly.

### `template`

Renders text from the variable pool. The `simple` engine substitutes
`{{refs}}`; the `jinja` engine adds filters (`{{ name|upper }}`),
`{% if %}` chains, and `{% for %}` loops. Or pick a saved doc template
from the workspace library. Outputs `output`.

**Example** (jinja):
`{% for hit in retrieval.citations %}- {{ hit.document }}{% endfor %}`
renders a source list from a retrieval node's citations.

### `variable_aggregator`

Takes the first non-empty of several source references — the way to
merge branches (e.g. either classifier path) back into one variable.
Outputs `output`.

**Example**: sources `{{billing_llm.text}}`, `{{technical_llm.text}}`
— whichever branch ran fills `{{merge.output}}` for the answer node.

### `variable_assigner`

Writes values into `{{conversation.*}}` variables that persist across a
chatflow conversation — remember a user's name, accumulate state,
build multi-turn forms.

**Example**: assign `customer_name = {{extractor.name}}` on the first
turn; every later turn's prompt can greet with
`{{conversation.customer_name}}`.

### `list_operator`

Filters, sorts, and slices a list from the pool without code. Outputs
the transformed `output` plus `count`.

**Example**: over `{{http.body.items}}` — filter `status == "open"`,
sort by `created_at` descending, take the first 5.

### `code`

Runs a code block through the flux-coderunner service (`python3` or
`javascript`; `CODE_RUNNER_URL`, the `code` compose profile). Python
blocks export `main(**inputs) -> dict`; the dict's keys become outputs,
plus `stdout`. The **ML toolkit is pre-installed** — numpy, pandas,
polars, scipy, scikit-learn, xgboost, lightgbm, statsmodels, nltk,
matplotlib, pillow, opencv, requests and more import with no dependency
entry; anything else installs per block through a cached venv.
JavaScript runs in permissionless Deno (no network, env, or writes
except its own `./artifacts/`); exact-version npm dependencies are
pre-cached and imported bare. Python user code additionally runs in an
**empty network namespace**.

Two file lanes close the **train → serve** loop:

* files the code saves under `./artifacts/` come back as run-output
  files (the `files` output holds their ids and download URLs) — train
  a model with the pre-installed toolkit and persist it;
* `attachments` (`[{file_id, name}]`, templatable) places previously
  stored run-output files next to the code before it runs — load that
  model and predict in a later flux.

**Example** (python):

```python
def main(ticket: str) -> dict:
    import joblib
    model = joblib.load("./attachments/intent-v3.pkl")
    return {"intent": model.predict([ticket])[0]}
```

With `attachments: [{"file_id": "registry:ticket-intent", "name":
"intent-v3.pkl"}]` the registry's latest version loads at run time.

### `http_request`

Calls an external HTTP API — method, URL, headers, and body are all
templated, and the URL is SSRF-guarded. Outputs `status`, `body`
(parsed JSON when possible), and raw `text`.

**Example**: `POST https://api.example.com/tickets` with body
`{"title": "{{llm.output.summary}}", "priority":
"{{start.priority}}"}` and an `Authorization: Bearer {{env.API_KEY}}`
header — read `{{http.body.id}}` downstream, route the `error` handle
to a fallback branch.

### `tool`

Calls one operation of an imported OpenAPI toolset or an installed tool
plugin, with templated arguments. Outputs `status`, `body`, `text`.

Toolsets come from **Console → Tools**: paste any OpenAPI spec (JSON
or YAML), or import one from a URL (SSRF-guarded) — every operation in
the spec becomes a callable tool. Each toolset stores its auth
(API keys, headers) encrypted with write-only secrets, plus private
variables you can template into requests. The same toolsets are
attachable to agent nodes, several at once, mixed with plugin and MCP
tools.

### `knowledge_retrieval`

Hybrid (keyword + vector + entity) retrieval across the datasets you
check, using RRF ranking. `top_k` left blank defers to each dataset's
own retrieval settings. Outputs `result` (joined passages),
`citations`, `count`. See the [Knowledge guide](knowledge.md) for
chunking, retrieval modes, and quality measurement.

**Example**: query `{{sys.query}}`, tag filter
`{{start.category}}` — the LLM prompt interpolates
`Context:\n{{retrieval.result}}` and the answer template appends
sources from `{{retrieval.citations}}`.

### `subflux`

Calls another published flux as one node: `inputs` maps the sub-flux's
start variables from templates, and its end outputs become this node's
outputs (`{{node.<key>}}`). Pinnable to a version; one level deep, same
as iteration and loop. The call-site companion to extract-to-flux.

**Example**: a shared "summarize" flux (start: `text` → llm → end:
`summary`) called with `inputs: {"text": "{{start.ticket}}"}` —
read `{{subflux.summary}}`, pin `subflux_version: "v3"` for
reproducibility.

### `delay`

Waits before continuing: `seconds` (fractions allowed) or `until` (an
ISO-8601 timestamp), both template-capable, capped at 300 seconds —
pacing for rate-limited APIs and cooling-off steps. Anything longer
belongs on a schedule trigger, and the error says so. Outputs
`waited_ms`.

**Example**: `seconds: 1.5` between two HTTP nodes keeps a
40-req/min API happy inside an iteration.

### `document_extractor`

Turns an uploaded file (from a file-type start variable) into plain
text — native for text/HTML formats. Outputs `text`, `name`, `size`.

**Example**: start variable `contract` (file) →
`document_extractor.variable: {{start.contract}}` → the LLM prompt
reads `{{extract.text}}`.

### `iteration`

Runs a *published* sub-flux once per item of a list, in order, and
collects the results. The sub-flux sees `{{sys.item}}` /
`{{sys.index}}`. `max_items` caps the fan-out. Outputs `output` (list)
and `count`. By default the *latest* published version runs;
`subflux_version` (`"v3"` or `3`) pins a specific one so composed
fluxes stay reproducible while the sub-flux evolves.

**Example**: `variable: {{list.output}}`, `max_items: 20` over a
"score one lead" sub-flux — `{{iterate.output}}` is the list of each
item's end outputs, in order.

### `loop`

A bounded while: runs a published sub-flux repeatedly, feeding each
round's outputs in as the next round's input, until the break
`conditions` match or `max_loops` (≤ 100) is reached. Outputs `output`,
`rounds`, `condition_met`, `history`. Accepts the same
`subflux_version` pin as iteration.

**Example**: a "refine draft" sub-flux looping until
`{{loop.score}} greater than 8` or `max_loops: 5` — each round sees
the previous round's draft and score as its inputs.

### `human_input`

Pauses the run and asks a person. Configure the `prompt` and optional
choice `options`; the run parks as `paused` and resumes from the
console, a public site, or `POST /v1/workflows/runs/:id/resume`. The
reply lands in `output`.

**Example**: prompt `Approve this draft?\n{{llm.text}}` with options
`approve` / `revise` — an `if_else` on `{{review.output}}` routes
publication or another editing pass.

### `labeling`

Queues a task into a **labeling project** (`/console/labeling`) and
pauses the run until someone labels it — human review as a first-class
graph step. The `data` rows (name → templated value) become the task's
payload, so labelers see exactly the context you give them. Submitting
the label resumes the run with the project's answer shape as outputs:
`choice` (single-select), `choices` (multi-select), or `text`, plus
`output`. Skipped tasks leave the run parked. Labels captured this way
also stay in the project for JSONL export — review and training data
from the same click.

**Example**: `data: [{"name": "Ticket", "value": "{{start.ticket}}"},
{"name": "Model says", "value": "{{classifier.class}}"}]` into a
single-select "Ticket intent" project — the labeler's pick resumes
the run as `{{label.choice}}`.

### `document`

Fills a **Word doc template** (uploaded under Doc templates) with the
run's variables and stores the finished file. Templates are canonical:
content never changes after upload, so a node pinned to a template
renders exactly what was reviewed — revisions are forks with lineage,
and you rebind the node when ready. Stores .docx — the docassemble-style
assembly step. Author templates in Word with `{{ tags }}` inline,
`{%p if … %}` / `{%p endfor %}` paragraphs, and `{%tr for … %}` table
rows. `output_name` templates the filename. Outputs `url` (a tokenized
download link that works from the console, public sites, and the API),
`name`, `file_id`, and `size`.

**Example**: an "engagement letter" template with
`{{ client_name }}` tags, `output_name: letter-{{start.client}}` —
the answer node links `{{doc.url}}`.

### `file_output`

Writes templated `content` to a **downloadable run file** — the
report-writer counterpart of the document node, no Word template
required. Formats: `html`, `pdf`, `markdown`, `text`, `csv`, `json`.
HTML and PDF content is wrapped into a styled full page automatically
(unless it already is one); PDF converts through the same Gotenberg
converter as the document node (`FLUX_PDF_URL`, fails honestly when
unset). `output_name` templates the filename stem. Outputs `url` (a
tokenized download link), `name`, `file_id`, `size`, and `format`.

**Example**: `format: pdf`, content
`# Weekly report\n\n{{llm.text}}`, `output_name:
report-{{start.week}}` — a styled PDF lands on the Files page and
`{{report.url}}` downloads it.

### `interview`

Pauses the run and asks a **stored interview** (a reusable question set
from `/console/interviews`) as one multi-field form — the multi-question
sibling of `human_input`. Questions snapshot into the pause, so the form
survives definition edits mid-pause. Answers are validated (required,
number, select membership, boolean) and land as one output per question
plus `output` (the whole map). Works from the console, public flux
sites, and `POST /v1/workflows/runs/:id/resume` with `{"inputs": {…}}`.

**Example**: an "intake" interview (name, matter type, budget) — the
run pauses with the whole form, and resumes with
`{{intake.name}}`, `{{intake.matter_type}}`, `{{intake.budget}}`.

### `answer`

Streams the user-facing reply in chat contexts (and records it on the
run). The `answer` template is where you interpolate whatever the flux
computed. A flux may answer several times.

**Example**: `{{llm.text}}\n\n_Sources: {{retrieval.citations}}_` —
the model's reply with a source footer.

### `end`

Declares the run's final outputs explicitly as key → templated value
mappings — what `/v1` callers and parent fluxes receive.

**Example**: `summary → {{llm.output.summary}}`, `intent →
{{classifier.class}}` — the run's API response carries exactly those
two keys.

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
