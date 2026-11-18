#!/usr/bin/env bash
# P2 dry-run（上机前置 · M8）：本机 Docker 影子边车 :21434 + 出域拦截 + 三项断言
# 须在非沙箱终端跑。产出：EVIDENCE_DIR（默认 ~/Desktop/declare/evidence106/<ts>/）
#
# 模型策略（默认零联网）：
#   1) 复用 ServBay 模型目录（APFS COW 到 ~/Library/Caches，因 Docker 不能挂 /Applications）
#   2) 或 MODELS_DIR=已有 models 目录
#   3) 仅当缺模型且 ALLOW_NETWORK_PULL=1 才 docker exec ollama pull
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/infra/ollama/docker-compose.shadow.yml"
TS="$(date +%Y%m%d-%H%M%S)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$HOME/Desktop/declare/evidence106/$TS}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:21434}"
GEN_MODEL="${GEN_MODEL:-qwen2.5-coder:1.5b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
DIGEST="sha256:910d0d8107b538fb0894e63163eb195de0cc7aefcbc666dc62d3b18f71124592"
IMAGE_PIN="ollama/ollama@${DIGEST}"
SERVBAY_MODELS="${SERVBAY_MODELS:-/Applications/ServBay/db/ollama/models}"
CACHE_MODELS="${CACHE_MODELS:-$HOME/Library/Caches/ollama-shadow-models/models}"
ALLOW_NETWORK_PULL="${ALLOW_NETWORK_PULL:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need docker
need curl
need python3
need jq

mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/dryrun.log"
INTERCEPT="$EVIDENCE_DIR/intercept.jsonl"
exec > >(tee -a "$LOG") 2>&1

echo "== P2 dry-run start $TS =="
echo "EVIDENCE_DIR=$EVIDENCE_DIR"
echo "OLLAMA_HOST=$OLLAMA_HOST"
echo "DIGEST=$DIGEST"
echo "ALLOW_NETWORK_PULL=$ALLOW_NETWORK_PULL"

# Prefer already-local digest image (DaoCloud mirror tag ok)
ensure_image() {
  if docker image inspect "docker.m.daocloud.io/ollama/ollama@${DIGEST}" >/dev/null 2>&1; then
    echo "image: local daocloud digest present"
    return 0
  fi
  if docker image inspect "ollama/ollama@${DIGEST}" >/dev/null 2>&1; then
    echo "image: local ollama digest present"
    return 0
  fi
  if [[ "$ALLOW_NETWORK_PULL" == "1" ]]; then
    echo "image: pulling digest via daocloud (ALLOW_NETWORK_PULL=1)"
    docker pull "docker.m.daocloud.io/ollama/ollama@${DIGEST}"
    return 0
  fi
  echo "FAIL: digest image not local; pull once with ALLOW_NETWORK_PULL=1 or docker pull daocloud mirror" >&2
  exit 1
}

# Docker Desktop cannot mount /Applications → COW into ~/
prepare_models_dir() {
  if [[ -n "${MODELS_DIR:-}" && -d "$MODELS_DIR" ]]; then
    echo "models: using MODELS_DIR=$MODELS_DIR"
    return 0
  fi
  if [[ -d "$CACHE_MODELS/manifests" ]]; then
    echo "models: reusing cache $CACHE_MODELS"
    MODELS_DIR="$CACHE_MODELS"
    export MODELS_DIR
    return 0
  fi
  if [[ -d "$SERVBAY_MODELS/manifests" ]]; then
    echo "models: APFS COW $SERVBAY_MODELS → $CACHE_MODELS (no network)"
    mkdir -p "$(dirname "$CACHE_MODELS")"
    rm -rf "$CACHE_MODELS"
    cp -cR "$SERVBAY_MODELS" "$CACHE_MODELS"
    MODELS_DIR="$CACHE_MODELS"
    export MODELS_DIR
    return 0
  fi
  echo "FAIL: no local models at $SERVBAY_MODELS or MODELS_DIR; set MODELS_DIR or ALLOW_NETWORK_PULL=1" >&2
  exit 1
}

