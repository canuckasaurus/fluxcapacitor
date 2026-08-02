# Golden harness

## Phase 1 — replay fixtures (always on)

Finished runs export as replay fixtures from the editor's run history
("Download fixture"). Committed fixtures in
`apps/flux_web/test/support/golden/` re-run on the echo provider in CI;
outputs and per-node status sets are pinned.

## Phase 2 — reference traces (needs a live Reference instance)

`record_reference_traces.py` runs deterministic DSL fixtures on a live
instance of the reference platform and records the full SSE transcripts:

1. Boot the reference stack (its own `docker/` compose; remap
   `EXPOSE_NGINX_PORT` if 80 is taken).
2. `python harness/record_reference_traces.py --base http://localhost:8280`
3. Commit the traces it writes to
   `apps/flux/test/support/reference_traces/`.

`reference_trace_test.exs` (apps/flux) then replays each trace's DSL on
our engine and asserts the reference's final outputs and executed-node
set are reproduced. Only deterministic fixtures participate — no LLM,
no external network — so the comparison is exact, not fuzzy.

The raw SSE transcript (event order, payload shapes, timings) is kept in
each trace file for the /v1 SSE-vocabulary comparison as that surface
grows.
