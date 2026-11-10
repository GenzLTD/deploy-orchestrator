#!/usr/bin/env bash
# ============================================================================
# 目标机引导脚本  bootstrap.sh  v2.3
#
# 职责边界（刻意窄）：
#   本脚本只装「基础设施」——OS 包、目录、systemd 单元、nginx 站点、ufw、.env 骨架。
#   代码与 venv 由各仓 CI 负责；外部凭据人工填 .env，本脚本绝不外传。
#
# 为什么要 v2：
#   v1 把 Ubuntu 本机快照写死（/home/ubuntu、ubuntu:ubuntu、端口 5200/5300/5211、
#   python3.12、rm sites-enabled/default），只在一台装好的机器上「碰巧」能跑。
#   在一台有既有服务的机器上（预发/共存）会失败，且部分失败不可逆。
#   v2 全部改为参数 + 预检 + 可演练，见 --help。
#
# 运行位置（v2.1 起强制）：
#   preflight / infra / secrets / verify  → 只能在目标 Linux 机（106 或 FRA）上跑
#   render                                → 任意机器可跑（Mac/Win 自动进入离线模式）
#   在非 Linux 主机上跑前四个命令会直接 FATAL，不再拿「用户不存在：ubuntu」冒充演练失败。
#
# 用法：
#   sudo ./bootstrap.sh preflight              # 只体检，不改任何东西
#   sudo ./bootstrap.sh infra                  # 装基础设施（幂等）
#        ./bootstrap.sh secrets                # 生成/校对 .env 骨架
#        ./bootstrap.sh verify                 # 健康检查（需 CI 部署完成）
#   sudo ./bootstrap.sh all                    # preflight → infra → secrets
#        ./bootstrap.sh render --out=/tmp/r    # 只渲染配置，用于 diff 校对（可离线）
#
# 常用开关：
#   --user=ubuntu          运行用户（默认自动探测：ubuntu > uid1000 > root）
#   --base=/home/ubuntu    应用根目录（默认取该用户家目录）
#   --looma-port=5200      宿主端口
#   --core-port=5300       核端口
#   --gfcc-port=5211       GFCC 端口
#   --unit-prefix=shadow-  单元名前缀（演练 coexist 用，避免覆盖既有单元）
#   --wp-upstream=45.76.84.90  门户 /wp-json 上游；留空则整段不渲染
#   --no-nginx             不碰 nginx
#   --take-default         允许抢占 80 default_server（会删 sites-enabled/default）
#   --no-ppa               禁止添加 deadsnakes PPA
#   --dry-run              只打印将执行的动作
#   --offline              不做任何本机校验（不查用户/不读 os-release）；render 在非 Linux 上自动开启
#   --force                端口/文件冲突时不中止（谨慎）
# ============================================================================
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 刻意不叫 VERSION：preflight 会 source /etc/os-release，那个文件里也有 VERSION
KIT_VERSION="2.3.0"
TS="$(date +%Y%m%d-%H%M%S)"
# 允许用环境变量伪造主机类型：仅用于在 Linux 上回归「站错机器」分支，正常运行不要设
HOST_OS="${BOOTSTRAP_HOST_OS:-$(uname -s 2>/dev/null || echo unknown)}"

# ---------------------------------------------------------------- 默认参数
APP_USER=""
APP_BASE=""
APP_GROUP=""
UNIT_PREFIX=""
LOOMA_PORT=5200
CORE_PORT=5300
GFCC_PORT=5211
NGINX_MODE=auto          # auto | skip
WP_UPSTREAM=""
PORTAL_ROOT="/var/www/szbolent.com/dist"
CERTBOT_ROOT="/var/www/certbot"
PYTHON_VERSION="3.12"
PYTHON_BIN=""
WITH_PPA=auto            # auto | no
TAKE_DEFAULT=0
DRY_RUN=0
OFFLINE=0
FORCE=0
TARGET_OS_HINT=""

say()  { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap] WARN: $*" >&2; }
die()  { echo "[bootstrap] FATAL: $*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "    [dry] $*"
    return 0
  fi
  "$@"
}

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "命令：preflight | infra | secrets | verify | render | all"
}

# ---------------------------------------------------------------- 本机覆盖
# kit.conf 必须在参数解析**之前**加载，这样命令行才能覆盖它。
# v2.1 及以前把它放在参数循环之后，而 kit.conf.example 用的是裸赋值，
# 结果是「写在后面、执行在前面」——命令行被静默盖掉，且没有任何提示。
# 106 上恰好没有 kit.conf 所以没炸；从 FRA 拷一份过去就会改了端口却看不出来。
if [ -f "$KIT_DIR/kit.conf" ]; then
  # shellcheck disable=SC1091
  . "$KIT_DIR/kit.conf"
  say "已加载 $KIT_DIR/kit.conf（命令行仍优先）"
fi

# ---------------------------------------------------------------- 参数解析
CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user=*)         APP_USER="${1#*=}" ;;
    --base=*)         APP_BASE="${1#*=}" ;;
    --looma-port=*)   LOOMA_PORT="${1#*=}" ;;
    --core-port=*)    CORE_PORT="${1#*=}" ;;
    --gfcc-port=*)    GFCC_PORT="${1#*=}" ;;
    --unit-prefix=*)  UNIT_PREFIX="${1#*=}" ;;
    --wp-upstream=*)  WP_UPSTREAM="${1#*=}" ;;
    --portal-root=*)  PORTAL_ROOT="${1#*=}" ;;
    --python=*)       PYTHON_VERSION="${1#*=}" ;;
    --no-nginx)       NGINX_MODE=skip ;;
    --take-default)   TAKE_DEFAULT=1 ;;
    --no-ppa)         WITH_PPA=no ;;
    --dry-run)        DRY_RUN=1 ;;
    --offline)        OFFLINE=1 ;;
    --force)          FORCE=1 ;;
    --out=*)          RENDER_OUT="${1#*=}" ;;
    -h|--help)        usage; exit 0 ;;
    preflight|infra|secrets|verify|render|all) CMD="$1" ;;
    *) die "未知参数：${1}（--help 查看用法）" ;;
  esac
  shift
done

[ -n "$CMD" ] || { usage; exit 1; }

