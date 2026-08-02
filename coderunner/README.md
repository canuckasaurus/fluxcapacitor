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
| `javascript` | Deno, **no permissions** (no network/env/write) | not yet |

## Isolation (phase 1)

- unprivileged user, throwaway working directory per run
- rlimits: CPU = timeout, memory 512 MB (`RUNNER_MEMORY_MB`), 16 MB file
  size, 256 fds; JS memory capped via V8 `--max-old-space-size`
- process-group kill on timeout; stdout capped at 64 KB, results at 5 MB
- dependency names validated before ever reaching a shell

The container boundary is the outer wall: python subprocesses can still
reach the docker network. Phase 2 adds a network-namespace split so user
code gets no network at all.

## Contract

`POST /run` `{language, code, dependencies: [{name, version}], inputs,
timeout_ms}` → `200 {"result": {...}, "stdout": "..."}` or
`422 {"error": "..."}`. Python blocks export `main(**inputs) -> dict`;
JS blocks `export function main(inputs) { return {...} }`.
`GET /health` reports runtime availability.
