# flux-coderunner

The execution service behind the code node. Untrusted workflow code runs
here — never inside the app VM.

```
docker compose --profile code up -d coderunner   # standalone
docker compose --profile full up -d              # part of the full stack
```

The app finds it through `CODE_RUNNER_URL` (compose sets
`http://coderunner:8194`). Set `CODE_RUNNER_API_KEY` in `.env` to require
bearer auth on `/run`.

## Languages

| Language | Runtime | Dependencies |
|---|---|---|
| `python3` | CPython 3.12 in a uv-managed venv | per-block, cached by dependency-set hash |
| `javascript` | Deno, **no permissions** (no network/env/write) | exact-version npm packages, deno-cached by dependency-set hash; user code imports them bare (`import dayjs from "dayjs"`) via a generated import map, executed `--cached-only` |

## Pre-installed ML toolkit

Python blocks import these with **no** per-block install (pinned in
`requirements-ml.txt`, reported live at `GET /libraries`):

numpy, pandas, polars, pyarrow, scipy · scikit-learn, xgboost,
lightgbm, statsmodels · nltk, rapidfuzz, tiktoken · matplotlib
(headless), pillow, opencv · beautifulsoup4, lxml, openpyxl, pyyaml,
jsonschema, sympy, python-dateutil · requests, httpx

Deep learning stacks (torch, transformers…) are deliberately not baked
in — CPU wheels add multiple GB. Declare them as block dependencies or
extend `requirements-ml.txt` in your own build.

## Isolation

- unprivileged user, throwaway working directory per run
- rlimits: CPU = timeout, allocations 1 GB (`RUNNER_MEMORY_MB`, via
  RLIMIT_DATA so loaded ML libraries don't count), 16 MB file size,
  256 fds; JS memory capped via V8 `--max-old-space-size`
- BLAS/OpenMP thread pools pinned to 1 (`RUNNER_BLAS_THREADS`) —
  unbounded they size themselves by host cores and starve the limits
- process-group kill on timeout; stdout capped at 64 KB, results at 5 MB
- dependency names validated before ever reaching a shell

- **network split (phase 2)**: python user code executes under
  `unshare` in a fresh network namespace with no interfaces — it cannot
  reach the docker network (postgres, minio, the app). Dependency
  installs run *outside* the namespace (they need PyPI); JS was already
  network-less via Deno's permission model. Probed at boot: on kernels
  without unprivileged user namespaces the runner logs a warning,
  reports `network_isolation: false` on `/health`, and degrades to the
  container boundary. `RUNNER_NETNS=off` disables the probe.

## Testing

With the container running, `python coderunner/test_server.py` executes
the live checks: both languages, dependency install + venv cache, the
error contract, and the sandbox properties (JS network denial, python
netns denial when reported, memory bomb killed by rlimit, timeout kill,
injection-safe dependency names, zero-install ML toolkit).

## Contract

`POST /run` `{language, code, dependencies: [{name, version}], inputs,
timeout_ms}` → `200 {"result": {...}, "stdout": "..."}` or
`422 {"error": "..."}`. Python blocks export `main(**inputs) -> dict`;
JS blocks `export function main(inputs) { return {...} }`.
`GET /health` reports runtime availability.
