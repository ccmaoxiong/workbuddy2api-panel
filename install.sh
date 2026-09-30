#!/usr/bin/env bash
# =============================================================================
# install.sh — workbuddy2api 一键安装（Linux 服务器：源码编译 + systemd 托管）
#
# 做什么：
#   1. 装依赖（git / curl / ca-certificates），缺少或过旧的 Go 自动装官方版
#   2. 取源码（已在仓库里就直接用；否则 git clone 到安装目录的 src/）
#   3. 在服务器本地编译静态二进制（CGO_ENABLED=0，产物不依赖 glibc）
#   4. 建 auths/ data/ 目录 + 生成 config.json（随机 api_key）
#   5. 注册 systemd 服务并启动 + 健康检查
#
# 用法（服务器上，需要 root 或 sudo）：
#   sudo bash install.sh                     # 一键装好
#   sudo bash install.sh --port 8080         # 换端口
#   sudo bash install.sh --listen 127.0.0.1:7863   # 只监听本机（配反代）
#   sudo bash install.sh --uninstall         # 卸载
#
# 一行安装（无需先 clone，脚本自己拉源码）：
#   curl -fsSL https://raw.githubusercontent.com/linguo2625469/workbuddy2api-panel/main/install.sh | sudo bash
#
# 重复执行即「原地升级」：重新拉源码 → 重新编译 → 重启服务；
# 已有 config.json / auths/ / data/ 一律保留。
# =============================================================================
set -euo pipefail

# ── 默认参数（都可用环境变量或命令行覆盖）──────────────────────────────────
APP_NAME="wb2api"
SERVICE_NAME="wb2api"
SERVICE_DESC="workbuddy2api — CodeBuddy 账号池网关 + Web 管理面板"
DEFAULT_REPO="https://github.com/linguo2625469/workbuddy2api-panel.git"
DEFAULT_BRANCH="main"
GO_MIN_VERSION="1.22.5"
# 官方源取不到版本号时的兜底版本（保证 >= GO_MIN_VERSION 且确定存在）
GO_FALLBACK_VERSION="1.22.12"
DEFAULT_GOPROXY="https://goproxy.cn,direct"
DEFAULT_TZ="Asia/Shanghai"

REPO_URL="${REPO_URL:-$DEFAULT_REPO}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
INSTALL_DIR="${INSTALL_DIR:-/opt/wb2api}"
SERVICE_USER="${SERVICE_USER:-wb2api}"
PORT="${PORT:-7863}"
HOST="${HOST:-0.0.0.0}"
API_KEY="${API_KEY:-}"
TZ_NAME="${TZ_NAME:-$DEFAULT_TZ}"
GO_VERSION="${GO_VERSION:-}"
GO_DL_BASE="${GO_DL_BASE:-https://golang.google.cn/dl}"
GOPROXY_URL="${GOPROXY_URL:-$DEFAULT_GOPROXY}"
BUILD_VERSION="${BUILD_VERSION:-}"

SRC_OPT=""
WITH_CLI=0
NO_SERVICE=0
UNINSTALL=0
PURGE=0
FORCE=0

# ── 输出helpers ────────────────────────────────────────────────────────────
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_yel=$'\033[33m'; c_blu=$'\033[36m'; c_bold=$'\033[1m'
if [ ! -t 1 ]; then c_reset=""; c_red=""; c_grn=""; c_yel=""; c_blu=""; c_bold=""; fi

