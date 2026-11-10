#!/usr/bin/env bash
# ============================================================================
# 套件自检  tests/selfcheck.sh
#
# 用途：在**任意机器**（含 Mac 自带 bash 3.2）上验证套件本身没退化。
#       只做只读检查 + 临时目录渲染，不碰本机系统，不碰线上。
#
# 为什么需要它：2026-11-10 Mac 侧实测暴露一个只有 bash 3.2 才复现的问题——
#   `$HOST_OS，` 里那个全角逗号被当成变量名的一部分（bash 3.2 不做多字节解析），
#   `set -u` 下直接 `unbound variable` 退出 1，手册承诺的「站错机器 exit 3」根本没出现。
#   这类问题在 Linux（bash 5）上永远测不出来，所以把判据写死在这里。
#
# 用法：  bash tests/selfcheck.sh          # 全部检查
#         bash tests/selfcheck.sh --quiet  # 只报结论
# 退出码：0=全过，1=有失败项
# ============================================================================
set -u

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

pass=0
failn=0
say()  { [ "$QUIET" = "1" ] || echo "  $*"; }
ok()   { pass=$((pass + 1));  [ "$QUIET" = "1" ] || echo "  ✅ $*"; }
bad()  { failn=$((failn + 1)); echo "  ❌ $*" >&2; }

echo "[selfcheck] 套件目录：${KIT_DIR}   bash：${BASH_VERSION}"

# ---------------------------------------------------------------- 1 语法
if bash -n "${KIT_DIR}/bootstrap.sh" 2>/tmp/_sc_n.err; then
  ok "bash -n bootstrap.sh 通过"
else
  bad "bash -n 失败：$(head -1 /tmp/_sc_n.err)"
fi
rm -f /tmp/_sc_n.err

# ---------------------------------------------------------------- 2 多字节变量名
# bash 3.2 会把紧跟变量的高位字节吃进变量名。所有展开必须写成 ${VAR}。
if command -v python3 >/dev/null 2>&1; then
  out="$(python3 - "${KIT_DIR}/bootstrap.sh" <<'PY'
import re, sys
pat = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])")
hits = []
for i, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if pat.search(line):
        hits.append("%d: %s" % (i, line.strip()[:80]))
print("\n".join(hits))
PY
)"
  if [ -z "$out" ]; then
    ok "无「变量紧跟中文/全角」的写法（bash 3.2 安全）"
  else
    bad "以下展开在 bash 3.2 上会变成未定义变量，请写成 \${VAR}："
    printf '%s\n' "$out" >&2
  fi
else
  say "（跳过多字节检查：本机无 python3）"
fi

# ---------------------------------------------------------------- 3 站错机器守卫
# 用环境钩子伪造非 Linux，检查四个命令是否 exit 3 且给出人话。
for c in preflight infra secrets verify; do
  mess="$(BOOTSTRAP_HOST_OS=Darwin "${KIT_DIR}/bootstrap.sh" "$c" 2>&1)"
  rc=$?
  case "$mess" in
    *"不是目标机"*) [ "$rc" = "3" ] && ok "非 Linux 上 ${c} → exit 3 并说明原因" \
                                   || bad "非 Linux 上 ${c} 退出码是 ${rc}，应为 3" ;;
    *) bad "非 Linux 上 ${c} 没走守卫（exit ${rc}）：$(printf '%s' "$mess" | head -1)" ;;
  esac
done

# ---------------------------------------------------------------- 4 render 可离线
if BOOTSTRAP_HOST_OS=Darwin "${KIT_DIR}/bootstrap.sh" render --user=ubuntu --base=/home/ubuntu \
     --take-default --wp-upstream=45.76.84.90 --out=/tmp/_sc_r >/dev/null 2>&1; then
  n="$(find /tmp/_sc_r -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -ge 10 ] && ok "非 Linux 上 render 自动离线，产出 ${n} 个文件" \
                  || bad "render 产出只有 ${n} 个文件"
else
  bad "非 Linux 上 render 失败"
fi
rm -rf /tmp/_sc_r

# ---------------------------------------------------------------- 5 kit.conf 优先级
T="$(mktemp -d)"
cp -r "${KIT_DIR}/bootstrap.sh" "${KIT_DIR}/systemd" "${KIT_DIR}/nginx" "${KIT_DIR}/env-templates" "$T"/
printf 'LOOMA_PORT=9999\nCORE_PORT=9998\n' > "$T/kit.conf"
# 命令行给了 looma 端口、没给 core 端口：两者各取一处，才证明优先级是「命令行 > kit.conf」
"$T/bootstrap.sh" render --offline --user=ubuntu --base=/home/ubuntu --looma-port=5200 --out="$T/o" \
  >/dev/null 2>&1
if [ -f "$T/o/systemd/looma-backend.service" ]; then
  got="$(find "$T/o" -type f -exec grep -ho '127\.0\.0\.1:[0-9][0-9]*' {} + 2>/dev/null \
         | sed 's/.*://' | sort -u | tr '\n' ' ')"
  case "$got" in
    *5200*9998*) ok "kit.conf 优先级正确（命令行 5200 赢、kit.conf 9998 生效）：${got}" ;;
    *)           bad "kit.conf 优先级异常，渲染端口为：${got}（期望含 5200 与 9998）" ;;
  esac
else
  bad "kit.conf 优先级测试未能渲染出单元"
fi
rm -rf "$T"

# ---------------------------------------------------------------- 汇总
echo
if [ "$failn" = "0" ]; then
  echo "[selfcheck] 全部通过（${pass} 项）"
  exit 0
fi
echo "[selfcheck] 失败 ${failn} 项，通过 ${pass} 项" >&2
exit 1