# ---------------------------------------------------------------- 运行位置守卫
# 2026-11-10 事故：在 Mac 上按手册跑 preflight/infra/render，三条都停在
# 「用户不存在：ubuntu」——这台机器本来就没有 ubuntu 用户，也没有 /etc/os-release。
# 那不是演练失败，是「站错了机器」。现在在动手前就把话说清楚；
# render 是纯文本替换，与主机无关，非 Linux 上自动切离线模式。
if [ "${HOST_OS:-unknown}" != "Linux" ]; then
  if [ "$CMD" = "render" ] && [ "$OFFLINE" = "0" ]; then
    OFFLINE=1
    warn "当前主机是 ${HOST_OS}（非 Linux）：render 自动进入离线模式，只做文本替换"
  elif [ "$CMD" != "render" ]; then
    echo "[bootstrap] FATAL: 当前主机是 ${HOST_OS}，不是目标机（Linux）。" >&2
    echo "" >&2
    echo "  preflight / infra / secrets / verify 读的是本机的用户、os-release、端口、systemd，" >&2
    echo "  在本机跑等于「拿 Mac 冒充 106」，结果没有意义。请在目标机上执行：" >&2
    echo "    ssh ubuntu@106.52.73.17" >&2
    echo "    sudo ./bootstrap.sh $CMD ..." >&2
    echo "" >&2
    echo "  只想在这台机器上校对配置（不碰本机）就用 render：" >&2
    echo "    ./bootstrap.sh render --offline --user=ubuntu --base=/home/ubuntu \\" >&2
    echo "        --looma-port=5200 --core-port=5300 --gfcc-port=5211 --take-default \\" >&2
    echo "        --wp-upstream=45.76.84.90 --out=./rendered" >&2
    exit 3
  fi
fi

# ---------------------------------------------------------------- 变量归一
resolve_vars() {
  if [ "$OFFLINE" = "1" ]; then
    # 离线模式：只按参数推导，不查本机（Mac/Win 上没有 ubuntu 用户，也不该有）
    [ -n "$APP_USER" ] || APP_USER="ubuntu"
    [ -n "$APP_BASE" ] || APP_BASE="/home/$APP_USER"
    APP_GROUP="$APP_USER"
    LOOMA_DIR="$APP_BASE/looma"
    THOMAS_DIR="$APP_BASE/thomas"
    GFCC_DIR="$APP_BASE/gfcc-kernel"
    U_LOOMA="${UNIT_PREFIX}looma-backend"
    U_CORE="${UNIT_PREFIX}thomas-core"
    U_GFCC="${UNIT_PREFIX}gfcc-kernel"
    return 0
  fi
  if [ -z "$APP_USER" ]; then
    if id ubuntu >/dev/null 2>&1; then
      APP_USER=ubuntu
    elif id -un 1000 >/dev/null 2>&1; then
      APP_USER="$(id -un 1000)"
    else
      APP_USER="$(id -un)"
    fi
  fi
  id "$APP_USER" >/dev/null 2>&1 || die "用户不存在：${APP_USER}（目标机没有这个用户；若只想校对配置用 render --offline）"
  APP_GROUP="$(id -gn "$APP_USER")"
  if [ -z "$APP_BASE" ]; then
    APP_BASE="$(getent passwd "$APP_USER" | cut -d: -f6)"
  fi
  [ -n "$APP_BASE" ] || die "无法确定 $APP_USER 的家目录，请用 --base="

  LOOMA_DIR="$APP_BASE/looma"
  THOMAS_DIR="$APP_BASE/thomas"
  GFCC_DIR="$APP_BASE/gfcc-kernel"

  # 前缀同时决定单元名与 .env 路径隔离，避免演练踩到既有服务
  U_LOOMA="${UNIT_PREFIX}looma-backend"
  U_CORE="${UNIT_PREFIX}thomas-core"
  U_GFCC="${UNIT_PREFIX}gfcc-kernel"
}
resolve_vars

# ---------------------------------------------------------------- 渲染
render_file() {  # render_file <src.in> <dst> [extra-sed...]
  local src="$1" dst="$2"; shift 2
  # 演练模式下默认不落盘：否则目标目录还没建，重定向会直接失败。
  # 但输出目录若已存在（install_rendered 用的 mktemp 文件就是），就照常渲染——
  # 否则 install_prepared 的幂等比对拿到空文件，--dry-run 会永远报「会写入」，
  # 演练预告与真跑结果对不上，「先 dry-run 看一眼」就白看了（106 上实测过这个坑）。
  if [ "$DRY_RUN" = "1" ] && [ ! -d "$(dirname "$dst")" ]; then
    echo "    [dry] 渲染 $(basename "$src") → $dst"
    return 0
  fi
  sed -e "s|@APP_USER@|$APP_USER|g" \
      -e "s|@APP_GROUP@|$APP_GROUP|g" \
      -e "s|@APP_BASE@|$APP_BASE|g" \
      -e "s|@LOOMA_DIR@|$LOOMA_DIR|g" \
      -e "s|@THOMAS_DIR@|$THOMAS_DIR|g" \
      -e "s|@GFCC_DIR@|$GFCC_DIR|g" \
      -e "s|@LOOMA_PORT@|$LOOMA_PORT|g" \
      -e "s|@CORE_PORT@|$CORE_PORT|g" \
      -e "s|@GFCC_PORT@|$GFCC_PORT|g" \
      -e "s|@WP_UPSTREAM@|$WP_UPSTREAM|g" \
      -e "s|@PORTAL_ROOT@|$PORTAL_ROOT|g" \
      -e "s|@CERTBOT_ROOT@|$CERTBOT_ROOT|g" \
      "$@" "$src" > "$dst"
}

