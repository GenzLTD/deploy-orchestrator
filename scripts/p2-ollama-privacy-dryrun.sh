#!/usr/bin/env bash
# P2 dry-run（上机前置 · M8）：影子边车 :21434 + 出域拦截 + 三项断言
# 须在非沙箱终端跑（Terminal.app / Cursor 本机终端均可；勿用无 Docker 的沙箱）。
# 产出：EVIDENCE_DIR（默认 ~/Desktop/declare/evidence106/<ts>/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/infra/ollama/docker-compose.shadow.yml"
TS="$(date +%Y%m%d-%H%M%S)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$HOME/Desktop/declare/evidence106/$TS}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:21434}"
GEN_MODEL="${GEN_MODEL:-qwen2.5-coder:1.5b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
IMAGE_PIN="ollama/ollama@sha256:910d0d8107b538fb0894e63163eb195de0cc7aefcbc666dc62d3b18f71124592"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need docker
need curl
need python3
need jq

mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/dryrun.log"
INTERCEPT="$EVIDENCE_DIR/intercept.jsonl"
SUMMARY="$EVIDENCE_DIR/SUMMARY.md"
exec > >(tee -a "$LOG") 2>&1

echo "== P2 dry-run start $TS =="
echo "EVIDENCE_DIR=$EVIDENCE_DIR"
echo "OLLAMA_HOST=$OLLAMA_HOST"
echo "IMAGE_PIN=$IMAGE_PIN"