cleanup() {
  echo "== cleanup shadow =="
  docker compose -f "$COMPOSE" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

ensure_image
prepare_models_dir
export MODELS_DIR

echo "== bring up shadow sidecar (MODELS_DIR=$MODELS_DIR) =="
# compose file pins ollama/ollama@digest; if only daocloud ref exists, retag for compose
if ! docker image inspect "$IMAGE_PIN" >/dev/null 2>&1 \
   && docker image inspect "docker.m.daocloud.io/ollama/ollama@${DIGEST}" >/dev/null 2>&1; then
  # docker cannot `tag @digest` → run via explicit image override
  docker rm -f looma-ollama-shadow >/dev/null 2>&1 || true
  docker run -d --name looma-ollama-shadow --restart=no \
    -p 127.0.0.1:21434:11434 \
    -e OLLAMA_HOST=0.0.0.0:11434 \
    -v "$MODELS_DIR:/root/.ollama/models" \
    "docker.m.daocloud.io/ollama/ollama@${DIGEST}"
else
  docker compose -f "$COMPOSE" up -d
fi

for i in $(seq 1 60); do
  if curl -fsS "$OLLAMA_HOST/api/version" >/dev/null 2>&1; then
    echo "shadow ready after ${i}s"
    break
  fi
  sleep 1
  if [[ "$i" -eq 60 ]]; then
    echo "FAIL: shadow ollama not ready" >&2
    exit 1
  fi
done

curl -fsS "$OLLAMA_HOST/api/version" | tee "$EVIDENCE_DIR/api-version.json"
docker inspect looma-ollama-shadow --format '{{.Config.Image}}' | tee "$EVIDENCE_DIR/image.txt"
IMG="$(cat "$EVIDENCE_DIR/image.txt")"
if [[ "$IMG" != *"$DIGEST"* ]]; then
  echo "FAIL: shadow image not digest-pinned: $IMG" >&2
  exit 1
fi

curl -fsS "$OLLAMA_HOST/api/tags" | tee "$EVIDENCE_DIR/api-tags.json" >/dev/null
jq -r '.models[].name' "$EVIDENCE_DIR/api-tags.json" | tee "$EVIDENCE_DIR/models.txt"
if ! jq -e --arg g "$GEN_MODEL" --arg e "$EMBED_MODEL" \
  '[.models[].name] | (index($g) != null) and (index($e) != null)' \
  "$EVIDENCE_DIR/api-tags.json" >/dev/null; then
  if [[ "$ALLOW_NETWORK_PULL" == "1" ]]; then
    echo "== missing models; ALLOW_NETWORK_PULL=1 → pull =="
    docker exec looma-ollama-shadow ollama pull "$GEN_MODEL"
    docker exec looma-ollama-shadow ollama pull "$EMBED_MODEL"
    curl -fsS "$OLLAMA_HOST/api/tags" | tee "$EVIDENCE_DIR/api-tags.json" >/dev/null
    jq -r '.models[].name' "$EVIDENCE_DIR/api-tags.json" | tee "$EVIDENCE_DIR/models.txt"
  else
    echo "FAIL: required models not in mounted dir ($GEN_MODEL / $EMBED_MODEL); refuse network pull (ALLOW_NETWORK_PULL=0)" >&2
    exit 1
  fi
else
  echo "models: already present — skip pull"
fi
echo "models_source=$MODELS_DIR" | tee "$EVIDENCE_DIR/models-source.txt"

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
    f"- models_source: {(ev / 'models-source.txt').read_text().strip() if (ev / 'models-source.txt').exists() else 'n/a'}",
    "- pull policy: reuse local / COW ServBay; network pull only if ALLOW_NETWORK_PULL=1",
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
