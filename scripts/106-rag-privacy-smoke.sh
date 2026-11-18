#!/usr/bin/env bash
# 106 Ask 隐私分轨冒烟（运维窗）。不写密钥；默认探本机回环（SSH 隧道或机上执行）。
# 用法：
#   LOOMA_HEALTH=http://127.0.0.1:5200/health \
#   THOMAS_HEALTH=http://127.0.0.1:5300/health \
#   ASK_URL=http://127.0.0.1:5300/v1/ask \
#   ./scripts/106-rag-privacy-smoke.sh
#
# 退出码：
#   0 = health + Ask 全部门禁断言通过（所有 P0 判据均已验证）
#   1 = 断言失败（读到明确证据证明违规）
#   2 = 依赖缺失
#   3 = 不可判定（health/Ask 抓取失败、HTTP 鉴权/配额、关键字段缺失）——绝不计 PASS
#
# 设计原则（fail-closed）：
#   「没验证到」与「验证通过」必须区分。任何字段缺失、读不到、抓不到，
#   一律 exit 3 UNDETERMINED，不得以 NOTE/WARN 放行，也不得晋升为 exit 0。
#   禁止任何可跳过 P0 判据（thomas ollama_ok / Ask egress / embedding 出域）的开关。
set -euo pipefail

LOOMA_HEALTH="${LOOMA_HEALTH:-http://127.0.0.1:5200/health}"
THOMAS_HEALTH="${THOMAS_HEALTH:-http://127.0.0.1:5300/health}"
ASK_URL="${ASK_URL:-http://127.0.0.1:5300/v1/ask}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need_cmd curl
need_cmd jq

fail=0

undetermined() { echo "UNDETERMINED: $*" >&2; exit 3; }
require_field() { # require_field <json> <jq-filter> <label>
  local json="$1" filter="$2" label="$3" val
  val="$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null || true)"
  [[ -n "$val" && "$val" != "null" ]] || undetermined "field missing/empty: $label"
  printf '%s' "$val"
}

echo "== health looma =="
looma_json="$(curl -fsS --max-time 15 "$LOOMA_HEALTH" 2>/dev/null)" \
  || undetermined "cannot fetch looma health: $LOOMA_HEALTH"
require_field "$looma_json" '.ollama_ok' 'looma.ollama_ok' >/dev/null
require_field "$looma_json" '.rag_privacy_mode' 'looma.rag_privacy_mode' >/dev/null
require_field "$looma_json" '.git_commit' 'looma.git_commit' >/dev/null
echo "$looma_json" | jq '{status,ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,llm_provider_order,git_commit}'
echo "$looma_json" | jq -e '.ollama_ok == true' >/dev/null \
  || { echo "FAIL: looma ollama_ok != true" >&2; fail=1; }
echo "$looma_json" | jq -e '.rag_privacy_mode == "dual" or .rag_privacy_mode == "local_only"' >/dev/null \
  || { echo "FAIL: unexpected rag_privacy_mode" >&2; fail=1; }

echo "== health thomas (P0 硬断言，禁止跳过) =="
thomas_json="$(curl -fsS --max-time 15 "$THOMAS_HEALTH" 2>/dev/null)" \
  || undetermined "cannot fetch thomas health: $THOMAS_HEALTH"
require_field "$thomas_json" '.ollama_ok' 'thomas.ollama_ok' >/dev/null
require_field "$thomas_json" '.git_commit' 'thomas.git_commit' >/dev/null
echo "$thomas_json" | jq '{status,service,ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,git_commit}'
# thomas 未同步分轨 tip（D2/V10）时必须 FAIL，不得用任何开关绕过
echo "$thomas_json" | jq -e '.ollama_ok == true' >/dev/null \
  || { echo "FAIL: thomas ollama_ok != true（D2/V10：须同步分轨 tip，禁止跳过）" >&2; fail=1; }