# 处理被标记的可选段：标记行本身永远不输出；
# keep=0（值空）时连段内内容一起剔除，keep=1 时保留内容。
host_block() {  # host_block <file> <MARK> <value>
  local f="$1" mark="$2" val="$3" keep=0
  [ -f "$f" ] || return 0
  if [ -n "$val" ]; then keep=1; fi
  awk -v m="$mark" -v keep="$keep" '
    $0 ~ ("# >>> " m "_BEGIN") { skipping = (keep == 0); next }
    $0 ~ ("# <<< " m "_END")   { skipping = 0; next }
    !skipping { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# 兼容旧名
strip_if_empty() { host_block "$@"; }

# ---------------------------------------------------------------- 预检
port_state() {  # port_state <port>  → free | busy:<procname>
  local p="$1" line proc
  line="$(ss -ltnp 2>/dev/null | awk -v pat=":$p\$" '$4 ~ pat {print; exit}' || true)"
  if [ -z "$line" ]; then echo free; return; fi
  proc="$(printf '%s' "$line" | grep -oE 'users:\(\("[^"]+' | sed 's/.*"//' | head -1 || true)"
  echo "busy:${proc:-unknown}"
}

unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# 同名单元不一定是「自己的」：FRA 上就有个既有 gfcc-kernel 指向 /data/gfcc。
# 只靠名字判断会在别人的机器上静默覆盖在跑的服务，所以要比对 WorkingDirectory。
unit_workdir() { systemctl show -p WorkingDirectory --value "$1" 2>/dev/null || true; }

unit_is_ours() {  # unit_is_ours <unit> <expected-workdir>
  local u="$1" want="$2" wd
  unit_active "$u" || return 1
  wd="$(unit_workdir "$u")"
  [ -n "$wd" ] && [ "$wd" = "$want" ]
}

expected_workdir() {  # expected_workdir <LOOMA|CORE|GFCC>
  case "$1" in
    LOOMA) echo "$LOOMA_DIR/current/backend" ;;
    CORE)  echo "$THOMAS_DIR/current/backend" ;;
    GFCC)  echo "$GFCC_DIR" ;;
  esac
}

nginx_default_owners() {
  grep -Rl "listen[[:space:]][^;]*default_server" \
      /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null || true
}

preflight() {
  local fail=0
  say "=== preflight（v${KIT_VERSION}）==="
  say "目标：user=$APP_USER group=$APP_GROUP base=$APP_BASE"
  say "端口：looma=$LOOMA_PORT core=$CORE_PORT gfcc=$GFCC_PORT  nginx=$NGINX_MODE  prefix='${UNIT_PREFIX}'"

  # root
  if [ "$(id -u)" = "0" ]; then
    say "权限：root ✅"
  else
    warn "非 root：infra/secrets 需要 sudo"; fail=1
  fi

  # OS
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    TARGET_OS_HINT="${PRETTY_NAME:-unknown}"
    say "OS：${TARGET_OS_HINT}（$ID ${VERSION_CODENAME}）"
    case "${VERSION_ID:-}" in
      22.04|24.04) say "  → 22.04 需要 deadsnakes 才能装 python${PYTHON_VERSION}；24.04 自带" ;;
      *) warn "未验证的 OS 版本：${VERSION_ID:-?}（脚本按 Debian 系写）" ;;
    esac
  else
    warn "无 /etc/os-release，可能不是 Debian 系"; fail=1
  fi

  # python
  if command -v "python$PYTHON_VERSION" >/dev/null 2>&1; then
    PYTHON_BIN="python$PYTHON_VERSION"
    say "python：$(command -v "$PYTHON_BIN") → $("$PYTHON_BIN" -V 2>&1) ✅"
  else
    say "python：缺 python${PYTHON_VERSION}（系统为 $(python3 -V 2>&1)）"
    if [ "$WITH_PPA" = "no" ]; then
      warn "已禁用 PPA，只能用系统 python3（代码若需 3.12 会失败）"
    else
      say "  → infra 阶段将尝试 apt 直装，失败则加 deadsnakes PPA"
    fi
  fi

  # python3-venv（22.04 的 3.12 需要独立包）
  if ! python3 -c "import venv" >/dev/null 2>&1; then
    warn "系统缺 venv 模块，infra 会装 python3-venv"; fi

  # 端口：区分「被本套件单元占着」（正常重入）与「被别人占着」（阻断）
  local p st who own rest unit
  for pair in "LOOMA:$LOOMA_PORT:$U_LOOMA" "CORE:$CORE_PORT:$U_CORE" "GFCC:$GFCC_PORT:$U_GFCC"; do
    who="${pair%%:*}"; rest="${pair#*:}"; p="${rest%%:*}"; unit="${rest#*:}"
    st="$(port_state "$p")"
    if [ "$st" = "free" ]; then
      say "端口 ${p}（${who}）：空闲 ✅"
      continue
    fi
    own=0
    if unit_is_ours "$unit" "$(expected_workdir "$who")"; then
      own=1
    elif unit_active "$unit"; then
      warn "  同名单元 $unit 指向 $(unit_workdir "$unit")，不是本套件的 $(expected_workdir "$who")"
      warn "  → 这是既有服务，infra 会拒绝覆盖（除非 --force）；请用 --unit-prefix 或换端口"
      fail=1
      continue
    fi
    if [ "$own" = "1" ]; then
      say "端口 ${p}（${who}）：由 $unit 占用，属正常重入 ✅"
    else
      warn "端口 ${p}（${who}）已被别的进程占用 → ${st#busy:}"
      if [ "$UNIT_PREFIX" = "" ]; then
        warn "  同端口上跑着非本套件的服务。要与既有栈共存，请改端口（如 --looma-port=6200）"
      else
        warn "  演练前缀 '${UNIT_PREFIX}' 下仍被占，请再换端口"
      fi
      fail=1
    fi
  done

  # nginx 冲突
  if [ "$NGINX_MODE" = "skip" ]; then
    say "nginx：已跳过 ✅"
  else
    local owners
    owners="$(nginx_default_owners | tr '\n' ' ')"
    if [ -n "$owners" ]; then
      say "nginx：已存在 default_server → $owners"
      if [ "$TAKE_DEFAULT" = "1" ]; then
        warn "  --take-default：将删除 sites-enabled/default 并抢占 80（原站点会被摘掉）"
      else
        say "  → 本套件站点将渲染为普通 listen 80（不抢 default），IP 直连仍进原站点"
      fi
    else
      say "nginx：无 default_server，本套件站点将接管 80 ✅"
    fi
  fi

  # 磁盘
  local avail
  avail="$(df -Pk / | awk 'NR==2{print int($4/1024/1024)}')"
  if [ "${avail:-0}" -lt 5 ]; then
    warn "根分区可用 ${avail}G < 5G"; fail=1
  else
    say "磁盘：可用 ${avail}G ✅"
  fi

  # 已有同名单元：必须分清「上次部署留下的」和「别的栈在跑的」
  local u wd want
  for pair in "$U_LOOMA|LOOMA" "$U_CORE|CORE" "$U_GFCC|GFCC"; do
    u="${pair%%|*}"; want="$(expected_workdir "${pair##*|}")"
    [ -f "/etc/systemd/system/$u.service" ] || continue
    wd="$(unit_workdir "$u")"
    if [ -n "$wd" ] && [ "$wd" != "$want" ]; then
      warn "单元 $u.service 已存在但指向 ${wd}（非本套件 ${want}）"
      warn "  → 这是别人的服务，infra 会拒绝覆盖；请用 --unit-prefix=shadow- 隔离"
      fail=1
    else
      say "单元已存在：$u.service（本套件的，infra 会先备份后重渲染）"
    fi
  done
  if [ -d "/etc/systemd/system/${U_CORE}.service.d" ]; then
    say "drop-in 已存在：${U_CORE}.service.d（会被更新，原文件备份）"
  fi
  # 三个 drop-in 目录里只要有一个 zz-kit.conf，就说明本套件接管了 EnvironmentFile 清单
  local d
  for d in "$U_LOOMA" "$U_CORE" "$U_GFCC"; do
    if [ -f "/etc/systemd/system/${d}.service.d/zz-kit.conf" ]; then
      say "env 清单由 drop-in 接管：${d}.service.d/zz-kit.conf（CI 重写主单元也不影响）"
    fi
  done

  if [ "$fail" = "1" ]; then
    warn "preflight 有阻断项（--force 可忽略非致命项）"
    [ "$FORCE" = "1" ] || exit 2
  else
    say "=== preflight 通过 ==="
  fi
}

