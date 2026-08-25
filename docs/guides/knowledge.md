# Knowledge (RAG)

Datasets turn documents into retrievable knowledge: upload → chunk →
embed → retrieve with citations. Everything lives at
**Console → Knowledge**; fluxes consume datasets through the
`knowledge_retrieval` node, apps through their bound flux, and the
API through `/v1/datasets`.

## Datasets

A dataset binds a document collection to an **embedding model** (the
echo provider's `echo-embed` works keyless for trying things out).
Create one, add documents, watch them index, and **hit-test**
retrieval right on the page before wiring anything.

**Example** — the two-minute loop: create "Handbook" → paste a policy
text → wait for `ready` → type "how many vacation days?" into the
hit-test box → see the matching chunks with scores.

## Getting documents in

- **Upload** — text, Markdown, CSV, JSON, HTML, PDF, Office files
  (extracted via Tika), plus **images** (described and transcribed by
  the workspace vision model) and **audio** (transcribed via the
  provider).
- **Paste** text straight into a named document.
- **URL** — fetched (SSRF-guarded), HTML stripped to text. A
  **depth-1 crawl** pulls same-host linked pages (up to 25); a
  **remembered source** re-fetches nightly, replacing its documents
  in place.
- **Datasources** — Notion, S3-compatible, and Google Drive plugins
  sync external collections on a schedule (auto-sync interval per
  dataset). Provider **instances** let two Notion workspaces or
  several buckets sync side by side.
- **API** — `POST /v1/datasets/:id/document/create-by-text`,
  `create-by-file` (multipart, extraction included), `create-by-url`,
  and `…/update-by-text`. Dataset-scoped `ds-…` tokens confine an
  integration to one dataset.

Same-named re-uploads **replace in place**; the outgoing content
survives as a **restorable revision** (last five per name). Documents
carry **tags** (retrieval can filter by them, templatable in the
node) and **typed metadata** (retrieval filters by JSONB
containment), can be **bulk enabled/disabled/tagged/deleted**, and
can carry an **expiry date** after which they silently leave
retrieval.

## Chunking & indexing

Per-dataset settings, with a **chunk preview** that dry-runs them on
pasted text before you re-index anything:

- **Chunk size / overlap** (200–4000 / 0–500 chars).
- **Markdown-aware splitting** — chunks keep their headings.
- **Parent-child** — small child chunks embed for precise matching;
  retrieval hands the model the enclosing parent section for context.
- **Q&A indexing** — each chunk indexes as model-generated questions
  carrying the original passage (queries match questions better than
  prose; one model call per chunk at index time).

An always-on **embedding cache** means re-indexing never pays for
unchanged text twice, and a per-dataset token meter makes embedding
spend visible.

## Retrieval

Hybrid by default: **vector cosine + Postgres full-text + entity
mentions**, fused by reciprocal-rank fusion (RRF). Tunables:

- **Retrieval mode** — `hybrid`, or single-source `semantic` /
  `keyword`.
- **Semantic weight** — skews hybrid fusion toward vectors (→1.0) or
  keywords/entities (→0.0).
- **Reranking** — an optional rerank model re-orders candidates.
- **Query expansion** — the workspace model rephrases each query and
  all rankings fuse (better recall, one extra model call).
- **Top-k and score threshold** — per dataset; nodes can override
  top-k per call.

**Example** — a `knowledge_retrieval` node with
`dataset_ids: [handbook]`, `query: {{sys.query}}`, `top_k: 4` feeds
`{{node.result}}` into an LLM prompt and `{{node.citations}}` into
the answer; citations flow onto chat replies and deep-link into the
knowledge browser.

## Measuring quality

- **Hit testing** — free-form queries against the live index, scores
  shown.
- **Retrieval evals** — golden `question → expected passage` cases
  scored as hit rate + MRR, so chunking and backend changes are
  measurable. A **cron** on the dataset re-scores unattended and
  notifies on regression.
- **Flagged retrievals** — the ⚑ on any citation in an app monitor
  queues that chunk here; edit the source, disable the chunk, or
  clear the flag. The retrieval-quality loop, closed.

## External knowledge bases

A dataset can be **external**: register a user-hosted retrieval
endpoint (**Connect external**) and queries POST to it —
`{"knowledge_id", "query", "retrieval_setting": {"top_k",
"score_threshold"}}` with an optional Bearer key — expecting
`{"records": [{"content", "score", "title", "metadata"}]}`. Records
ride into answers, citations, hit testing, and evals exactly like
local chunks; the documents stay on your side. The endpoint is
SSRF-guarded and the key stored encrypted.

## Scale & backends

Similarity ranks in-BEAM by default. At corpus scale:

- `FLUX_VECTOR_BACKEND=pgvector` — SQL-side similarity; add
  `FLUX_VECTOR_DIMS` for an HNSW approximate index.
- `FLUX_VECTOR_BACKEND=arango` + `FLUX_ARANGO_URL` (the `rag`
  compose profile) — AQL cosine next to the **entity graph**, which
  upgrades related-entity lookups to real 1–2 hop weighted
  traversals.

## Odds & ends

- **Run a flux over a dataset** — every document becomes a batch row
  (bulk summarize/classify/extract without a CSV); completed batches
  can land outputs back into a dataset, closing the generate→index
  circle.
- **Import/export** — datasets ride the workspace export archive;
  a dataset also exports/imports on its own as JSON.
- **Duplicate dataset** and **guarded embedding-model switch**
  (re-embeds everything, with a confirmation that says so).