echo "== ask smoke (auto assert, fail-closed) =="
ask_body="/tmp/106-ask-smoke.json"
rm -f "$ask_body"
code="$(curl -sS --max-time 30 -o "$ask_body" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"query":"知识库是什么","mode":"fast"}' \
  "$ASK_URL" 2>/dev/null || true)"
[[ -n "$code" ]] || undetermined "Ask request failed with no HTTP code"
echo "HTTP $code"
[[ -f "$ask_body" && -s "$ask_body" ]] || undetermined "no Ask response body (HTTP $code)"

# JSON 可解析性硬门禁：解析失败 = 不可判定
jq -e . "$ask_body" >/dev/null 2>&1 || undetermined "Ask response is not valid JSON"
jq '{intent,egress,rag_privacy,llm_provider,error,answer:(.answer[:80]//null)}' "$ask_body"

case "$code" in
  200)
    # 200 必须携带可断言的 egress + llm_provider；缺字段 = 不可判定
    egress="$(require_field "$(cat "$ask_body")" '.egress' 'ask.egress')"
    llm="$(require_field "$(cat "$ask_body")" '.llm_provider' 'ask.llm_provider')"
    err="$(jq -r '.error // ""' "$ask_body")"
    [[ "$err" != "null" ]] || undetermined "ask.error is null"

    # egress 白名单：local_only | cloud_allowed（dual 轨）；其余值不可判定
    case "$egress" in
      local_only|cloud_allowed) ;;
      *) undetermined "unexpected ask.egress value: $egress" ;;
    esac

    if [[ "$egress" == "local_only" ]]; then
      # 本地轨：llm 必须是 ollama，或携带 fail-closed 错误；deepseek = 云回落违规
      if [[ "$llm" == "deepseek" ]]; then
        echo "FAIL: local_only egress but llm_provider=deepseek (cloud fallback)" >&2
        fail=1
      elif [[ "$llm" != "ollama" && -z "$err" ]]; then
        undetermined "local_only egress with non-ollama llm_provider=$llm and no error"
      fi
    fi
    # fail-closed 信号绝不能与 deepseek 同现
    if [[ "$err" == "rag_local_required" && "$llm" == "deepseek" ]]; then
      echo "FAIL: rag_local_required must not pair with deepseek" >&2
      fail=1
    fi
    ;;
  401|403|429)
    undetermined "Ask HTTP $code — 鉴权/配额，不能计 PASS"
    ;;
  *)
    # 非 200 仅接受一种明确证据：body 携带 fail-closed 信号 rag_local_required
    err="$(jq -r '.error // ""' "$ask_body")"
    if [[ "$err" == "rag_local_required" ]]; then
      echo "OK: fail-closed signal rag_local_required (HTTP $code)"
    else
      undetermined "Ask HTTP $code without assertable fail-closed signal"
    fi
    ;;
esac

# embedding 出域门（D10 根治）：不允许「读不到就 NOTE 放行」。
# 优先 looma health 暴露的 embed_provider_order；health 未暴露则该判据不可判定，
# 必须以 exit 3 交回 P2 dry-run 拦截日志取证，绝不计 PASS。
embed_order="$(echo "$looma_json" | jq -r 'if has("embed_provider_order") then .embed_provider_order elif has("EMBED_PROVIDER_ORDER") then .EMBED_PROVIDER_ORDER else empty end' 2>/dev/null || true)"
if [[ -z "$embed_order" || "$embed_order" == "null" ]]; then
  undetermined "embed_provider_order not exposed by looma health — 须由 P2 dry-run 拦截日志取证，不计 PASS"
fi
if [[ "$embed_order" != *ollama* ]]; then
  echo "FAIL: embed_provider_order missing ollama: $embed_order" >&2
  fail=1
else
  echo "OK: embed_provider_order contains ollama: $embed_order"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: smoke assertions failed" >&2
  exit 1
fi
echo "PASS: all P0 gates verified (health + Ask egress/fail-closed + embedding order)"