log()  { printf '%s[%s]%s %s\n' "$c_blu" "$APP_NAME" "$c_reset" "$*"; }
ok()   { printf '%s[%s]%s %s\n' "$c_grn" "$APP_NAME" "$c_reset" "$*"; }
warn() { printf '%s[%s] 警告%s %s\n' "$c_yel" "$APP_NAME" "$c_reset" "$*" >&2; }
die()  { printf '%s[%s] 错误%s %s\n' "$c_red" "$APP_NAME" "$c_reset" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${c_bold}workbuddy2api 一键安装脚本${c_reset}

用法: sudo bash install.sh [选项]

安装/升级选项:
  --dir PATH           安装目录               (默认 ${INSTALL_DIR})
  --port PORT          监听端口               (默认 ${PORT})
  --host HOST          监听地址               (默认 ${HOST}；填 127.0.0.1 只对本机开放)
  --listen ADDR:PORT   直接指定完整监听地址   (覆盖 --host/--port)
  --api-key KEY        面板/网关密钥          (默认自动生成随机 32 位)
  --repo URL           源码仓库               (默认官方仓库)
  --branch NAME        分支/标签              (默认 ${DEFAULT_BRANCH})
  --source PATH        用本地已有源码目录编译 (跳过 git clone)
  --version STR        编译进二进制的版本号   (默认沿用源码里的版本)
  --user NAME          运行服务的系统用户     (默认 ${SERVICE_USER}；填 root 则以 root 运行)
  --tz ZONE            时区                   (默认 ${DEFAULT_TZ})
  --with-cli           额外编译 login / signin_bin / credit 及配套脚本
  --no-service         只编译安装，不注册 systemd 服务
  --force              端口被占用时也继续（默认遇到占用直接退出）

卸载选项:
  --uninstall          停止并移除 systemd 服务与二进制（保留数据）
  --purge              配合 --uninstall：连同 ${INSTALL_DIR} 一起删除

  -h, --help           显示本帮助

可用环境变量覆盖上面对应项（大写）: REPO_URL BRANCH INSTALL_DIR SERVICE_USER
PORT HOST API_KEY TZ_NAME GO_VERSION GO_DL_BASE GOPROXY_URL BUILD_VERSION
EOF
}