# ---------------------------------------------------------------- infra
install_packages() {
  say "安装 OS 依赖"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -qq || warn "apt-get update 有告警（继续）"

  run apt-get install -y -qq nginx rsync sqlite3 openssl curl ca-certificates tcpdump \
    || die "基础包安装失败"
  say "基础包：nginx rsync sqlite3 openssl curl ca-certificates tcpdump ✅"

  install_python
}

install_python() {
  local want="python$PYTHON_VERSION" wantv="python$PYTHON_VERSION-venv"

  if command -v "$want" >/dev/null 2>&1; then
    PYTHON_BIN="$want"
    say "python$PYTHON_VERSION 已存在：$("$want" -V 2>&1)"
    # 22.04 的 deadsnakes 版本需要单独装 venv 包
    if ! "$want" -c "import venv" >/dev/null 2>&1; then
      run apt-get install -y -qq "$wantv" || warn "$wantv 安装失败，venv 可能不可用"
    fi
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    say "[dry] 将安装 $want / $wantv"
    PYTHON_BIN="$want"
    return 0
  fi

  # 第一次：直接装（24.04 或已加源）
  if apt-get install -y -qq "$want" "$wantv" >/dev/null 2>&1; then
    PYTHON_BIN="$want"
    say "$want 安装成功 ✅"
    return 0
  fi

  # 第二次：加 deadsnakes（22.04 需要）
  if [ "$WITH_PPA" != "no" ]; then
    say "官方源无 ${want}，尝试 deadsnakes PPA"
    apt-get install -y -qq software-properties-common >/dev/null 2>&1 || true
    if add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      if apt-get install -y -qq "$want" "$wantv" >/dev/null 2>&1; then
        PYTHON_BIN="$want"
        say "$want 经 deadsnakes 安装成功 ✅"
        return 0
      fi
    fi
  fi

  # 降级
  warn "无法获得 ${want}，降级到 $(python3 -V 2>&1)"
  warn "  代码若依赖 3.12 语法会失败；CI 的 venv 也会用这个解释器"
  apt-get install -y -qq python3-venv >/dev/null 2>&1 || true
  PYTHON_BIN="python3"
}

make_dirs() {
  say "创建目录骨架"
  local p
  # 父目录必须先归位。以前只 chown 了 data/logs/bin 三个子目录，
  # 而 mkdir -p 顺手建出来的 $LOOMA_DIR 本身是 root:root ——
  # 空机上 CI 以 $APP_USER 身份在它里面建 releases/current 就会 Permission denied，
  # 表现为「infra 全绿、第一次部署必挂」。
  for p in "$LOOMA_DIR" "$THOMAS_DIR" "$GFCC_DIR" "$PORTAL_ROOT" "$CERTBOT_ROOT"; do
    if [ -d "$p" ]; then
      run chown "$APP_USER:$APP_GROUP" "$p"      # 已存在：只改属主，不硬改权限
    else
      run install -d -o "$APP_USER" -g "$APP_GROUP" -m 755 "$p"
    fi
  done
  local d
  for d in "$LOOMA_DIR"/{data,logs,bin} "$THOMAS_DIR"/{data,logs,bin} \
           "$GFCC_DIR"/{logs,bin} "$PORTAL_ROOT" "$CERTBOT_ROOT"; do
    run mkdir -p "$d"
    run chown "$APP_USER:$APP_GROUP" "$d"
  done
  run chown -R "$APP_USER:$APP_GROUP" "$PORTAL_ROOT" "$CERTBOT_ROOT" 2>/dev/null || true
  run chmod 700 "$LOOMA_DIR/data"
  run chmod 750 "$THOMAS_DIR/data"
  say "目录：$LOOMA_DIR / $THOMAS_DIR / $GFCC_DIR / $PORTAL_ROOT ✅"
}

# 渲染并安装一个文件：内容与现有一致就完全不动（幂等，不堆 .bak）
install_prepared() {  # install_prepared <已渲染临时文件> <dst> <mode> <label>
  local tmpf="$1" dst="$2" mode="$3" label="$4"
  # 幂等比对在 dry-run 下也要做。v2.2 及以前这里是 `[ "$DRY_RUN" = 0 ] && cmp`，
  # 于是 --dry-run 永远报「会写入」——演练预告与真跑结果对不上，
  # 「先 dry-run 看一眼」就失去意义（106 上实测：内容一字未变也照样打印 8 条写入）。
  if [ -f "$dst" ] && cmp -s "$tmpf" "$dst"; then
    say "  ${label}：无变化 ✅"
    rm -f "$tmpf"
    return 0
  fi
  if [ -f "$dst" ]; then
    run cp -a "$dst" "$dst.bak-$TS"
    say "  已备份 → $dst.bak-$TS"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "    [dry] 写入 $dst"
    rm -f "$tmpf"
  else
    install -m "$mode" "$tmpf" "$dst"
    rm -f "$tmpf"
  fi
  say "  ${label}：已写入 ✅"
}

