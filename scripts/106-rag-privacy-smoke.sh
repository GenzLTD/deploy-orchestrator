#!/usr/bin/env bash
# 106 Ask 隐私分轨冒烟（运维窗）。不写密钥；默认探本机回环（SSH 隧道或机上执行）。
# 用法：
#   LOOMA_HEALTH=http://127.0.0.1:5200/health \
#   THOMAS_HEALTH=http://127.0.0.1:5300/health \
#   ASK_URL=http://127.0.0.1:5300/v1/ask \
#   ./scripts/106-rag-privacy-smoke.sh
set -euo pipefail

LOOMA_HEALTH="${LOOMA_HEALTH:-http://127.0.0.1:5200/health}"
THOMAS_HEALTH="${THOMAS_HEALTH:-http://127.0.0.1:5300/health}"
ASK_URL="${ASK_URL:-http://127.0.0.1:5300/v1/ask}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd jq

echo "== health looma =="
looma_json="$(curl -fsS "$LOOMA_HEALTH")"
echo "$looma_json" | jq '{status,ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,llm_provider_order}'
echo "$looma_json" | jq -e '.ollama_ok == true' >/dev/null \
  || { echo "FAIL: looma ollama_ok != true" >&2; exit 1; }
echo "$looma_json" | jq -e '.rag_privacy_mode == "dual" or .rag_privacy_mode == "local_only"' >/dev/null \
  || { echo "FAIL: unexpected rag_privacy_mode" >&2; exit 1; }

echo "== health thomas =="
thomas_json="$(curl -fsS "$THOMAS_HEALTH")"
echo "$thomas_json" | jq '{status,service,ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections}'
echo "$thomas_json" | jq -e '.ollama_ok == true' >/dev/null \
  || { echo "FAIL: thomas ollama_ok != true" >&2; exit 1; }

echo "== ask smoke (best-effort; may 401/429 without auth/quota) =="
# 不强制 200：仅打印 egress / error / llm_provider，便于人工确认
code="$(curl -sS -o /tmp/106-ask-smoke.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"query":"知识库是什么","mode":"fast"}' \
  "$ASK_URL" || true)"
echo "HTTP $code"
if [[ -f /tmp/106-ask-smoke.json ]]; then
  jq '{intent,egress,rag_privacy,llm_provider,error,answer:(.answer[:80])}' /tmp/106-ask-smoke.json 2>/dev/null || cat /tmp/106-ask-smoke.json
fi

echo "OK: health gates passed. Review Ask JSON for egress/llm_provider manually."
