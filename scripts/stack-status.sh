#!/usr/bin/env bash
# 对照 stack/106.stack.json 只读探测 106（不部署）。
# 用法：配齐 DEPLOY106_* 后 ./scripts/stack-status.sh
# 退出码：0=与清单一致且绑定回环；2=有漂移/暴露面
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="${STACK_LOCK:-$ROOT/stack/106.stack.json}"
[ -f "$LOCK" ] || { echo "缺清单: $LOCK" >&2; exit 1; }
chmod +x "$ROOT/scripts/106.sh"

: "${DEPLOY106_HOST:?DEPLOY106_HOST 未设置}"
: "${DEPLOY106_SSH_KEY:?DEPLOY106_SSH_KEY 未设置}"
APP_USER="${DEPLOY106_USER:-ubuntu}"
PORT="${DEPLOY106_SSH_PORT:-22}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
keyfile="$work/key"
if [ -f "$DEPLOY106_SSH_KEY" ]; then
  cp "$DEPLOY106_SSH_KEY" "$keyfile"
else
  printf '%s\n' "$DEPLOY106_SSH_KEY" > "$keyfile"
fi
chmod 600 "$keyfile"

scp -i "$keyfile" -P "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  "$ROOT/scripts/_stack_probe_remote.py" \
  "${APP_USER}@${DEPLOY106_HOST}:/tmp/_stack_probe_remote.py"

# 106.sh 会往 stdout 打「主机身份已钉…」，只取最后一行 JSON
REMOTE_RAW="$("$ROOT/scripts/106.sh" 'python3 /tmp/_stack_probe_remote.py; rm -f /tmp/_stack_probe_remote.py')"
REMOTE_JSON="$(printf '%s\n' "$REMOTE_RAW" | awk '/^\{/{line=$0} END{print line}')"
if [ -z "$REMOTE_JSON" ]; then
  echo "探测失败，未拿到 JSON：" >&2
  printf '%s\n' "$REMOTE_RAW" >&2
  exit 1
fi

export STACK_LOCK_PATH="$LOCK"
printf '%s\n' "$REMOTE_JSON" | python3 "$ROOT/scripts/_stack_compare.py"
