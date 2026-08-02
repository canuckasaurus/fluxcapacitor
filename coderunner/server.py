"""flux-coderunner: the sandboxed execution service behind the code node.

Contract (matches Flux.CodeRunner.Sandbox):

    POST /run   {language, code, dependencies: [{name, version}],
                 inputs: {...}, timeout_ms}
        200 {"result": {...}, "stdout": "..."}   on success
        422 {"error": "..."}                     on any failure
    GET /health {"status": "up", ...}

Auth: when CODE_RUNNER_API_KEY is set, /run requires
`Authorization: Bearer <key>`.

Languages:
  * python3    — per-block dependencies installed into a uv-managed venv,
                 cached by the hash of the dependency set. User code runs
                 as a subprocess with rlimits (CPU, memory, fds, file
                 size, procs) in a throwaway directory.
  * javascript — Deno with NO permissions beyond reading its own
                 scratch directory: no network, no env, no writes.
                 Dependencies are not supported yet.

Phase 1 isolation is rlimits + throwaway dirs + an unprivileged user;
the container itself is the outer boundary. Phase 2 adds a network
namespace split so user code cannot reach the internal network.

Stdlib only, on purpose: the service that runs untrusted code should
have the smallest possible supply chain.
"""

import hashlib
import hmac
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("RUNNER_PORT", "8194"))
API_KEY = os.environ.get("CODE_RUNNER_API_KEY") or ""
VENV_ROOT = os.environ.get("RUNNER_VENV_ROOT", "/cache/venvs")
MEMORY_MB = int(os.environ.get("RUNNER_MEMORY_MB", "512"))
MAX_TIMEOUT_MS = int(os.environ.get("RUNNER_MAX_TIMEOUT_MS", "120000"))
MAX_BODY_BYTES = 2 * 1024 * 1024
MAX_STDOUT_BYTES = 64 * 1024
MAX_RESULT_BYTES = 5 * 1024 * 1024
MAX_DEPENDENCIES = 20

PY_WRAPPER = """\
import json, sys, io, contextlib
sys.path.insert(0, ".")
import usercode
with open("inputs.json", "r", encoding="utf-8") as f:
    inputs = json.load(f)
buffer = io.StringIO()
with contextlib.redirect_stdout(buffer):
    result = usercode.main(**inputs)
if not isinstance(result, dict):
    print("__FLUX_NOT_DICT__", file=sys.stderr)
    sys.exit(3)
with open("__result__.json", "w", encoding="utf-8") as f:
    json.dump(result, f)
sys.stdout.write(buffer.getvalue())
"""

JS_WRAPPER = """\
import { main } from "./usercode.js";
const inputs = JSON.parse(Deno.readTextFileSync("inputs.json"));
const result = await main(inputs);
const isPlainObject =
  typeof result === "object" && result !== null && !Array.isArray(result);
if (!isPlainObject) {
  console.error("__FLUX_NOT_DICT__");
  Deno.exit(3);
}
console.log("__FLUX_RESULT__" + JSON.stringify(result));
"""

_venv_locks: dict[str, threading.Lock] = {}
_venv_locks_guard = threading.Lock()


class RunError(Exception):
    """User-visible execution failure -> 422 {"error": str(exc)}."""


def run_subprocess(argv, cwd, timeout_ms, cpu_seconds, limit_as=True):
    def preexec():
        import resource

        if limit_as:
            # V8 (Deno) reserves TBs of virtual address space, so RLIMIT_AS
            # only applies to python; JS is capped via --max-old-space-size.
            mem = MEMORY_MB * 1024 * 1024
            resource.setrlimit(resource.RLIMIT_AS, (mem, mem))
        resource.setrlimit(resource.RLIMIT_NPROC, (128, 128))
        resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
        resource.setrlimit(resource.RLIMIT_FSIZE, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds))
        os.setsid()

    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": cwd,
        "LANG": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
        "NO_COLOR": "1",
    }

    proc = subprocess.Popen(
        argv,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        preexec_fn=preexec,
    )
    try:
        output, _ = proc.communicate(timeout=timeout_ms / 1000)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        raise RunError(f"code execution timed out after {timeout_ms} ms")

    text = output.decode("utf-8", errors="replace")
    if len(text) > MAX_STDOUT_BYTES:
        text = text[:MAX_STDOUT_BYTES] + "\n[output truncated]"
    return proc.returncode, text


def normalize_dependencies(raw):
    deps = []
    for entry in raw or []:
        name = str(entry.get("name") or "").strip()
        version = str(entry.get("version") or "").strip()
        if not name:
            continue
        ok = all(c.isalnum() or c in "._-[]" for c in name)
        ok = ok and all(c.isalnum() or c in "._*+!<>=~," for c in version)
        if not ok or len(name) > 100 or len(version) > 50:
            raise RunError(f"invalid dependency: {name!r} {version!r}")
        deps.append(f"{name}=={version}" if version else name)
    if len(deps) > MAX_DEPENDENCIES:
        raise RunError(f"too many dependencies (max {MAX_DEPENDENCIES})")
    return sorted(deps)