# ── 参数解析 ───────────────────────────────────────────────────────────────
parse_args() {
  local listen_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)         INSTALL_DIR="${2:?--dir 需要路径}"; shift 2 ;;
      --port)        PORT="${2:?--port 需要端口}"; shift 2 ;;
      --host)        HOST="${2:?--host 需要地址}"; shift 2 ;;
      --listen)      listen_opt="${2:?--listen 需要地址}"; shift 2 ;;
      --api-key)     API_KEY="${2:?--api-key 需要值}"; shift 2 ;;
      --repo)        REPO_URL="${2:?--repo 需要 URL}"; shift 2 ;;
      --branch)      BRANCH="${2:?--branch 需要名称}"; shift 2 ;;
      --source)      SRC_OPT="${2:?--source 需要路径}"; shift 2 ;;
      --version)     BUILD_VERSION="${2:?--version 需要值}"; shift 2 ;;
      --user)        SERVICE_USER="${2:?--user 需要用户名}"; shift 2 ;;
      --tz)          TZ_NAME="${2:?--tz 需要时区}"; shift 2 ;;
      --with-cli)    WITH_CLI=1; shift ;;
      --no-service)  NO_SERVICE=1; shift ;;
      --force)       FORCE=1; shift ;;
      --uninstall)   UNINSTALL=1; shift ;;
      --purge)       PURGE=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "未知参数: $1（用 --help 查看用法）" ;;
    esac
  done
  if [ -n "$listen_opt" ]; then
    LISTEN_ADDR="$listen_opt"
  else
    LISTEN_ADDR="${HOST}:${PORT}"
  fi
  # PORT 只是给 URL/健康检查用的展示值；以 LISTEN_ADDR 里的端口为准
  case "$LISTEN_ADDR" in
    *:*) PORT="${LISTEN_ADDR##*:}" ;;
    *)   LISTEN_ADDR=":${LISTEN_ADDR}"; PORT="${LISTEN_ADDR##*:}" ;;
  esac
  [ -n "$PORT" ] || die "无法从监听地址推断端口：$LISTEN_ADDR"
  # 安装目录统一转绝对路径：后续会在源码目录里 cd 后写产物，相对路径会跑偏
  case "$INSTALL_DIR" in
    /*) ;;
    *)  INSTALL_DIR="${PWD}/${INSTALL_DIR}" ;;
  esac
  # 路径含空格会让 systemd ExecStart 解析复杂化，直接拒绝
  case "$INSTALL_DIR" in
    *[[:space:]]*) die "安装目录不能包含空格：$INSTALL_DIR" ;;
  esac
}

# ── 基础检查 ───────────────────────────────────────────────────────────────
need_root() {
  if [ "$(id -u)" != "0" ]; then
    die "需要 root 权限：请用 sudo bash $0 ${*:-}"
  fi
}

# 版本号比较：ver_ge A B → A >= B
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

go_ver_num() {
  sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p' <<<"$1" | head -n 1
}

detect_os() {
  [ "$(uname -s)" = "Linux" ] || die "本脚本只支持 Linux 服务器（当前：$(uname -s)）"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    armv7l|armv6l) GO_ARCH="armv6l" ;;
    *) die "不支持的 CPU 架构：$ARCH" ;;
  esac

  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  elif command -v apk     >/dev/null 2>&1; then PKG=apk
  elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
  elif command -v zypper  >/dev/null 2>&1; then PKG=zypper
  else PKG=none
  fi
  log "系统：$(uname -s) $(uname -m) · 包管理器：${PKG}"
}

pkg_install() {
  [ $# -gt 0 ] || return 0
  case "$PKG" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
    dnf)    dnf install -y -q "$@" ;;
    yum)    yum install -y -q "$@" ;;
    apk)    apk add --no-cache -q "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
    zypper) zypper --non-interactive --quiet install "$@" ;;
    none)   die "系统没有可用的包管理器，请手动安装：$*" ;;
  esac
}

ensure_bash() {
  command -v bash >/dev/null 2>&1 && return 0
  log "安装 bash..."
  pkg_install bash || die "请先安装 bash 再运行本脚本"
}

ensure_tools() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  if [ ${#missing[@]} -gt 0 ]; then
    log "安装基础工具：${missing[*]}"
    pkg_install "${missing[@]}" ca-certificates
  fi
  command -v git  >/dev/null 2>&1 || die "缺少 git"
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
}

# ── Go 工具链 ──────────────────────────────────────────────────────────────
resolve_go_version() {
  # 优先问官方源当前稳定版；失败则用兜底版本
  local v=""
  v="$(curl -fsSL --max-time 10 "${GO_DL_BASE}/?mode=json" 2>/dev/null \
       | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"go\([0-9][0-9.]*\)".*/\1/p' | head -n 1)" || true
  if [ -z "$v" ]; then
    v="$(curl -fsSL --max-time 10 "https://go.dev/dl/?mode=json" 2>/dev/null \
         | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"go\([0-9][0-9.]*\)".*/\1/p' | head -n 1)" || true
  fi
  [ -n "$v" ] || v="$GO_FALLBACK_VERSION"
  # 官方稳定版可能低于本模块要求（不会发生，但兜一下）
  ver_ge "$v" "$GO_MIN_VERSION" || v="$GO_FALLBACK_VERSION"
  printf '%s' "$v"
}

install_go() {
  local ver tarball url tmp
  ver="$GO_VERSION"
  [ -n "$ver" ] || ver="$(resolve_go_version)"
  tarball="go${ver}.linux-${GO_ARCH}.tar.gz"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  log "下载 Go ${ver}（${GO_ARCH}）..."
  url="${GO_DL_BASE}/${tarball}"
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/${tarball}" "$url" 2>/dev/null; then
    url="https://go.dev/dl/${tarball}"
    log "改用备用源：$url"
    curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/${tarball}" "$url" \
      || die "Go 下载失败。可加 --help 看 GO_DL_BASE / GO_VERSION 用法"
  fi

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmp}/${tarball}"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  GO_BIN=/usr/local/go/bin/go
  ok "Go 已安装：$("$GO_BIN" version)"
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local cur
    cur="$(go_ver_num "$(go version)")"
    if [ -n "$cur" ] && ver_ge "$cur" "$GO_MIN_VERSION"; then
      GO_BIN="$(command -v go)"
      log "使用系统 Go：$(go version)"
      return 0
    fi
    warn "系统 Go 版本过低（${cur:-未知} < ${GO_MIN_VERSION}），将安装官方新版"
  else
    log "未检测到 Go，将安装官方版"
  fi
  install_go
}

