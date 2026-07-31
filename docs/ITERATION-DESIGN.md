# Iteration / Loop: design spike (2026-07-31)

## The problem

The reference platform's `iteration` and `loop` nodes give a node a
*sub-graph scope*: child nodes carry a `parent_id`, the canvas nests them
visually inside the iteration frame, and the runner executes the scope once
per list item (`iteration`) or until a break condition (`loop`). Bringing
that model over touches everything we deliberately kept simple:

- **Validator** — the cycle check must become per-scope (a loop scope is
  *allowed* to re-run; edges may not cross scope boundaries except through
  the iteration node itself).
- **Runner** — the walker's single `pool` becomes a stack of scoped pools
  with per-iteration shadowing (`item`, `index`, partial outputs).
- **Canvas** — nested node containment, drag-into-frame, scoped edge
  rules: the largest UI change since the editor was built.
- **DSL** — nested-scope import (`parent_id`/`iteration_id` on children,
  `iteration-start` pseudo-nodes).

## Options

**A. Reference-style inline scopes.** Fidelity to upstream, imports their
iteration DSL directly. Cost: all four surfaces above at once; high risk
without the recorded-trace harness (Docker-blocked) to pin semantics.

**B. Iteration over a sub-flux.** The iteration node references *another
published flux* and runs it once per item. No graph-model change: the
sub-graph is a real graph, already validated, versioned, and editable on
the existing canvas. Item/index are seeded as `{{sys.item}}` /
`{{sys.index}}` (and as `item`/`index` start inputs when declared).
Composition-as-reference also gives reusable sub-flows for free — something
upstream's inline scopes cannot do.

## Decision

**Ship B now** (done, this commit: the `iteration` node), **revisit A when
two unblocks land**: the recorded-trace harness (Docker) to pin upstream's
scope semantics, and canvas nesting. The DSL importer keeps dropping
upstream `iteration`/`loop` scopes with a warning until A exists; B-style
iteration exports under a vendor key (`flux_subflux`) like tool nodes.

### v1 semantics (implemented)

- Config: `variable` (list selector; JSON strings decoded), `workflow_id`
  (the sub-flux), `max_items` (default 50, cap 200), sequential execution.
- Each item runs the sub-flux's **latest published version** through the
  `run_subflux` host capability (workspace-checked). Sub-runs execute
  inline — no `WorkflowRun` rows, no engine events except
  `{:iteration_progress, %{node_id, index, total}}` — keeping the parent
  run's trace clean.
- Recursion guard: sub-fluxes may not start their own sub-fluxes
  (depth cap 1). A sub-flux containing an iteration node fails that item.
- Outputs: `%{"output" => [sub-run outputs...], "count" => n}` —
  feed `{{iter.output}}` into a list-operator or code node downstream.
- Failure of any item fails the node (wire its error branch to tolerate).

### Loop (`while`) — deferred

Upstream's `loop` (repeat scope until break condition / max count) stays
deferred with A: without recorded traces, break-condition semantics are
guesswork, and B-style loops (self-referencing sub-flux) invite unbounded
recursion for marginal value. Bounded retries + error branches already
cover the main practical cases.