install_rendered() {  # install_rendered <tpl> <dst> <mode> <label>
  local tpl="$1" dst="$2" mode="$3" label="$4" tmpf
  tmpf="$(mktemp)"
  render_file "$tpl" "$tmpf"
  install_prepared "$tmpf" "$dst" "$mode" "$label"
}

install_unit() {  # install_unit <名字> <模板> <目标目录> [期望 WorkingDirectory]
  local name="$1" tpl="$2" dir="$3" want="${4:-}"
  local dst="$dir/$name.service"

  # 已存在同名单元：若它指向别的目录，说明是别的栈的服务，绝不静默覆盖
  if [ -f "$dst" ] && [ -n "$want" ]; then
    local wd
    wd="$(unit_workdir "$name")"
    if [ -n "$wd" ] && [ "$wd" != "$want" ] && [ "$FORCE" != "1" ]; then
      warn "单元 $name.service 已存在，WorkingDirectory=${wd}，不是本套件的 $want"
      die "拒绝覆盖既有服务。改用 --unit-prefix（如 shadow-）或确认后 --force"
    fi
  fi
  install_rendered "$tpl" "$dst" 644 "单元 $name.service"
}

install_systemd() {
  say "渲染 systemd 单元"
  install_unit "$U_LOOMA" "$KIT_DIR/systemd/looma-backend.service.in" /etc/systemd/system "$LOOMA_DIR/current/backend"
  install_unit "$U_CORE"  "$KIT_DIR/systemd/thomas-core.service.in"  /etc/systemd/system "$THOMAS_DIR/current/backend"
  install_unit "$U_GFCC"  "$KIT_DIR/systemd/gfcc-kernel.service.in"  /etc/systemd/system "$GFCC_DIR"

  # drop-in 才是抗 CI 重写的落点（主单元会被各仓部署脚本重装）
  install_dropin "$U_LOOMA" "$LOOMA_DIR/.env"  "$LOOMA_DIR/deploy.env"  0 "drop-in ${U_LOOMA}.service.d/zz-kit.conf"
  install_dropin "$U_CORE"  "$THOMAS_DIR/.env" "$THOMAS_DIR/deploy.env" 0 "drop-in ${U_CORE}.service.d/zz-kit.conf"
  install_dropin "$U_GFCC"  "$GFCC_DIR/.env"   ""                       1 "drop-in ${U_GFCC}.service.d/zz-kit.conf"

  local drop="/etc/systemd/system/${U_CORE}.service.d"
  run mkdir -p "$drop"
  install_rendered "$KIT_DIR/systemd/ledger.conf.in" "$drop/ledger.conf" 644 "drop-in ${U_CORE}.service.d/ledger.conf"

  run systemctl daemon-reload
}

render_dropin_to() {  # render_dropin_to <dst> <env1> <env2> <keep-extra-env:0|1>
  local dst="$1" e1="$2" e2="$3" keep="$4"
  render_file "$KIT_DIR/systemd/zz-kit.conf.in" "$dst" \
    -e "s|@ENVFILE1@|$e1|g" -e "s|@ENVFILE2@|$e2|g"
  host_block "$dst" "ENVFILE2" "$e2"
  if [ "$keep" = "1" ]; then
    host_block "$dst" "EXTRA_ENV" "1"
  else
    host_block "$dst" "EXTRA_ENV" ""
  fi
}

install_dropin() {  # install_dropin <unit> <envfile1> <envfile2> <keep-extra-env:0|1> <label>
  local u="$1" e1="$2" e2="$3" keep="$4" label="$5"
  local drop="/etc/systemd/system/${u}.service.d"
  local dst="$drop/zz-kit.conf" tmpf
  run mkdir -p "$drop"
  tmpf="$(mktemp)"
  render_dropin_to "$tmpf" "$e1" "$e2" "$keep"
  install_prepared "$tmpf" "$dst" 644 "$label"
}

install_nginx() {
  if [ "$NGINX_MODE" = "skip" ]; then
    say "跳过 nginx（--no-nginx）"
    return 0
  fi

  local avail=/etc/nginx/sites-available enabled=/etc/nginx/sites-enabled
  local tpl="$KIT_DIR/nginx/looma.conf.in"
  local tmp; tmp="$(mktemp -d)"

  # 决定 looma 站点是否抢 default_server。
  # 模板里是 `listen 80@DEFAULT_FLAG@;`，所以值带前导空格；空串时渲染成 `listen 80;`
  local default_flag="" owners
  owners="$(nginx_default_owners | grep -v "looma.conf" | tr '\n' ' ' || true)"
  if [ "$TAKE_DEFAULT" = "1" ]; then
    default_flag=" default_server"
  elif [ -z "$owners" ]; then
    default_flag=" default_server"
    say "无既有 default_server → looma 站点接管 80 默认"
  else
    warn "已存在 default_server（${owners}），本套件站点不抢默认（IP 直连仍进原站点）"
  fi

  render_file "$tpl" "$tmp/looma.conf" -e "s|@DEFAULT_FLAG@|$default_flag|g"
  render_file "$KIT_DIR/nginx/szbolent.com.conf.in" "$tmp/szbolent.com.conf"
  strip_if_empty "$tmp/szbolent.com.conf" "WP_UPSTREAM" "$WP_UPSTREAM"

  # 备份 → 安装 → 测试 → 失败回滚。内容没变就不动文件（幂等）
  local f changed=0
  for f in looma.conf szbolent.com.conf; do
    if [ -f "$avail/$f" ] && cmp -s "$tmp/$f" "$avail/$f"; then   # dry-run 也比对，理由同上
      say "  nginx ${f}：无变化 ✅"
      continue
    fi
    changed=1
    if [ -f "$avail/$f" ]; then run cp -a "$avail/$f" "$avail/$f.bak-$TS"; fi
    run install -m 644 "$tmp/$f" "$avail/$f"
    run ln -sfn "$avail/$f" "$enabled/$f"
  done

  if [ "$TAKE_DEFAULT" = "1" ] && [ -f "$enabled/default" ]; then
    run cp -a "$enabled/default" "/etc/nginx/sites-available/default.bak-$TS"
    run rm -f "$enabled/default"
    say "已摘除 sites-enabled/default（备份在 sites-available/default.bak-${TS}）"
  fi

  if [ "$DRY_RUN" = "0" ] && [ "$changed" = "1" ]; then
    if ! nginx -t 2>"$tmp/err"; then
      warn "nginx -t 失败，回滚："
      sed 's/^/    /' "$tmp/err" >&2
      for f in looma.conf szbolent.com.conf; do
        if [ -f "$avail/$f.bak-$TS" ]; then
          cp -a "$avail/$f.bak-$TS" "$avail/$f"
        else
          rm -f "$avail/$f" "$enabled/$f"
        fi
      done
      rm -rf "$tmp"
      die "nginx 配置未生效，已恢复原状"
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    say "nginx：已 reload ✅"
  fi
  rm -rf "$tmp"
  say "nginx：looma.conf + szbolent.com.conf 就位 ✅"
}