# ── 取源码 ─────────────────────────────────────────────────────────────────
prepare_source() {
  # 1) --source 显式指定
  if [ -n "$SRC_OPT" ]; then
    [ -f "$SRC_OPT/go.mod" ] || die "--source 指向的目录里没有 go.mod：$SRC_OPT"
    SRC_DIR="$(cd "$SRC_OPT" && pwd)"
    log "使用指定源码目录：$SRC_DIR"
    return 0
  fi

  # 2) 脚本自身就在仓库里（git clone 后直跑）
  local self_dir=""
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || self_dir=""
  if [ -n "$self_dir" ] && [ -f "${self_dir}/go.mod" ] && [ -d "${self_dir}/internal" ]; then
    SRC_DIR="$self_dir"
    # 直跑仓库里的脚本时也支持原地升级；关键数据与本地改动不碰。
    if [ -d "${SRC_DIR}/.git" ]; then
      local dirty=""
      dirty="$(git -C "$SRC_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)"
      if [ -n "$dirty" ]; then
        warn "源码目录有未提交修改，按当前内容编译（不自动更新）"
      elif git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH" >/dev/null 2>&1; then
        # 已确认工作树干净，可直接切到刚取回的远端提交；浅历史下比 merge 更稳。
        git -C "$SRC_DIR" checkout -q --force FETCH_HEAD
        git -C "$SRC_DIR" clean -qfd -e config.json -e auths -e data
        log "源码已更新到 origin/${BRANCH}"
      else
        warn "拉取最新源码失败，按当前内容编译"
      fi
    fi
    log "使用当前源码目录：$SRC_DIR"
    return 0
  fi

  # 3) 其它情况（curl | bash）：clone 到安装目录的 src/
  SRC_DIR="${INSTALL_DIR}/src"
  mkdir -p "$(dirname "$SRC_DIR")"
  if [ -d "${SRC_DIR}/.git" ]; then
    log "更新源码：${SRC_DIR}（分支 ${BRANCH}）"
    git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH" >/dev/null 2>&1 \
      || die "git fetch 失败（检查网络 / 仓库地址 ${REPO_URL}）"
    git -C "$SRC_DIR" checkout -q --force FETCH_HEAD
    git -C "$SRC_DIR" clean -qfd -e config.json -e auths -e data
  else
    log "克隆源码 → ${SRC_DIR}（分支 ${BRANCH}）"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 \
      || die "git clone 失败（检查网络 / 仓库地址 ${REPO_URL} / 分支 ${BRANCH}）"
  fi
}

# ── 编译 ───────────────────────────────────────────────────────────────────
build_binary() {
  local ldflags="-s -w"
  if [ -n "$BUILD_VERSION" ]; then
    ldflags="${ldflags} -X main.appVersion=${BUILD_VERSION}"
  fi
  log "编译二进制（首次需拉取依赖，视网络约 1-3 分钟）..."
  (
    cd "$SRC_DIR"
    env -u GOFLAGS GOTOOLCHAIN=local CGO_ENABLED=0 GOPROXY="${GOPROXY_URL}" \
      "$GO_BIN" build -trimpath -ldflags "$ldflags" -o "${INSTALL_DIR}/.wb2api.new" ./cmd/server
  ) || die "编译失败（网络不通可改镜像：GOPROXY_URL=https://goproxy.io,direct）"
  # rename 而非就地覆盖：正在运行的二进制被覆盖会 ETXTBSY，rename 不受影响
  mv -f "${INSTALL_DIR}/.wb2api.new" "${INSTALL_DIR}/wb2api"
  chmod 0755 "${INSTALL_DIR}/wb2api"
  ok "二进制就绪：${INSTALL_DIR}/wb2api（$(du -h "${INSTALL_DIR}/wb2api" | cut -f1)）"
}