def venv_python(deps):
    """A cached venv for this dependency set; the system python for none."""
    if not deps:
        return sys.executable

    key = hashlib.sha256("\n".join(deps).encode()).hexdigest()[:24]
    venv_dir = os.path.join(VENV_ROOT, key)
    python = os.path.join(venv_dir, "bin", "python")
    ready = os.path.join(venv_dir, ".ready")

    with _venv_locks_guard:
        lock = _venv_locks.setdefault(key, threading.Lock())

    with lock:
        if os.path.exists(ready):
            return python
        shutil.rmtree(venv_dir, ignore_errors=True)
        try:
            subprocess.run(
                ["uv", "venv", venv_dir, "--python", sys.executable],
                check=True, capture_output=True, timeout=120,
            )
            install = subprocess.run(
                ["uv", "pip", "install", "--python", python, *deps],
                capture_output=True, timeout=300,
            )
            if install.returncode != 0:
                detail = install.stderr.decode("utf-8", errors="replace")[-500:]
                raise RunError(f"dependency install failed: {detail}")
        except subprocess.TimeoutExpired:
            raise RunError("dependency install timed out")
        except FileNotFoundError:
            raise RunError("uv is not installed in the runner image")
        except subprocess.CalledProcessError as exc:
            detail = exc.stderr.decode("utf-8", errors="replace")[-500:]
            raise RunError(f"could not create a venv: {detail}")
        open(ready, "w").close()
        return python


def run_python(spec, workdir, timeout_ms):
    deps = normalize_dependencies(spec.get("dependencies"))
    python = venv_python(deps)

    with open(os.path.join(workdir, "usercode.py"), "w", encoding="utf-8") as f:
        f.write(spec.get("code") or "")
    with open(os.path.join(workdir, "inputs.json"), "w", encoding="utf-8") as f:
        json.dump(spec.get("inputs") or {}, f)
    with open(os.path.join(workdir, "wrapper.py"), "w", encoding="utf-8") as f:
        f.write(PY_WRAPPER)

    cpu = max(2, timeout_ms // 1000 + 1)
    code, output = run_subprocess([python, "wrapper.py"], workdir, timeout_ms, cpu)

    if code == 3:
        raise RunError("the code block's main() must return a dict/object")
    if code != 0:
        raise RunError(f"exit {code}: {output[:1000]}")

    result_path = os.path.join(workdir, "__result__.json")
    if os.path.getsize(result_path) > MAX_RESULT_BYTES:
        raise RunError("the result object is too large (5 MB max)")
    with open(result_path, encoding="utf-8") as f:
        return json.load(f), output


def run_javascript(spec, workdir, timeout_ms):
    if normalize_dependencies(spec.get("dependencies")):
        raise RunError("javascript blocks do not support dependencies yet")

    with open(os.path.join(workdir, "usercode.js"), "w", encoding="utf-8") as f:
        f.write(spec.get("code") or "")
    with open(os.path.join(workdir, "inputs.json"), "w", encoding="utf-8") as f:
        json.dump(spec.get("inputs") or {}, f)
    with open(os.path.join(workdir, "wrapper.js"), "w", encoding="utf-8") as f:
        f.write(JS_WRAPPER)

    argv = [
        "deno", "run", "--quiet", "--no-prompt", "--no-remote",
        f"--v8-flags=--max-old-space-size={MEMORY_MB}",
        f"--allow-read={workdir}", "wrapper.js",
    ]
    cpu = max(2, timeout_ms // 1000 + 1)
    code, output = run_subprocess(argv, workdir, timeout_ms, cpu, limit_as=False)

    if code == 3 or "__FLUX_NOT_DICT__" in output:
        raise RunError("the code block's main() must return a dict/object")
    if code != 0:
        raise RunError(f"exit {code}: {output[:1000]}")

    lines = output.splitlines()
    marker = next((l for l in reversed(lines) if l.startswith("__FLUX_RESULT__")), None)
    if marker is None:
        raise RunError("the code block produced no result")
    result = json.loads(marker[len("__FLUX_RESULT__"):])
    stdout = "\n".join(l for l in lines if not l.startswith("__FLUX_RESULT__"))
    return result, stdout


RUNNERS = {"python3": run_python, "javascript": run_javascript}


def execute(spec):
    language = str(spec.get("language") or "python3")
    runner = RUNNERS.get(language)
    if runner is None:
        supported = ", ".join(sorted(RUNNERS))
        raise RunError(f"unsupported language {language!r} (supported: {supported})")
    if not str(spec.get("code") or "").strip():
        raise RunError("the code block is empty")

    timeout_ms = min(int(spec.get("timeout_ms") or 30000), MAX_TIMEOUT_MS)
    workdir = tempfile.mkdtemp(prefix="flux-run-")
    try:
        result, stdout = runner(spec, workdir, timeout_ms)
        return {"result": result, "stdout": stdout}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            deno = shutil.which("deno") is not None
            uv = shutil.which("uv") is not None
            self.reply(200, {"status": "up", "deno": deno, "uv": uv})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/run":
            return self.reply(404, {"error": "not found"})

        if API_KEY:
            header = self.headers.get("Authorization") or ""
            expected = "Bearer " + API_KEY
            if not hmac.compare_digest(header.encode(), expected.encode()):
                return self.reply(401, {"error": "invalid api key"})

        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            return self.reply(413, {"error": "request too large"})

        try:
            spec = json.loads(self.rfile.read(length))
            if not isinstance(spec, dict):
                raise ValueError("spec must be an object")
        except (ValueError, json.JSONDecodeError) as exc:
            return self.reply(400, {"error": f"bad request: {exc}"})

        try:
            self.reply(200, execute(spec))
        except RunError as exc:
            self.reply(422, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001 — never crash the worker thread
            self.reply(422, {"error": f"runner failure: {exc.__class__.__name__}: {exc}"})


def main():
    os.makedirs(VENV_ROOT, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    auth = "on" if API_KEY else "OFF"
    print(f"flux-coderunner listening on :{PORT} (auth {auth})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
