#!/usr/bin/env bash
# 在 106 上执行命令：先钉主机身份，再连。
# 复用 thomas-core / looma-zervi 两仓的安全口径（严禁 StrictHostKeyChecking=no）。
#
# 用法：
#   ./scripts/106.sh 'hostname; whoami'
#   ./scripts/106.sh --sudo 'systemctl is-active looma-backend'
#
# 环境变量：
#   DEPLOY106_HOST               必填，主机名或 IP
#   DEPLOY106_USER               默认 ubuntu
#   DEPLOY106_SSH_KEY            必填，私钥内容（CI）或私钥文件路径（本机）
#   DEPLOY106_HOST_FINGERPRINT   可选但强烈建议；支持 SHA256:xxx / MD5:xx:xx / 裸冒号串
#   DEPLOY106_SSH_PORT           默认 22
set -euo pipefail

: "${DEPLOY106_HOST:?DEPLOY106_HOST 未设置}"
: "${DEPLOY106_SSH_KEY:?DEPLOY106_SSH_KEY 未设置}"
APP_USER="${DEPLOY106_USER:-ubuntu}"
FP="${DEPLOY106_HOST_FINGERPRINT:-}"
PORT="${DEPLOY106_SSH_PORT:-22}"

USE_SUDO=0
if [ "${1:-}" = "--sudo" ]; then USE_SUDO=1; shift; fi
if [ "$#" -eq 0 ]; then echo "用法：106.sh [--sudo] <命令...>" >&2; exit 64; fi
REMOTE_CMD="$*"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# ---- 私钥落临时文件（600，退出即删） ----
keyfile="$work/id_deploy"
if [ -f "$DEPLOY106_SSH_KEY" ]; then
  cp "$DEPLOY106_SSH_KEY" "$keyfile"
else
  printf '%s\n' "$DEPLOY106_SSH_KEY" > "$keyfile"
fi
chmod 600 "$keyfile"
if ! ssh-keygen -y -f "$keyfile" >/dev/null 2>&1; then
  echo "::error::DEPLOY106_SSH_KEY 不是可用的私钥（内容损坏或含多余字符）"
  exit 2
fi

# ---- 主机身份：先扫描，再与期望指纹逐字比对 ----
known="$work/known_hosts"
if [ -n "$FP" ]; then
  scan="$work/scan"
  for _ in 1 2 3; do
    ssh-keyscan -p "$PORT" -T 8 "$DEPLOY106_HOST" > "$scan" 2>/dev/null || true
    [ -s "$scan" ] && break
    sleep 2
  done
  if [ ! -s "$scan" ]; then
    echo "::error::扫描不到 $DEPLOY106_HOST:$PORT 的主机公钥（网络不通或端口被挡）"
    exit 2
  fi
  raw="$(ssh-keygen -lf "$scan" -E sha256 2>/dev/null; ssh-keygen -lf "$scan" -E md5 2>/dev/null)"
  hit=""
  if printf '%s' "$FP" | grep -q '^SHA256:'; then
    hit="$(printf '%s\n' "$raw" | awk -v f="$FP" '$2==f' | head -1)"
  elif printf '%s' "$FP" | grep -q '^MD5:'; then
    hit="$(printf '%s\n' "$raw" | awk -v f="${FP#MD5:}" '{g=$2; sub(/^MD5:/,"",g); if(g==f) print}' | head -1)"
  else
    hit="$(printf '%s\n' "$raw" | awk -v f="$FP" -v f2="SHA256:$FP" '{g=$2; sub(/^MD5:/,"",g); if(g==f || $2==f2) print}' | head -1)"
  fi
  ok=0
  if [ -n "$hit" ]; then ok=1; fi
  # 匹配到哪一类，就只允许那一类算法，防止协商降级到别的 host key
  HOSTKEY_ALG=""
  case "$hit" in
    *"(ECDSA)"*)   HOSTKEY_ALG="ecdsa-sha2-nistp256" ;;
    *"(ED25519)"*) HOSTKEY_ALG="ssh-ed25519" ;;
    *"(RSA)"*)     HOSTKEY_ALG="rsa-sha2-256,rsa-sha2-512,ssh-rsa" ;;
  esac
  if [ "$ok" != "1" ]; then
    echo "::error::主机指纹不匹配，拒绝连接"
    echo "  期望：$FP"
    echo "  实得：$(printf '%s\n' "$raw" | awk '{print $1" "$2" "$4}' | tr '\n' ';')"
    echo "  若确实是换机/重装，请更新 DEPLOY106_HOST_FINGERPRINT 后再跑"
    exit 2
  fi
  cp "$scan" "$known"
  echo "主机身份已钉：$FP"
else
  echo "::warning::未设 DEPLOY106_HOST_FINGERPRINT，本次跳过指纹校验（不推荐长期如此）"
  ssh-keyscan -p "$PORT" -T 8 "$DEPLOY106_HOST" > "$known" 2>/dev/null || : > "$known"
fi

# ---- 执行：命令走 stdin，避免多层引号被本地 shell 吃掉 ----
REMOTE_SHELL="bash -s"
if [ "$USE_SUDO" = "1" ]; then
  REMOTE_SHELL="sudo -n bash -s"
  echo "以 sudo 执行"
fi

HOSTKEY_ALG="${HOSTKEY_ALG:-}"
set +e
printf '%s\n' "$REMOTE_CMD" | ssh \
  -i "$keyfile" -p "$PORT" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=4 \
  -o UserKnownHostsFile="$known" \
  -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=yes \
  ${HOSTKEY_ALG:+-o HostKeyAlgorithms="$HOSTKEY_ALG"} \
  -o LogLevel=ERROR \
  "$APP_USER@$DEPLOY106_HOST" "$REMOTE_SHELL"
rc=$?
set -e
exit "$rc"