build_cli_tools() {
  [ "$WITH_CLI" = "1" ] || return 0
  log "编译命令行工具（login / signin_bin / credit）..."
  local name
  for pair in "login:./cmd/login" "signin_bin:./cmd/signin" "credit:./cmd/credit"; do
    name="${pair%%:*}"
    ( cd "$SRC_DIR" && env -u GOFLAGS GOTOOLCHAIN=local CGO_ENABLED=0 GOPROXY="${GOPROXY_URL}" \
        "$GO_BIN" build -trimpath -ldflags "-s -w" -o "${INSTALL_DIR}/${name}" "${pair#*:}" ) \
      || die "编译 ${name} 失败"
    chmod 0755 "${INSTALL_DIR}/${name}"
  done
  local s
  for s in login.sh signin.sh credit.sh; do
    [ -f "${SRC_DIR}/${s}" ] && install -m 0755 "${SRC_DIR}/${s}" "${INSTALL_DIR}/${s}"
  done
  ok "命令行工具与脚本已就位"
}

# ── 目录与配置 ─────────────────────────────────────────────────────────────
random_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif [ -r /dev/urandom ]; then
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
  else
    printf '%s%s' "$(date +%s%N)" "$$" | sha256sum | cut -c1-32
  fi
}

ensure_dirs() {
  mkdir -p "${INSTALL_DIR}/auths" "${INSTALL_DIR}/data"
  if [ "$SERVICE_USER" != "root" ]; then
    create_service_user
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR" 2>/dev/null || true
  fi
}

user_exists()  { id -u "$1" >/dev/null 2>&1; }
group_exists() { getent group "$1" >/dev/null 2>&1 || grep -q "^$1:" /etc/group 2>/dev/null; }

# service_group 取运行用户的主组；用户不存在或查询失败时回落同名组。
service_group() {
  local g=""
  if user_exists "$SERVICE_USER"; then
    g="$(id -gn "$SERVICE_USER" 2>/dev/null || true)"
  fi
  printf '%s' "${g:-$SERVICE_USER}"
}

# create_service_user 建一个无登录权限的系统用户 + 同名用户组（存在则跳过）。
# 不同发行版的 useradd/adduser 方言差异很大，逐个降级尝试。
create_service_user() {
  user_exists "$SERVICE_USER" && return 0
  log "创建系统用户：${SERVICE_USER}"
  if ! group_exists "$SERVICE_USER"; then
    groupadd --system "$SERVICE_USER" 2>/dev/null || addgroup -S "$SERVICE_USER" 2>/dev/null || true
  fi
  if group_exists "$SERVICE_USER"; then
    useradd --system --gid "$SERVICE_USER" --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER" 2>/dev/null \
      || useradd --system --gid "$SERVICE_USER" --home-dir "$INSTALL_DIR" --shell /sbin/nologin "$SERVICE_USER" 2>/dev/null \
      || adduser -S -D -H -G "$SERVICE_USER" -h "$INSTALL_DIR" "$SERVICE_USER" 2>/dev/null \
      || true
  else
    useradd --system --home-dir "$INSTALL_DIR" --shell /sbin/nologin "$SERVICE_USER" 2>/dev/null || true
  fi
  user_exists "$SERVICE_USER" || die "创建用户 ${SERVICE_USER} 失败（可改用 --user root）"
}