ufw_note() {
  say "ufw：只读检查（不改规则）"
  if ! command -v ufw >/dev/null 2>&1; then
    say "  未安装 ufw，跳过"; return 0
  fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    say "  当前已启用，已放行：$(ufw status 2>/dev/null | awk '/ALLOW/{printf "%s ", $1}')"
  else
    say "  当前未启用"
  fi
  say "  注意：公网边界在云安全组/Vultr Firewall，ufw 只是第二层；本脚本不擅自放行端口"
}

infra() {
  say "=== infra ==="
  install_packages
  make_dirs
  install_systemd
  install_nginx
  ufw_note

  say "启用单元（只 enable，不 start——代码要等首次 CI 部署）"
  run systemctl enable "$U_LOOMA" "$U_CORE" "$U_GFCC" >/dev/null 2>&1 || true
  say "=== infra 完成 ==="
  say "下一步：./bootstrap.sh secrets → 触发 CI 首次部署 → ./bootstrap.sh verify"
}

# ---------------------------------------------------------------- secrets
gen_hex() { openssl rand -hex "$1"; }

ensure_env() {  # ensure_env <目标> <模板> <本文件私有生成的键,逗号分隔>
  local path="$1" tpl="$2" own="${3:-}" tmp k
  if [ -f "$path" ]; then
    say "已存在，不覆盖：$path"
    return 0
  fi
  say "创建：$path"
  tmp="$(mktemp)"
  render_file "$tpl" "$tmp"
  # 关键：只有「本文件私有」的键才现场生成。
  # 三份 .env 若各自生成 JWT_SECRET/ETHOS，奇偶校验必然失败——
  # 共享密钥一律由 looma 生成、其余两份用 copy_key 抄过去。
  while IFS= read -r line; do
    k="${line%%=*}"
    case ",$own," in
      *",$k,"*)
        case "$k" in
          SECRET_KEY)           echo "SECRET_KEY=$(gen_hex 32)"; continue ;;
          JWT_SECRET)           echo "JWT_SECRET=$(gen_hex 48)"; continue ;;
          ETHOS_AUTH_SECRET)    echo "ETHOS_AUTH_SECRET=$(gen_hex 32)"; continue ;;
          SIGNAL_INGEST_SECRET) echo "SIGNAL_INGEST_SECRET=$(gen_hex 32)"; continue ;;
        esac
        ;;
    esac
    echo "$line"
  done < "$tmp" > "${tmp}.out"
  if [ "$DRY_RUN" = "1" ]; then
    say "  [dry] 写入 ${path}（$(grep -c . "${tmp}.out") 行）"
  else
    install -m 600 "${tmp}.out" "$path"
    chown "$APP_USER:$APP_GROUP" "$path"
  fi
  rm -f "$tmp" "${tmp}.out"
}

set_env_key() {  # set_env_key <file> <key> <value>
  # v2.1：原来的 sed 版在值里含 & 时会被当成「整个匹配」而截断，
  # 含 / 时（用 | 分隔虽不炸但）与其他调用不一致；改用 python 逐行改写，
  # 且键不存在时会追加——原来 sed 匹配不到就静默什么都不做，是更坏的 bug。
  local f="$1" k="$2" v="$3"
  if [ "$DRY_RUN" = "1" ]; then say "  [dry] 写 $k → $f"; return 0; fi
  "$PYTHON_BIN" - "$f" "$k" "$v" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); k = sys.argv[2]; v = sys.argv[3]
lines = p.read_text().splitlines() if p.exists() else []
out, hit = [], False
for line in lines:
    if line.startswith(k + "="):
        out.append(f"{k}={v}"); hit = True
    else:
        out.append(line)
if not hit:
    out.append(f"{k}={v}")
p.write_text("\n".join(out) + "\n")
PY
}

copy_key() {  # copy_key <key> <dst-env>
  local key="$1" dst="$2" v cur
  [ -f "$dst" ] || return 1
  v="$(grep "^$key=" "$LOOMA_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
  [ -n "$v" ] || return 1
  cur="$(grep "^$key=" "$dst" 2>/dev/null | head -1 | cut -d= -f2-)"
  [ -n "$cur" ] && return 0          # 目标已有值：不覆盖（避免踩人工填的真凭据）
  set_env_key "$dst" "$key" "$v"
}

check_parity() {
  "$PYTHON_BIN" - "$LOOMA_DIR/.env" "$THOMAS_DIR/.env" "$GFCC_DIR/.env" <<'PY'
import hashlib, sys
from pathlib import Path

def load(p):
    d = {}
    try:
        for line in Path(p).read_text().splitlines():
            s = line.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1)
                d[k] = v
    except FileNotFoundError:
        pass
    return d

a, b, c = (load(p) for p in sys.argv[1:4])

# v2.1 分两类：
#   crit = 机器自生成、闭环必需 —— 双方都空不是「允许」，是「生成了没抄过去」的 bug
#   ext  = 外部凭据 —— 双方都空只降级，不阻断；但一边有一边空必须报
pairs = [
    ("JWT_SECRET",            a, b, "crit"),
    ("SECRET_KEY",            a, b, "crit"),
    ("ETHOS_AUTH_SECRET",     a, b, "crit"),
    ("ETHOS_AUTH_SECRET",     a, c, "crit"),
    ("SIGNAL_INGEST_SECRET",  a, c, "crit"),
    ("WECHAT_APPID",          a, b, "ext"),
    ("WECHAT_APP_SECRET",     a, b, "ext"),
    ("WECHAT_DEV_MODE",       a, b, "ext"),
    ("DEEPSEEK_API_KEY",      a, b, "ext"),
    ("HUAWEI_CLIENT_ID",      a, b, "ext"),
    ("HUAWEI_CLIENT_SECRET",  a, b, "ext"),
]
bad, missing, empty_ext = [], [], []
for k, x, y, kind in pairs:
    who = "looma/gfcc" if y is c else "looma/thomas"
    xv, yv = x.get(k, ""), y.get(k, "")
    if xv == "" and yv == "":
        (missing if kind == "crit" else empty_ext).append(f"{k}({who})")
        continue
    if hashlib.sha256(xv.encode()).digest() != hashlib.sha256(yv.encode()).digest():
        bad.append(f"{k}({who})")

