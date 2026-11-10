#!/usr/bin/env bash
# 触发另一个仓的 workflow 并等到结束，退出码跟着结论走。
#
# 用法：trigger-and-wait.sh <owner/repo> <workflow-file> [gh workflow run 的其余参数...]
# 例：  trigger-and-wait.sh GenzLTD/looma-zervi deploy-106.yml --ref feat/core-selfcontained -f sha=abc123
#
# 环境：GH_TOKEN（能对该仓 actions:write / actions:read）、WAIT_TIMEOUT（秒，默认 2400）
set -euo pipefail

repo="${1:?用法：trigger-and-wait.sh <owner/repo> <workflow> [参数...]}"
wf="${2:?缺少 workflow 文件名}"
shift 2
limit="${WAIT_TIMEOUT:-2400}"

before="$(gh run list -R "$repo" -w "$wf" --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
echo "── $repo/$wf"
echo "   触发前最新 run id = $before"

gh workflow run "$wf" -R "$repo" "$@"
echo "   已触发，等待出现在列表里…"

new_id=""
for _ in $(seq 1 30); do
  sleep 4
  new_id="$(gh run list -R "$repo" -w "$wf" --limit 10 \
      --json databaseId --jq "map(select(.databaseId > $before)) | sort_by(.databaseId) | last | .databaseId // 0")"
  [ -n "$new_id" ] && [ "$new_id" != "0" ] && [ "$new_id" != "null" ] && break
  new_id=""
done
if [ -z "$new_id" ]; then
  echo "::error::$repo 触发了但 2 分钟内没出现新 run（检查 workflow 是否支持 workflow_dispatch）"
  exit 1
fi

echo "   新 run = $new_id   https://github.com/$repo/actions/runs/$new_id"
echo "   轮询中（上限 $((limit / 60)) 分钟）…"

deadline=$((SECONDS + limit))
while [ "$SECONDS" -lt "$deadline" ]; do
  row="$(gh run view "$new_id" -R "$repo" --json status,conclusion,headSha \
      --jq '"\(.status)\t\(.conclusion // "-")\t\(.headSha[0:7])"')"
  st="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  concl="${rest%%$'\t'*}"
  sha="${rest#*$'\t'}"
  printf '   %-12s %-10s %s\n' "$st" "$concl" "$sha"
  if [ "$st" = "completed" ]; then
    echo "   结论：$concl"
    { echo "### $repo → $concl"
      echo ""
      echo "- run: https://github.com/$repo/actions/runs/$new_id"
      echo "- sha: \`$sha\`"
      echo ""
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    case "$concl" in
      success) exit 0 ;;
      skipped) exit 0 ;;
      *) echo "::error::$repo 部署失败：$concl"; exit 1 ;;
    esac
  fi
  sleep 20
done

echo "::error::$repo 等待超时（$((limit / 60)) 分钟）"
exit 1
