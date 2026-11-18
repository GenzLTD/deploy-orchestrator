#!/usr/bin/env bash
# 106 Ask 隐私分轨冒烟（运维窗）。不写密钥；默认探本机回环（SSH 隧道或机上执行）。
# 用法：
#   LOOMA_HEALTH=http://127.0.0.1:5200/health \
#   THOMAS_HEALTH=http://127.0.0.1:5300/health \
#   ASK_URL=http://127.0.0.1:5300/v1/ask \
#   ./scripts/106-rag-privacy-smoke.sh
#
# 退出码：
#   0 = health + Ask 自动断言全过
#   1 = 断言失败
#   2 = 依赖缺失
#   3 = Ask 不可判定（401/429/缺字段）——不算 PASS
set -euo pipefail

LOOMA_HEALTH="${LOOMA_HEALTH:-http://127.0.0.1:5200/health}"
THOMAS_HEALTH="${THOMAS_HEALTH:-http://127.0.0.1:5300/health}"
ASK_URL="${ASK_URL:-http://127.0.0.1:5300/v1/ask}"
SKIP_THOMAS_OLLAMA="${SKIP_THOMAS_OLLAMA:-0}"   # 1=thomas 尚未同步分轨 tip 时跳过 ollama_ok（仅过渡）

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need_cmd curl
need_cmd jq

fail=0
warn=0

echo "== health looma =="
looma_json="$(curl -fsS "$LOOMA_HEALTH")"
echo "$looma_json" | jq '{status,ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,llm_provider_order,git_commit}'
echo "$looma_json" | jq -e '.ollama_ok == true' >/dev/null \
  || { echo "FAIL: looma ollama_ok != true" >&2; fail=1; }
echo "$looma_json" | jq -e '.rag_privacy_mode == "dual" or .rag_privacy_mode == "local_only"' >/dev/null \
  || { echo "FAIL: unexpected rag_privacy_mode" >&2; fail=1; }

echo "== health thomas =="
thomas_json="$(curl -fsS "$THOMAS_HEALTH")"
echo "$thomas_json" | jq '{status,service,ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,git_commit}'
if [[ "$SKIP_THOMAS_OLLAMA" == "1" ]]; then
  echo "WARN: SKIP_THOMAS_OLLAMA=1 — thomas ollama_ok 未断言（D2 过渡）" >&2
  warn=1
else
  echo "$thomas_json" | jq -e '.ollama_ok == true' >/dev/null \
    || { echo "FAIL: thomas ollama_ok != true（须同步分轨 tip）" >&2; fail=1; }
fi

echo "== ask smoke (auto assert) =="
code="$(curl -sS -o /tmp/106-ask-smoke.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"query":"知识库是什么","mode":"fast"}' \
  "$ASK_URL" || true)"
echo "HTTP $code"
if [[ ! -f /tmp/106-ask-smoke.json ]]; then
  echo "FAIL: no Ask body" >&2
  exit 1
fi
jq '{intent,egress,rag_privacy,llm_provider,error,answer:(.answer[:80]//null)}' /tmp/106-ask-smoke.json 2>/dev/null \
  || cat /tmp/106-ask-smoke.json

case "$code" in
  200)
    # 隐私命中或本地轨：不得静默回落 deepseek
    egress="$(jq -r '.egress // empty' /tmp/106-ask-smoke.json)"
    llm="$(jq -r '.llm_provider // empty' /tmp/106-ask-smoke.json)"
    err="$(jq -r '.error // empty' /tmp/106-ask-smoke.json)"
    if [[ "$egress" == "local_only" ]]; then
      if [[ "$llm" == "deepseek" ]]; then
        echo "FAIL: local_only egress but llm_provider=deepseek (cloud fallback)" >&2
        fail=1
      fi
      if [[ -n "$llm" && "$llm" != "ollama" && -z "$err" ]]; then
        echo "FAIL: local_only expected ollama or error, got llm_provider=$llm" >&2
        fail=1
      fi
    fi
    if [[ "$err" == "rag_local_required" && "$llm" == "deepseek" ]]; then
      echo "FAIL: rag_local_required must not pair with deepseek" >&2
      fail=1
    fi
    ;;
  401|403|429)
    echo "UNDETERMINED: Ask HTTP $code — 鉴权/配额，不能计 PASS" >&2
    exit 3
    ;;
  *)
    # 允许业务错误体携带 fail-closed 信号
    err="$(jq -r '.error // empty' /tmp/106-ask-smoke.json 2>/dev/null || true)"
    if [[ "$err" == "rag_local_required" ]]; then
      echo "OK: fail-closed signal rag_local_required (HTTP $code)"
    else
      echo "UNDETERMINED: Ask HTTP $code without assertable egress/error" >&2
      exit 3
    fi
    ;;
esac

# embedding 出域门：health/env 侧只能确认配置意图；真拦截见 P2 dry-run
embed_order="$(echo "$looma_json" | jq -r '.embed_provider_order // .EMBED_PROVIDER_ORDER // empty')"
if [[ -n "$embed_order" && "$embed_order" != *ollama* ]]; then
  echo "FAIL: embed_provider_order missing ollama: $embed_order" >&2
  fail=1
else
  echo "NOTE: embedding 出域以 P2 dry-run 拦截日志为准；health 未暴露 embed 顺序时跳过硬断言"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: smoke assertions failed" >&2
  exit 1
fi
if [[ "$warn" -ne 0 ]]; then
  echo "OK_WITH_WARN: health gates passed; Ask asserts passed; see WARN above"
  exit 0
fi
echo "PASS: health + Ask auto asserts"
