"""Golden harness phase 2: record run traces from a live Reference instance.

Boot the reference platform's docker stack (any recent version), then:

    python harness/record_reference_traces.py [--base http://localhost:8280]

For each deterministic DSL fixture this script imports the workflow
through the console API, publishes it, mints an app API key, executes it
with `response_mode: streaming`, and saves the full SSE transcript plus
the distilled outcome to apps/flux/test/support/reference_traces/.
The recorded traces then drive reference_trace_test.exs, which replays
the same DSL on our engine and pins the outcomes against each other.

Stdlib only; no credentials beyond the throwaway admin it creates.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "apps", "flux", "test", "support", "fixtures", "dsl")
TRACES = os.path.join(REPO, "apps", "flux", "test", "support", "reference_traces")

ADMIN = {"email": "harness@example.com", "name": "Harness", "password": "FluxHarness88mph1"}

# Deterministic fixtures only: no LLM, no external network. Each entry
# may record several input variants (branch coverage).
RECORDINGS = [
    {
        "fixture": "conditional_hello_branching_workflow.yml",
        "variants": [
            {"name": "true_branch", "inputs": {"query": "well hello there"}},
            {"name": "false_branch", "inputs": {"query": "goodbye"}},
        ],
    },
    {
        "fixture": "conditional_parallel_code_execution_workflow.yml",
        "variants": [
            {"name": "switch_1", "inputs": {"switch": 1}},
            {"name": "switch_0", "inputs": {"switch": 0}},
        ],
    },
]


def request(method, url, token=None, payload=None, timeout=60):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {"raw": body.decode(errors="replace")}


def ensure_admin(base):
    status, body = request("GET", f"{base}/console/api/setup")
    if body.get("step") != "finished":
        status, body = request("POST", f"{base}/console/api/setup", payload=ADMIN)
        if status not in (200, 201):
            sys.exit(f"setup failed ({status}): {body}")
        print("admin account created")


def login(base):
    status, body = request(
        "POST",
        f"{base}/console/api/login",
        payload={"email": ADMIN["email"], "password": ADMIN["password"], "remember_me": True},
    )
    token = (body.get("data") or {}).get("access_token") or body.get("access_token")
    if status != 200 or not token:
        sys.exit(f"login failed ({status}): {body}")
    return token


def import_dsl(base, token, yaml_content):
    status, body = request(
        "POST",
        f"{base}/console/api/apps/imports",
        token,
        {"mode": "yaml-content", "yaml_content": yaml_content},
    )
    app_id = body.get("app_id") or (body.get("data") or {}).get("app_id")
    if status not in (200, 201) or not app_id:
        sys.exit(f"DSL import failed ({status}): {body}")
    return app_id


def publish(base, token, app_id):
    status, body = request(
        "POST", f"{base}/console/api/apps/{app_id}/workflows/publish", token, {}
    )
    if status not in (200, 201):
        sys.exit(f"publish failed ({status}): {body}")


def api_key(base, token, app_id):
    status, body = request("POST", f"{base}/console/api/apps/{app_id}/api-keys", token, {})
    key = body.get("token")
    if status not in (200, 201) or not key:
        sys.exit(f"api key failed ({status}): {body}")
    return key


def run_streaming(base, key, inputs):
    """POST /v1/workflows/run capturing the raw SSE transcript."""
    payload = json.dumps(
        {"inputs": inputs, "response_mode": "streaming", "user": "harness"}
    ).encode()
    req = urllib.request.Request(f"{base}/v1/workflows/run", payload, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {key}")

    raw, events = [], []
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=300) as resp:
        for line_bytes in resp:
            line = line_bytes.decode("utf-8", errors="replace").rstrip("\n\r")
            if not line:
                continue
            raw.append({"t_ms": round((time.monotonic() - started) * 1000), "line": line})
            if line.startswith("data: "):
                try:
                    events.append(json.loads(line[len("data: "):]))
                except json.JSONDecodeError:
                    pass
    return raw, events


def distill(events):
    """The comparison surface: final status/outputs + per-node results."""
    final = {"status": None, "outputs": None, "error": None, "nodes": []}
    for event in events:
        kind = event.get("event")
        data = event.get("data") or {}
        if kind == "node_finished":
            final["nodes"].append(
                {
                    "node_id": str(data.get("node_id")),
                    "node_type": data.get("node_type"),
                    "title": data.get("title"),
                    "status": data.get("status"),
                    "outputs": data.get("outputs"),
                }
            )
        elif kind == "workflow_finished":
            final["status"] = data.get("status")
            final["outputs"] = data.get("outputs")
            final["error"] = data.get("error")
    return final


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://localhost:8280")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    ensure_admin(base)
    token = login(base)
    os.makedirs(TRACES, exist_ok=True)

    for recording in RECORDINGS:
        fixture = recording["fixture"]
        with open(os.path.join(FIXTURES, fixture), encoding="utf-8") as f:
            yaml_content = f.read()

        app_id = import_dsl(base, token, yaml_content)
        publish(base, token, app_id)
        key = api_key(base, token, app_id)
        print(f"{fixture}: imported as app {app_id}")

        for variant in recording["variants"]:
            raw, events = run_streaming(base, key, variant["inputs"])
            final = distill(events)
            name = fixture.replace("_workflow.yml", "").replace(".yml", "")
            out_path = os.path.join(TRACES, f"{name}__{variant['name']}.json")
            trace = {
                "format": "fluxcapacitor-reference-trace",
                "version": 1,
                "fixture": fixture,
                "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "inputs": variant["inputs"],
                "final": final,
                "events": events,
                "raw_sse": raw,
            }
            with open(out_path, "w", encoding="utf-8", newline="\n") as f:
                json.dump(trace, f, indent=2, ensure_ascii=False)
                f.write("\n")
            print(f"  {variant['name']}: {final['status']} -> {os.path.basename(out_path)}")

    print("\ndone — re-run `mix test` in apps/flux to replay the traces")


if __name__ == "__main__":
    main()
