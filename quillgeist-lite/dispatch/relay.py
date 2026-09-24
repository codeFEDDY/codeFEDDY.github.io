import json
import os
import sys
import time
import urllib.error
import urllib.request

CONTROL_PLANE = os.environ.get("CONTROL_PLANE", "https://mcp.codefeddy.com").rstrip("/")
TOKEN = os.environ.get("CONTROL_PLANE_MCP_TOKEN", "")
REQUEST_FILE = os.environ.get("REQUEST_FILE", "quillgeist-lite/dispatch/request.json")

ALLOWED = {
    "clintware-doctor": set(),
    "google-cloud-support-access": {"OwnerAccount", "SupportAccount", "ProjectName"},
    "finish-google-oauth": {"Repo"},
    "python-runtime-check": {"Message"},
    "c-runtime-check": {"Message"},
    "ensure-c-runtime": set(),
    "ensure-powershell": set(),
    "update-powerchatbridge": set(),
    "self-update": set(),
    "restart-window": set(),
    "repair-local-service": set(),
    "apply-terminal-glass": set(),
    "connect-jira": set(),
    "enable-admin-console": set(),
    "bootstrap-admin-console": set(),
    "gimp-clintware-eclipse": set(),
    "codefeddy-access-check": set(),
    "provision-codefeddy-platform": set(),
}

def request_json(method, path, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        CONTROL_PLANE + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bearer " + TOKEN,
            "Content-Type": "application/json",
            "User-Agent": "clintware-quillgeist-lite-relay",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        payload = e.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(payload)
        except Exception:
            parsed = {"error": payload}
        return e.code, parsed

if not TOKEN:
    raise SystemExit("CONTROL_PLANE_MCP_TOKEN is missing")

with open(REQUEST_FILE, "r", encoding="utf-8") as f:
    req = json.load(f)

task_id = str(req.get("task_id") or "")
args = req.get("args") or {}
if task_id not in ALLOWED:
    raise SystemExit(f"task_not_allowed: {task_id!r}")
if not isinstance(args, dict):
    raise SystemExit("args must be an object")

unknown = set(args) - ALLOWED[task_id]
if unknown:
    raise SystemExit(f"argument_not_allowed: {sorted(unknown)}")

print(f"REQUEST_OK task={task_id} request_id={req.get('request_id','')}", flush=True)

status, created = request_json("POST", "/api/v1/quillgeist-lite/jobs", {
    "task_id": task_id,
    "args": args,
    "objective": str(req.get("objective") or ""),
})
print(json.dumps(created, indent=2), flush=True)
if status not in (200, 201, 202) or not created.get("ok"):
    raise SystemExit("dispatch_failed")

job_id = created["job_id"]
print(f"JOB_ID={job_id}", flush=True)

last_seq = 0
for _ in range(900):
    status_code, payload = request_json("GET", f"/api/v1/quillgeist-lite/jobs/{job_id}")
    if status_code != 200:
        print(json.dumps(payload, indent=2), flush=True)
        time.sleep(2)
        continue

    job = payload.get("job") or {}
    logs = job.get("logs") or []
    for row in logs:
        seq = int(row.get("seq") or 0)
        if seq > last_seq:
            print(f"[{row.get('timestamp','')}] {row.get('line','')}", flush=True)
            last_seq = max(last_seq, seq)

    state = str(job.get("status") or "unknown")
    if state in {"passed", "failed"}:
        result = job.get("result") or {}
        print("", flush=True)
        print(f"FINAL_STATUS={state}", flush=True)
        print(f"EXIT_CODE={result.get('exit_code')}", flush=True)
        print(f"DURATION_MS={result.get('duration_ms')}", flush=True)
        output = str(result.get("output") or "")
        if output:
            print("--- FINAL OUTPUT ---", flush=True)
            print(output[-20000:], flush=True)
        # A local task failure is diagnostic evidence. The relay itself remains usable
        # so another request can be dispatched immediately by the model.
        sys.exit(0)

    time.sleep(2)

raise SystemExit(f"timed_out_waiting_for_job:{job_id}")

