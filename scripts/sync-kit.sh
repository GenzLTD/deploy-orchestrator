#!/usr/bin/env bash
# 把仓内 infra/ 同步到 106 的 /home/ubuntu/106-deploy-kit（先备份再覆盖）。
# 用法：配齐 DEPLOY106_* 后 ./scripts/sync-kit.sh
# 仅同步套件文件，不执行 bootstrap infra / 不重启服务。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT_DIR="${KIT_DIR:-/home/ubuntu/106-deploy-kit}"
chmod +x "$ROOT/scripts/106.sh"

: "${DEPLOY106_HOST:?DEPLOY106_HOST 未设置}"
: "${DEPLOY106_SSH_KEY:?DEPLOY106_SSH_KEY 未设置}"
APP_USER="${DEPLOY106_USER:-ubuntu}"
PORT="${DEPLOY106_SSH_PORT:-22}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# gzip 包不能 tar -r 追加（GNU tar: Cannot update compressed archives）
extra=()
if [ -f "$ROOT/infra/部署手册.md" ]; then
  extra+=("部署手册.md")
fi
tar -C "$ROOT/infra" -czf "$work/kit.tgz"   bootstrap.sh systemd nginx env-templates tests   kit.conf.example README.md   "${extra[@]}"

keyfile="$work/key"
if [ -f "$DEPLOY106_SSH_KEY" ]; then
  cp "$DEPLOY106_SSH_KEY" "$keyfile"
else
  printf '%s\n' "$DEPLOY106_SSH_KEY" > "$keyfile"
fi
chmod 600 "$keyfile"

scp -i "$keyfile" -P "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  "$work/kit.tgz" "${APP_USER}@${DEPLOY106_HOST}:/tmp/deploy-kit.tgz"

"$ROOT/scripts/106.sh" "set -euo pipefail
KIT='${KIT_DIR}'
ts=\$(date +%Y%m%d-%H%M%S)
if [ -d \"\$KIT\" ]; then cp -a \"\$KIT\" \"\${KIT}.bak-\$ts\"; fi
mkdir -p \"\$KIT\"
tar -xzf /tmp/deploy-kit.tgz -C \"\$KIT\"
chmod +x \"\$KIT/bootstrap.sh\" \"\$KIT/tests/selfcheck.sh\" 2>/dev/null || true
rm -f /tmp/deploy-kit.tgz
echo KIT_SYNC_OK
echo KIT_VER=\$(grep -m1 KIT_VERSION= \"\$KIT/bootstrap.sh\" | cut -d'\"' -f2)
echo KIT_SHA=\$(sha256sum \"\$KIT/bootstrap.sh\" | cut -c1-16)
"