write_config() {
  local cfg="${INSTALL_DIR}/config.json"
  if [ -f "$cfg" ]; then
    log "沿用已有配置：$cfg（未改动）"
    # 复用已有配置里的密钥与端口（汇总里直接给用户看，省得翻文件）
    [ -n "$API_KEY" ] || API_KEY="$(sed -n 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -n 1)"
    # 复用已有配置里的端口做健康检查
    local got
    got="$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"[^"]*:\([0-9]\+\)".*/\1/p' "$cfg" | head -n 1)"
    [ -n "$got" ] && PORT="$got"
    return 0
  fi
  [ -n "$API_KEY" ] || API_KEY="$(random_key)"
  cat > "$cfg" <<EOF
{
  "listen": "${LISTEN_ADDR}",
  "api_key": "${API_KEY}",
  "auth_dir": "./auths",
  "state_file": "./data/state.json",
  "schedule": {
    "checkin_hours": [9, 21],
    "growth_hours": [1],
    "travel_hours": [9, 21],
    "activity_hours": [10],
    "keepalive_hours": [22],
    "blackcat_hours": [23],
    "checkin_enabled": true,
    "growth_enabled": true,
    "travel_enabled": true,
    "activity_enabled": true,
    "keepalive_enabled": true,
    "blackcat_enabled": true,
    "balance_refresh_enabled": true,
    "balance_refresh_minutes": 5
  }
}
EOF
  chmod 0600 "$cfg"
  [ "$SERVICE_USER" != "root" ] && chown "${SERVICE_USER}:${SERVICE_USER}" "$cfg" 2>/dev/null || true
  ok "已生成配置：$cfg"
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else
    return 1
  fi
}

# ── systemd ────────────────────────────────────────────────────────────────
have_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# render_service_unit 把 unit 文件打到 stdout（单独成函数：注册前可先看、也方便测试）。
render_service_unit() {
  cat <<EOF
[Unit]
Description=${SERVICE_DESC}
Documentation=${REPO_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=$(service_group)
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/wb2api -config ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3
Environment="TZ=${TZ_NAME}"
# 只允许写安装目录（auths/ data/ config.json 都在里面）
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

install_service() {
  if [ "$NO_SERVICE" = "1" ]; then
    log "已跳过 systemd 服务注册（--no-service）"
    return 0
  fi
  if ! have_systemd; then
    warn "当前系统没有 systemd（容器/精简系统？），改为直接后台启动"
    pkill -f "${INSTALL_DIR}/wb2api" 2>/dev/null || true
    sleep 1
    local logfile="${INSTALL_DIR}/data/wb2api.log"
    if [ "$SERVICE_USER" = "root" ]; then
      nohup "${INSTALL_DIR}/wb2api" -config "${INSTALL_DIR}/config.json" >> "$logfile" 2>&1 &
    elif command -v runuser >/dev/null 2>&1; then
      nohup runuser -u "$SERVICE_USER" -- "${INSTALL_DIR}/wb2api" -config "${INSTALL_DIR}/config.json" >> "$logfile" 2>&1 &
    elif command -v su >/dev/null 2>&1; then
      nohup su -s /bin/sh "$SERVICE_USER" -c "exec \"${INSTALL_DIR}/wb2api\" -config \"${INSTALL_DIR}/config.json\"" >> "$logfile" 2>&1 &
    else
      warn "未找到 runuser/su，改为以 root 后台运行"
      nohup "${INSTALL_DIR}/wb2api" -config "${INSTALL_DIR}/config.json" >> "$logfile" 2>&1 &
    fi
    ok "已后台启动（PID $!，日志 ${logfile}）"
    return 0
  fi

  log "注册 systemd 服务：${SERVICE_NAME}"
  render_service_unit > "/etc/systemd/system/${SERVICE_NAME}.service"

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"
  ok "服务已启动：systemctl status ${SERVICE_NAME}"
}

# ── 健康检查 ───────────────────────────────────────────────────────────────
detect_ip() {
  local ip=""
  ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -n 1)" || true
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  [ -n "$ip" ] || ip="<服务器IP>"
  printf '%s' "$ip"
}

health_check() {
  local url="http://127.0.0.1:${PORT}/healthz" code="" i
  if ! command -v curl >/dev/null 2>&1; then return 0; fi
  for i in $(seq 1 15); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
    case "$code" in
      200) ok "健康检查通过（HTTP 200）"; return 0 ;;
      503) ok "健康检查通过（HTTP 503：暂无可用账号，属正常）"; return 0 ;;
    esac
    sleep 1
  done
  warn "健康检查未通过（最后响应：${code:-无}）。排查："
  warn "  systemctl status ${SERVICE_NAME} -l --no-pager"
  warn "  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
  return 0
}