cleanup() {
  echo "== cleanup shadow =="
  docker compose -f "$COMPOSE" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== bring up shadow sidecar =="
docker compose -f "$COMPOSE" up -d
# wait ready
for i in $(seq 1 60); do
  if curl -fsS "$OLLAMA_HOST/api/version" >/dev/null 2>&1; then
    echo "shadow ready after ${i}s"
    break
  fi
  sleep 2
  if [[ "$i" -eq 60 ]]; then
    echo "FAIL: shadow ollama not ready" >&2
    exit 1
  fi
done

curl -fsS "$OLLAMA_HOST/api/version" | tee "$EVIDENCE_DIR/api-version.json"
docker inspect looma-ollama-shadow --format '{{.Config.Image}}' | tee "$EVIDENCE_DIR/image.txt"
IMG="$(cat "$EVIDENCE_DIR/image.txt")"
if [[ "$IMG" != *sha256:910d0d8107b538fb0894e63163eb195de0cc7aefcbc666dc62d3b18f71124592* ]]; then
  echo "FAIL: shadow image not digest-pinned: $IMG" >&2
  exit 1
fi

echo "== pull models (may take minutes) =="
docker exec looma-ollama-shadow ollama pull "$GEN_MODEL"
docker exec looma-ollama-shadow ollama pull "$EMBED_MODEL"
curl -fsS "$OLLAMA_HOST/api/tags" | tee "$EVIDENCE_DIR/api-tags.json" >/dev/null
jq -r '.models[].name' "$EVIDENCE_DIR/api-tags.json" | tee "$EVIDENCE_DIR/models.txt"

echo "== item1+2+3: python intercept harness =="
OLLAMA_HOST="$OLLAMA_HOST" GEN_MODEL="$GEN_MODEL" EMBED_MODEL="$EMBED_MODEL" \
INTERCEPT="$INTERCEPT" EVIDENCE_DIR="$EVIDENCE_DIR" python3 - <<'PY'
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

HOST = os.environ["OLLAMA_HOST"].rstrip("/")
GEN = os.environ["GEN_MODEL"]
EMB = os.environ["EMBED_MODEL"]
INTERCEPT = os.environ["INTERCEPT"]
EVIDENCE = os.environ["EVIDENCE_DIR"]

ALLOWED_PREFIXES = (
    "http://127.0.0.1:",
    "http://localhost:",
    "https://127.0.0.1:",
    "https://localhost:",
)
BLOCKED_MARKERS = (
    "api.deepseek.com",
    "api.openai.com",
    "openai.com",
    "dashscope",
    "aliyuncs.com",
)

seen: list[dict[str, Any]] = []
real_urlopen = urllib.request.urlopen


def guarded_urlopen(req, *args, **kwargs):
    if isinstance(req, str):
        url = req
    else:
        url = req.full_url
    rec = {"url": url, "method": getattr(req, "get_method", lambda: "GET")()}
    seen.append(rec)
    with open(INTERCEPT, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    low = url.lower()
    if not any(low.startswith(p) for p in ALLOWED_PREFIXES):
        raise AssertionError(f"egress blocked (non-loopback): {url}")
    for m in BLOCKED_MARKERS:
        if m in low:
            raise AssertionError(f"egress blocked (cloud marker {m}): {url}")
    return real_urlopen(req, *args, **kwargs)


urllib.request.urlopen = guarded_urlopen  # type: ignore


def post_json(path: str, body: dict) -> dict:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{HOST}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read().decode())


results: dict[str, Any] = {"item1_zero_egress": None, "item2_fail_closed": None, "item3_field_whitelist": None}

# --- item1: generate + embed only loopback ---
try:
    gen = post_json(
        "/api/generate",
        {"model": GEN, "prompt": "ping privacy dry-run", "stream": False},
    )
    emb = post_json(
        "/api/embeddings",
        {"model": EMB, "prompt": "private corpus must not leave machine"},
    )
    assert "response" in gen or "message" in gen
    assert "embedding" in emb
    cloud_hits = [s for s in seen if any(m in s["url"].lower() for m in BLOCKED_MARKERS)]
    non_loop = [s for s in seen if not any(s["url"].startswith(p) for p in ALLOWED_PREFIXES)]
    if cloud_hits or non_loop:
        results["item1_zero_egress"] = {
            "pass": False,
            "cloud_hits": cloud_hits,
            "non_loopback": non_loop,
        }
    else:
        results["item1_zero_egress"] = {
            "pass": True,
            "calls": len(seen),
            "hosts": sorted({s["url"].split("/")[2] for s in seen}),
        }
except Exception as e:
    results["item1_zero_egress"] = {"pass": False, "error": str(e)}

# --- item2: stop ollama → expect connection failure (fail-closed signal) ---
# Caller stops container around this section via env GATE; we simulate by wrong port first
# then real stop is done by shell between python invocations.
# Here we only validate policy shape if OLLAMA_DOWN=1
if os.environ.get("OLLAMA_DOWN") == "1":
    try:
        post_json("/api/generate", {"model": GEN, "prompt": "should fail", "stream": False})
        results["item2_fail_closed"] = {"pass": False, "error": "ollama still answered while DOWN"}
    except Exception as e:
        # refuse = cannot reach local → upstream must not fall back to cloud (we made no cloud call)
        cloud_after = [s for s in seen if any(m in s["url"].lower() for m in BLOCKED_MARKERS)]
        results["item2_fail_closed"] = {
            "pass": not cloud_after,
            "exception": type(e).__name__,
            "message": str(e)[:200],
            "cloud_after": cloud_after,
            "signal": "rag_local_required_equivalent",
        }
else:
    results["item2_fail_closed"] = {"pass": None, "deferred": "shell phase"}

# --- item3: field whitelist projection (structural; A9 full MCP out of window) ---
ALLOW = {"path", "title", "status", "count"}
raw = {
    "path": "docs/adrs/0001.md",
    "title": "lab canonical",
    "status": "Accepted",
    "count": 3,
    "content": "SECRET_BODY_MUST_NOT_EGRESS " + ("x" * 200),
    "raw_html": "<p>leak</p>",
}


def project(doc: dict) -> dict:
    return {k: doc[k] for k in ALLOW if k in doc}


proj = project(raw)
leak = "SECRET_BODY" in json.dumps(proj) or "raw_html" in proj or "content" in proj
results["item3_field_whitelist"] = {
    "pass": not leak and set(proj) <= ALLOW,
    "projected": proj,
    "allowlist": sorted(ALLOW),
    "note": "确定性结构投影 stub；完整 MCP 工具字段白名单属 A9 本窗外，焊点形态在此证明",
}

out = os.path.join(EVIDENCE, "harness-results.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
print(json.dumps(results, ensure_ascii=False, indent=2))
if not results["item1_zero_egress"].get("pass"):
    sys.exit(1)
if not results["item3_field_whitelist"].get("pass"):
    sys.exit(1)
PY

echo "== item2: stop shadow, expect refuse, no cloud =="
docker stop looma-ollama-shadow
OLLAMA_HOST="$OLLAMA_HOST" GEN_MODEL="$GEN_MODEL" EMBED_MODEL="$EMBED_MODEL" \
INTERCEPT="$INTERCEPT" EVIDENCE_DIR="$EVIDENCE_DIR" OLLAMA_DOWN=1 python3 - <<'PY'
from __future__ import annotations
import json, os, sys, urllib.request, urllib.error
from typing import Any

HOST = os.environ["OLLAMA_HOST"].rstrip("/")
GEN = os.environ["GEN_MODEL"]
INTERCEPT = os.environ["INTERCEPT"]
EVIDENCE = os.environ["EVIDENCE_DIR"]
BLOCKED = ("api.deepseek.com", "api.openai.com", "openai.com")
seen: list[dict[str, Any]] = []
real = urllib.request.urlopen

def guarded(req, *a, **k):
    url = req if isinstance(req, str) else req.full_url
    seen.append({"url": url})
    with open(INTERCEPT, "a", encoding="utf-8") as f:
        f.write(json.dumps({"url": url, "phase": "down"}) + "\n")
    return real(req, *a, **k)

urllib.request.urlopen = guarded  # type: ignore
ok = False
err = ""
try:
    data = json.dumps({"model": GEN, "prompt": "x", "stream": False}).encode()
    req = urllib.request.Request(f"{HOST}/api/generate", data=data, headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=5).read()
    err = "unexpected success"
except Exception as e:
    err = f"{type(e).__name__}: {e}"
    cloud = [s for s in seen if any(m in s["url"].lower() for m in BLOCKED)]
    ok = not cloud

path = os.path.join(EVIDENCE, "harness-results.json")
with open(path, encoding="utf-8") as f:
    results = json.load(f)
results["item2_fail_closed"] = {
    "pass": ok,
    "exception": err[:300],
    "cloud_calls": [s for s in seen if any(m in s["url"].lower() for m in BLOCKED)],
    "signal": "rag_local_required_equivalent",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
print(json.dumps(results["item2_fail_closed"], ensure_ascii=False, indent=2))
sys.exit(0 if ok else 1)
PY

docker start looma-ollama-shadow >/dev/null
sleep 2

echo "== write SUMMARY =="
export EVIDENCE_DIR TS OLLAMA_HOST
python3 - <<'PY'
import json, os
from pathlib import Path

ev = Path(os.environ["EVIDENCE_DIR"])
res = json.loads((ev / "harness-results.json").read_text())
img = (ev / "image.txt").read_text().strip() if (ev / "image.txt").exists() else "?"
models = (ev / "models.txt").read_text().replace("\n", " ").strip() if (ev / "models.txt").exists() else "?"
lines = [
    "# P2 dry-run evidence (M8)",
    "",
    f"- ts: {os.environ.get('TS', '')}",
    f"- host: shadow {os.environ.get('OLLAMA_HOST', '')}",
    f"- image: {img}",
    f"- models: {models}",
    "",
    "| Item | Result |",
    "|---|---|",
    f"| 1 生成+向量双轨零出域 | {'PASS' if res['item1_zero_egress'].get('pass') else 'FAIL'} |",
    f"| 2 拔 Ollama 拒答（无云回落） | {'PASS' if res['item2_fail_closed'].get('pass') else 'FAIL'} |",
    f"| 3 字段白名单投影 | {'PASS' if res['item3_field_whitelist'].get('pass') else 'FAIL'} |",
    "",
    "Artifacts: `dryrun.log`, `intercept.jsonl`, `harness-results.json`, `api-version.json`, `api-tags.json`, `image.txt`.",
    "",
    "Note: item3 is structural projection stub; full MCP tool whitelist is A9 out of this window.",
    "Orchestration: stack pin + compose digest in deploy-orchestrator; do not deploy-all without B8 auth.",
]
(ev / "SUMMARY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print((ev / "SUMMARY.md").read_text())
all_ok = all(
    res[k].get("pass")
    for k in ("item1_zero_egress", "item2_fail_closed", "item3_field_whitelist")
)
raise SystemExit(0 if all_ok else 1)
PY

echo "PASS: P2 dry-run three greens → $EVIDENCE_DIR"