for e in empty_ext:
    print(f"PARITY_EMPTY_EXT {e}")          # 外部凭据未填：功能降级，不阻断
if bad:
    print("PARITY_FAIL " + ",".join(bad))
elif missing:
    print("PARITY_MISSING " + ",".join(missing))   # 双方都空的自生成键 = 必须修
else:
    print("PARITY_OK")
PY
}

secrets() {
  say "=== secrets ==="
  [ -n "$PYTHON_BIN" ] || PYTHON_BIN="$(command -v "python$PYTHON_VERSION" || command -v python3)"
  # 共享密钥只在宿主生成；核与 gfcc 留空，交给下面的 copy_key 抄。
  # SIGNAL_INGEST_SECRET 归宿主：gfcc 那句注释写着「Must match kernel」，原来是 gfcc 自己生成、
  # 宿主留空，等于两边必然不一致，闭环的 HMAC 校验永远过不了。
  ensure_env "$LOOMA_DIR/.env"  "$KIT_DIR/env-templates/looma.env.example"  "SECRET_KEY,JWT_SECRET,ETHOS_AUTH_SECRET,SIGNAL_INGEST_SECRET"
  ensure_env "$THOMAS_DIR/.env" "$KIT_DIR/env-templates/thomas.env.example" ""
  ensure_env "$GFCC_DIR/.env"   "$KIT_DIR/env-templates/gfcc.env.example"   ""

  say "核与 gfcc 从宿主抄齐同值键（值不外露）"
  local k
  for k in JWT_SECRET SECRET_KEY WECHAT_APPID WECHAT_APP_SECRET WECHAT_DEV_MODE \
           DEEPSEEK_API_KEY ETHOS_AUTH_SECRET HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET; do
    copy_key "$k" "$THOMAS_DIR/.env" || true
  done
  for k in ETHOS_AUTH_SECRET SIGNAL_INGEST_SECRET; do
    copy_key "$k" "$GFCC_DIR/.env" || true
  done

  if [ "$DRY_RUN" = "1" ]; then
    say "  [dry] 跳过奇偶校验"
    return 0
  fi
  chmod 600 "$LOOMA_DIR/.env" "$THOMAS_DIR/.env" "$GFCC_DIR/.env"

  local result
  result="$(check_parity)"
  printf '%s\n' "$result" | sed 's/^/  /'
  case "$result" in
    *PARITY_FAIL*)    die "奇偶校验未过（同值键不一致）：先修 .env 再继续" ;;
    *PARITY_MISSING*) die "自生成键在两边都为空（应生成却没抄过去）：先修 .env 再继续" ;;
  esac
  say "=== secrets 完成 ==="
  say "外部凭据（DEEPSEEK/微信/QCC/华为）为空时对应功能降级，不阻断启动"
}

# ---------------------------------------------------------------- verify
health_json() { curl -s -m 5 "$1" 2>/dev/null || true; }

health_field() {  # health_field <json> <key>
  printf '%s' "$1" | "$PYTHON_BIN" -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1],""))
except Exception: print("")' "$2" 2>/dev/null || true
}