# ── 卸载 ───────────────────────────────────────────────────────────────────
do_uninstall() {
  log "卸载 ${SERVICE_NAME} ..."
  if have_systemd; then
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    ok "systemd 服务已移除"
  else
    pkill -f "${INSTALL_DIR}/wb2api" 2>/dev/null || true
  fi

  if [ "$PURGE" = "1" ]; then
    case "$INSTALL_DIR" in
      ""|"/"|"/usr"|"/opt"|"/root"|"/home") die "拒绝删除危险路径：$INSTALL_DIR" ;;
    esac
    rm -rf "$INSTALL_DIR"
    ok "已删除安装目录：$INSTALL_DIR"
    if [ "$SERVICE_USER" != "root" ] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
      userdel "$SERVICE_USER" 2>/dev/null || true
    fi
  else
    ok "已保留数据目录：${INSTALL_DIR}（含 auths/ data/ config.json）"
    log "如需彻底删除：bash $0 --uninstall --purge"
  fi
}

# ── 主流程 ─────────────────────────────────────────────────────────────────
print_summary() {
  local ip; ip="$(detect_ip)"
  local bind_note=""
  case "$LISTEN_ADDR" in
    127.0.0.1:*|localhost:*) bind_note="（仅本机监听，请用反向代理暴露）" ;;
  esac
  echo
  printf '%s============================================================%s\n' "$c_bold" "$c_reset"
  printf '%s 安装完成%s\n' "$c_bold" "$c_reset"
  printf '%s============================================================%s\n' "$c_bold" "$c_reset"
  echo "  面板地址 : http://${ip}:${PORT}/panel/ ${bind_note}"
  echo "  本机地址 : http://127.0.0.1:${PORT}/panel/"
  echo "  接口地址 : http://${ip}:${PORT}/v1  （OpenAI 兼容）"
  echo "  密钥     : ${API_KEY:-（沿用已有 config.json 中的 api_key）}"
  echo "  安装目录 : ${INSTALL_DIR}"
  echo "  配置     : ${INSTALL_DIR}/config.json"
  echo "  账号目录 : ${INSTALL_DIR}/auths"
  echo
  echo "  下一步   : 浏览器打开面板 → 右上角「添加账号」扫码/登录，凭证自动落盘并热加载"
  echo
  if have_systemd && [ "$NO_SERVICE" != "1" ]; then
    echo "  查看状态 : systemctl status ${SERVICE_NAME} --no-pager"
    echo "  实时日志 : journalctl -u ${SERVICE_NAME} -f"
    echo "  重启服务 : systemctl restart ${SERVICE_NAME}"
  fi
  echo "  重新升级 : sudo bash install.sh            （重编译并重启，数据不动）"
  echo "  卸载     : sudo bash install.sh --uninstall"
  echo
  printf '%s  安全提醒：服务本身只提供明文 HTTP，公网使用请设置强 api_key%s\n' "$c_yel" "$c_reset"
  printf '%s            并置于 HTTPS 反向代理（Nginx / Caddy）之后。%s\n' "$c_yel" "$c_reset"
  echo
}

main() {
  parse_args "$@"
  need_root
  detect_os

  if [ "$UNINSTALL" = "1" ]; then
    do_uninstall
    return 0
  fi

  ensure_bash
  ensure_tools

  if port_in_use "$PORT" && [ ! -f "${INSTALL_DIR}/config.json" ] && [ "$FORCE" != "1" ]; then
    die "端口 ${PORT} 已被占用。换端口：--port 8080（或 --force 强行继续）"
  fi

  ensure_go
  prepare_source
  mkdir -p "$INSTALL_DIR"
  build_binary
  build_cli_tools
  ensure_dirs
  write_config
  install_service
  health_check
  print_summary
}

# 允许被 source 进来做单元测试（不触发主流程）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
