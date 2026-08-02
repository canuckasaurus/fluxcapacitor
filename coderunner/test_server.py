"""Live checks against a running flux-coderunner container.

    docker compose --profile code up -d coderunner
    python coderunner/test_server.py [base_url]

Not a unit suite: these hit the real service and verify the sandbox
properties (network denial, memory/timeout kills, dependency-name
validation) plus the pre-installed ML toolkit — the things a mock can't
prove.
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CODERUNNER_URL", "http://localhost:8194")).rstrip("/")
URL = BASE + "/run"


def run(spec, expect_status=200):
    req = urllib.request.Request(
        URL, json.dumps(spec).encode(), {"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


passed = []

# 1. plain python
status, body = run({
    "language": "python3",
    "code": "def main(a, b):\n    print('side channel')\n    return {'sum': a + b}",
    "inputs": {"a": 2, "b": 40},
    "timeout_ms": 10000,
})
assert status == 200 and body["result"] == {"sum": 42}, body
assert "side channel" in body["stdout"], body
passed.append("python basic + stdout")

# 2. python with a real dependency (installed via uv, cached venv)
status, body = run({
    "language": "python3",
    "code": "import dateutil.parser\ndef main(when):\n    d = dateutil.parser.parse(when)\n    return {'year': d.year}",
    "dependencies": [{"name": "python-dateutil", "version": "2.9.0"}],
    "inputs": {"when": "Oct 26 1985"},
    "timeout_ms": 60000,
})
assert status == 200 and body["result"] == {"year": 1985}, body
passed.append("python dependency via uv")

# 3. second call hits the cached venv (should be fast; just correctness here)
status, body = run({
    "language": "python3",
    "code": "import dateutil\ndef main():\n    return {'cached': True}",
    "dependencies": [{"name": "python-dateutil", "version": "2.9.0"}],
    "inputs": {},
    "timeout_ms": 15000,
})
assert status == 200 and body["result"] == {"cached": True}, body
passed.append("venv cache hit")

# 4. javascript via deno
status, body = run({
    "language": "javascript",
    "code": "export function main({x}) { console.log('js log'); return {double: x * 2}; }",
    "inputs": {"x": 21},
    "timeout_ms": 20000,
})
assert status == 200 and body["result"] == {"double": 42}, body
assert "js log" in body["stdout"], body
passed.append("javascript basic + stdout")

# 4b. javascript with an npm dependency (deno-cached, exact version)
status, body = run({
    "language": "javascript",
    "code": (
        "import dayjs from \"dayjs\";\n"
        "export function main({when}) { return {year: dayjs(when).year()}; }"
    ),
    "dependencies": [{"name": "dayjs", "version": "1.11.13"}],
    "inputs": {"when": "1985-10-26"},
    "timeout_ms": 60000,
})
assert status == 200 and body["result"] == {"year": 1985}, body
passed.append("javascript npm dependency via deno cache")

# 5. non-dict return -> honest error
status, body = run({
    "language": "python3",
    "code": "def main():\n    return [1, 2]",
    "inputs": {},
    "timeout_ms": 10000,
})
assert status == 422 and "dict" in body["error"], (status, body)
passed.append("non-dict rejected")

# 6. timeout enforced
status, body = run({
    "language": "python3",
    "code": "import time\ndef main():\n    time.sleep(30)\n    return {}",
    "inputs": {},
    "timeout_ms": 3000,
})
assert status == 422 and "timed out" in body["error"], (status, body)
passed.append("timeout kill")

# 7. exception surfaces
status, body = run({
    "language": "python3",
    "code": "def main():\n    raise ValueError('boom')",
    "inputs": {},
    "timeout_ms": 10000,
})
assert status == 422 and "boom" in body["error"], (status, body)
passed.append("exception surfaced")

# 8. deno stays sandboxed: network access must fail
status, body = run({
    "language": "javascript",
    "code": "export async function main() { const r = await fetch('http://postgres:5432'); return {leak: true}; }",
    "inputs": {},
    "timeout_ms": 15000,
})
assert status == 422, (status, body)
passed.append("js network blocked")

# 8b. phase 2: python network isolation — asserted when the runner
# reports it (kernels without unprivileged userns fall back to phase 1)
with urllib.request.urlopen(BASE + "/health", timeout=10) as resp:
    health = json.loads(resp.read())

if health.get("network_isolation"):
    status, body = run({
        "language": "python3",
        "code": (
            "import socket\n"
            "def main():\n"
            "    socket.create_connection((\"postgres\", 5432), timeout=5)\n"
            "    return {\"leak\": True}"
        ),
        "inputs": {},
        "timeout_ms": 20000,
    })
    assert status == 422, (status, body)
    passed.append("python network blocked (netns)")
else:
    print("SKIP: python netns isolation (runner reports network_isolation=false)")

# 9. python memory bomb dies from rlimit, server survives
status, body = run({
    "language": "python3",
    "code": "def main():\n    x = 'a' * (2 * 1024 * 1024 * 1024)\n    return {'n': len(x)}",
    "inputs": {},
    "timeout_ms": 20000,
})
assert status == 422, (status, body)
passed.append("memory limit enforced")

# 10. bad dependency name rejected before shelling out
status, body = run({
    "language": "python3",
    "code": "def main():\n    return {}",
    "dependencies": [{"name": "evil; rm -rf /", "version": "1"}],
    "inputs": {},
    "timeout_ms": 10000,
})
assert status == 422 and "invalid dependency" in body["error"], (status, body)
passed.append("dependency name validation")

# 11. the pre-installed ML toolkit imports and works with zero deps
status, body = run({
    "language": "python3",
    "code": (
        "import numpy as np\n"
        "import pandas as pd\n"
        "import sklearn, scipy, xgboost, lightgbm, statsmodels, polars, matplotlib\n"
        "from sklearn.linear_model import LinearRegression\n"
        "def main(n):\n"
        "    x = np.arange(n).reshape(-1, 1)\n"
        "    model = LinearRegression().fit(x, 2 * x.ravel() + 1)\n"
        "    return {'slope': round(float(model.coef_[0]), 4), 'rows': len(pd.DataFrame({'x': x.ravel()}))}\n"
    ),
    "inputs": {"n": 88},
    "timeout_ms": 90000,
})
assert status == 200 and body["result"] == {"slope": 2.0, "rows": 88}, body
passed.append("ML toolkit zero-install")

for p in passed:
    print("PASS:", p)
print(f"\n{len(passed)} live coderunner checks passed")