verify() {
  say "=== verify（v${KIT_VERSION}）==="
  [ -n "$PYTHON_BIN" ] || PYTHON_BIN=python3
  local fail=0 s

  # 坑：systemctl is-active 在 inactive 时返回 3，配合 pipefail + set -e
  # 会让整个脚本静默退出。必须 || true 兜住；也不用再 echo，它自己会打印 inactive。
  local st
  st="$(systemctl is-active nginx 2>/dev/null || true)"
  printf "  %-18s %s\n" nginx "${st:-inactive}"

  for s in "$U_LOOMA" "$U_CORE" "$U_GFCC"; do
    st="$(systemctl is-active "$s" 2>/dev/null || true)"
    printf "  %-18s %s\n" "$s" "${st:-inactive}"
    if ! unit_active "$s"; then warn "单元未运行：$s"; fail=1; fi
  done

  local j
  j="$(health_json "http://127.0.0.1:$LOOMA_PORT/health")"
  if [ -n "$j" ]; then
    local st; st="$(health_field "$j" status)"
    if [ "$st" = "ok" ]; then say "宿主 :$LOOMA_PORT → ok ✅"
    elif [ "$st" = "degraded" ]; then warn "宿主 :$LOOMA_PORT → degraded（缺外部凭据？）"
    else warn "宿主 :$LOOMA_PORT → status='$st'"; fail=1; fi
  else
    warn "宿主 :$LOOMA_PORT 不通"; fail=1
  fi

  j="$(health_json "http://127.0.0.1:$CORE_PORT/health")"
  if [ -n "$j" ]; then
    say "核 :$CORE_PORT → $(health_field "$j" status)（bridge=$(health_field "$j" bridge_configured)）"
  else
    warn "核 :$CORE_PORT 不通"; fail=1
  fi

  j="$(health_json "http://127.0.0.1:$GFCC_PORT/health")"
  [ -n "$j" ] && say "gfcc :$GFCC_PORT → ok" || { warn "gfcc :$GFCC_PORT 不通"; fail=1; }

  # v2.2：账本落点断言。以前 verify 只验三端口，DATABASE_PATH 指向哪里从来不查，
  # 于是手册里「核的库就是 looma.db」只是一句话，没有工具兜着。
  # 优先读真实进程的 environ（= 生效值，含 drop-in 与单元两处来源），读不到再退回单元声明。
  local want_db="$LOOMA_DIR/data/looma.db" db_path="" core_pid=""
  core_pid="$(systemctl show "$U_CORE" -p MainPID --value 2>/dev/null || true)"
  [ -n "$core_pid" ] || core_pid=0
  if [ "$core_pid" != "0" ] && [ -r "/proc/$core_pid/environ" ]; then
    db_path="$(tr '\0' '\n' < "/proc/$core_pid/environ" 2>/dev/null | sed -n 's/^DATABASE_PATH=//p' | head -1 || true)"
  fi
  if [ -z "$db_path" ]; then
    db_path="$(systemctl show "$U_CORE" -p Environment --value 2>/dev/null \
               | tr ' ' '\n' | sed -n 's/^DATABASE_PATH=//p' | head -1 || true)"
  fi
  if [ -z "$db_path" ]; then
    warn "账本：读不到 DATABASE_PATH（进程与单元都没有）→ 核会用内置默认值，跑的不是宿主这本账"
    fail=1
  elif [ "$db_path" = "$want_db" ]; then
    say "账本 → $db_path ✅"
  else
    warn "账本 → ${db_path}（期望 ${want_db}）"
    fail=1
  fi

  if [ "$NGINX_MODE" != "skip" ]; then
    local code
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: szbolent.com" "http://127.0.0.1/" || true)"
    [ "$code" = "200" ] && say "门户 200 ✅" || warn "门户返回 ${code}（dist 未发布？）"
  fi

  # v2.1：原来只要响应里出现 "invalid code" 就判 ✅。那只证明宿主把请求发出去了，
  # 不证明核收到了——核挂掉/端口错/令牌不认，宿主一样回 invalid code，于是假绿。
  # 环闭合的定义是「核上留下了这次调用的痕迹」，所以用唯一探针串去核日志里找。
  local core_log="$THOMAS_DIR/logs/thomas-core.log"
  local before=0 probe_code probe
  probe_code="bootstrap-probe-$(date +%s)"
  [ -f "$core_log" ] && before="$(wc -l < "$core_log" 2>/dev/null || echo 0)"
  probe="$(curl -s -m 20 -X POST "http://127.0.0.1:$LOOMA_PORT/v1/auth/wechat" \
           -H "Content-Type: application/json" -d "{\"code\":\"$probe_code\"}" || true)"

  if ! printf '%s' "$probe" | grep -q "invalid code"; then
    warn "闭环探针：宿主侧就没走通 → $(printf '%s' "$probe" | head -c 200)"; fail=1
  else
    say "闭环探针：宿主返回 invalid code（宿主 → 核 已转发）"
    sleep 1
    # 判据分三层，从强到弱：
    #   A 核日志里出现探针串            → 最硬，但核目前只记 werkzeug 访问日志，不含入参
    #   B 探针之后核日志新增一条 wechat 认证调用 → 说明请求确实落到核并被处理（400=入参无效，符合预期）
    #   C 核日志毫无新增                → 环没闭合（宿主发了，核没落）
    local hit=0 newlines=""
    if [ -f "$core_log" ]; then
      newlines="$(tail -n +"$((before + 1))" "$core_log" 2>/dev/null || true)"
      if printf '%s' "$newlines" | grep -q "$probe_code"; then
        hit=1
      elif printf '%s' "$newlines" | grep -Eq 'POST /v1/auth/wechat'; then
        hit=2
      fi
    fi
    if [ "$hit" = "0" ] && command -v journalctl >/dev/null 2>&1 \
       && journalctl -u "$U_CORE" --since "-2 min" --no-pager 2>/dev/null | grep -q "$probe_code"; then
      hit=1
    fi
    if [ "$hit" = "1" ]; then
      say "  核日志命中探针串 $probe_code → 环闭合 ✅"
    elif [ "$hit" = "2" ]; then
      say "  核日志新增 POST /v1/auth/wechat（400）→ 请求已落到核 ✅"
      say "  （核只记访问日志、不记 code 入参，故只能确认「同一时刻有这次调用到核」，见手册 §7.10）"
    else
      warn "  探针之后核日志没有任何新增 → 环未闭合（宿主发了，核没落）"; fail=1
    fi
  fi

  [ "$fail" = "0" ] && say "=== verify 全过 ===" || die "verify 有失败项"
}

# ---------------------------------------------------------------- render
render() {
  local out="${RENDER_OUT:-$KIT_DIR/rendered-$TS}"
  mkdir -p "$out/systemd" "$out/nginx" "$out/env"
  say "渲染到 $out"

  render_file "$KIT_DIR/systemd/looma-backend.service.in" "$out/systemd/${U_LOOMA}.service"
  render_file "$KIT_DIR/systemd/thomas-core.service.in"   "$out/systemd/${U_CORE}.service"
  render_file "$KIT_DIR/systemd/gfcc-kernel.service.in"   "$out/systemd/${U_GFCC}.service"
  render_file "$KIT_DIR/systemd/ledger.conf.in"           "$out/systemd/ledger.conf"
  render_dropin_to "$out/systemd/${U_LOOMA}.service.d-zz-kit.conf" "$LOOMA_DIR/.env"  "$LOOMA_DIR/deploy.env"  0
  render_dropin_to "$out/systemd/${U_CORE}.service.d-zz-kit.conf"  "$THOMAS_DIR/.env" "$THOMAS_DIR/deploy.env" 0
  render_dropin_to "$out/systemd/${U_GFCC}.service.d-zz-kit.conf"  "$GFCC_DIR/.env"   ""                       1

  local flag=""
  if [ "$TAKE_DEFAULT" = "1" ]; then flag=" default_server"; fi
  render_file "$KIT_DIR/nginx/looma.conf.in" "$out/nginx/looma.conf" -e "s|@DEFAULT_FLAG@|$flag|g"
  render_file "$KIT_DIR/nginx/szbolent.com.conf.in" "$out/nginx/szbolent.com.conf"
  strip_if_empty "$out/nginx/szbolent.com.conf" "WP_UPSTREAM" "$WP_UPSTREAM"

  render_file "$KIT_DIR/env-templates/looma.env.example"  "$out/env/looma.env"
  render_file "$KIT_DIR/env-templates/thomas.env.example" "$out/env/thomas.env"
  render_file "$KIT_DIR/env-templates/gfcc.env.example"   "$out/env/gfcc.env"

  find "$out" -type f | sort | sed 's/^/  /'
  say "可与非 template 的线上快照 diff 校对"
}

# ---------------------------------------------------------------- 主流程
case "$CMD" in
  preflight) preflight ;;
  infra)     preflight; infra ;;
  secrets)   secrets ;;
  verify)    verify ;;
  render)    render ;;
  all)       preflight; infra; secrets; say "all 完成：请触发 CI 后再 verify" ;;
  *)         die "未知命令：$CMD" ;;
esac
