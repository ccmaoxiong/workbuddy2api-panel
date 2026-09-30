#!/usr/bin/env bash
# =============================================================================
# install.sh - workbuddy2api 云端一键安装（下载预编译二进制 + systemd 托管）
#
# 做什么：
#   1. 识别 Linux CPU 架构
#   2. 从 GitHub Releases 下载对应架构的预编译压缩包
#   3. 校验 SHA-256 后解压并安装
#   4. 建 auths/ data/ 目录 + 生成 config.json（随机 api_key）
#   5. 注册并启动 systemd 服务 + 健康检查
#
# 服务器不需要安装 Go，也不需要拉源码编译。
#
# 一行安装：
#   curl -fsSL https://github.com/ccmaoxiong/workbuddy2api-panel/releases/latest/download/install.sh | sudo bash
#
# 重复执行即「原地升级」：重新下载最新版二进制并重启，已有数据全部保留。
# =============================================================================
set -euo pipefail

# ── 默认参数（都可用环境变量或命令行覆盖）──────────────────────────────────
APP_NAME="wb2api"
SERVICE_NAME="wb2api"
SERVICE_DESC="workbuddy2api - CodeBuddy 账号池网关 + Web 管理面板"
DEFAULT_RELEASE_REPO="ccmaoxiong/workbuddy2api-panel"
DEFAULT_TZ="Asia/Shanghai"

RELEASE_REPO="${WB2API_REPO:-$DEFAULT_RELEASE_REPO}"
RELEASE_VERSION="${WB2API_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/opt/wb2api}"
SERVICE_USER="${SERVICE_USER:-wb2api}"
PORT="${PORT:-7863}"
HOST="${HOST:-0.0.0.0}"
API_KEY="${API_KEY:-}"
TZ_NAME="${TZ_NAME:-$DEFAULT_TZ}"

NO_CLI=0
NO_SERVICE=0
UNINSTALL=0
PURGE=0
FORCE=0

# ── 输出 helpers ───────────────────────────────────────────────────────────
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_yel=$'\033[33m'; c_blu=$'\033[36m'; c_bold=$'\033[1m'
if [ ! -t 1 ]; then c_reset=""; c_red=""; c_grn=""; c_yel=""; c_blu=""; c_bold=""; fi

log()  { printf '%s[%s]%s %s\n' "$c_blu" "$APP_NAME" "$c_reset" "$*"; }
ok()   { printf '%s[%s]%s %s\n' "$c_grn" "$APP_NAME" "$c_reset" "$*"; }
warn() { printf '%s[%s] 警告%s %s\n' "$c_yel" "$APP_NAME" "$c_reset" "$*" >&2; }
die()  { printf '%s[%s] 错误%s %s\n' "$c_red" "$APP_NAME" "$c_reset" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${c_bold}workbuddy2api 云端一键安装脚本${c_reset}

用法: sudo bash install.sh [选项]

安装/升级选项:
  --dir PATH            安装目录               (默认 ${INSTALL_DIR})
  --port PORT           监听端口               (默认 ${PORT})
  --host HOST           监听地址               (默认 ${HOST}；填 127.0.0.1 只对本机开放)
  --listen ADDR:PORT    直接指定完整监听地址   (覆盖 --host/--port)
  --api-key KEY         面板/网关密钥          (默认自动生成随机 32 位)
  --repo OWNER/REPO     发行版仓库             (默认 ${DEFAULT_RELEASE_REPO})
  --version TAG         安装指定版本           (默认 latest；例如 v1.11.11)
  --user NAME           运行服务的系统用户     (默认 ${SERVICE_USER}；填 root 则以 root 运行)
  --tz ZONE             时区                   (默认 ${DEFAULT_TZ})
  --no-cli              不安装 login / signin_bin / credit 工具
  --no-service          只安装，不注册 systemd 服务
  --force               端口被占用时也继续（默认遇到占用直接退出）

卸载选项:
  --uninstall           停止并移除 systemd 服务与二进制（保留数据）
  --purge               配合 --uninstall：连同 ${INSTALL_DIR} 一起删除

  -h, --help            显示本帮助

可用环境变量覆盖:
  WB2API_REPO WB2API_VERSION WB2API_DOWNLOAD_BASE INSTALL_DIR SERVICE_USER PORT HOST API_KEY TZ_NAME
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
      --repo)        RELEASE_REPO="${2:?--repo 需要 OWNER/REPO}"; shift 2 ;;
      --version)     RELEASE_VERSION="${2:?--version 需要版本}"; shift 2 ;;
      --user)        SERVICE_USER="${2:?--user 需要用户名}"; shift 2 ;;
      --tz)          TZ_NAME="${2:?--tz 需要时区}"; shift 2 ;;
      --no-cli)      NO_CLI=1; shift ;;
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
  # PORT 只是给 URL/健康检查用的展示值；以 LISTEN_ADDR 里的端口为准。
  case "$LISTEN_ADDR" in
    *:*) PORT="${LISTEN_ADDR##*:}" ;;
    *)   LISTEN_ADDR=":${LISTEN_ADDR}"; PORT="${LISTEN_ADDR##*:}" ;;
  esac
  [ -n "$PORT" ] || die "无法从监听地址推断端口：$LISTEN_ADDR"

  # 安装目录统一转绝对路径，避免后续 cd 后相对路径跑偏。
  case "$INSTALL_DIR" in
    /*) ;;
    *)  INSTALL_DIR="${PWD}/${INSTALL_DIR}" ;;
  esac
  case "$INSTALL_DIR" in
    *[[:space:]]*) die "安装目录不能包含空格：$INSTALL_DIR" ;;
  esac

  case "$RELEASE_REPO" in
    */*) ;;
    *) die "--repo 需要 OWNER/REPO 格式：$RELEASE_REPO" ;;
  esac
}

# ── 基础检查 ───────────────────────────────────────────────────────────────
need_root() {
  if [ "$(id -u)" != "0" ]; then
    die "需要 root 权限：请用 sudo bash $0 ${*:-}"
  fi
}

detect_os() {
  [ "$(uname -s)" = "Linux" ] || die "本脚本只支持 Linux 服务器（当前：$(uname -s)）"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)   ASSET_ARCH="amd64" ;;
    aarch64|arm64)  ASSET_ARCH="arm64" ;;
    armv7l)         ASSET_ARCH="armv7" ;;
    armv6l)         ASSET_ARCH="armv6" ;;
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
  log "系统：$(uname -s) $(uname -m) · 架构资产：linux-${ASSET_ARCH} · 包管理器：${PKG}"
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

ensure_tools() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar  >/dev/null 2>&1 || missing+=(tar)
  if [ ${#missing[@]} -gt 0 ]; then
    log "安装基础工具：${missing[*]}"
    pkg_install "${missing[@]}" ca-certificates
  fi
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  command -v tar  >/dev/null 2>&1 || die "缺少 tar"
}

# ── 下载与安装 Release 二进制 ──────────────────────────────────────────────
sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    die "缺少 SHA-256 校验工具（sha256sum / shasum / openssl）"
  fi
}

release_download_base() {
  if [ -n "${WB2API_DOWNLOAD_BASE:-}" ]; then
    printf '%s' "${WB2API_DOWNLOAD_BASE%/}"
    return 0
  fi
  local version="$1"
  if [ "$version" = "latest" ]; then
    printf 'https://github.com/%s/releases/latest/download' "$RELEASE_REPO"
    return 0
  fi
  case "$version" in
    v*) ;;
    *) version="v${version}" ;;
  esac
  printf 'https://github.com/%s/releases/download/%s' "$RELEASE_REPO" "$version"
}

download_release() {
  local base asset url sha_url tmp archive sha_file expected actual
  base="$(release_download_base "$RELEASE_VERSION")"
  asset="wb2api_linux_${ASSET_ARCH}.tar.gz"
  url="${base}/${asset}"
  sha_url="${url}.sha256"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmp"' RETURN
  archive="${tmp}/${asset}"
  sha_file="${tmp}/${asset}.sha256"

  log "下载预编译二进制：${url}"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$archive" "$url" \
    || die "下载失败。检查 Release 是否已生成，或指定版本：--version v1.11.11"
  [ -s "$archive" ] || die "下载文件为空：$archive"

  log "下载并校验 SHA-256..."
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$sha_file" "$sha_url" \
    || die "校验文件下载失败：$sha_url"
  expected="$(awk 'NR==1 {print $1}' "$sha_file")"
  actual="$(sha256_file "$archive")"
  [ -n "$expected" ] || die "校验文件内容为空：$sha_url"
  [ "$expected" = "$actual" ] || die "SHA-256 校验失败（期望 ${expected}，实际 ${actual}）"

  tar -tzf "$archive" >/dev/null 2>&1 || die "压缩包损坏：$asset"
  mkdir -p "${tmp}/extract"
  tar -xzf "$archive" -C "${tmp}/extract"
  [ -f "${tmp}/extract/wb2api" ] || die "压缩包内缺少 wb2api 二进制"

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "${tmp}/extract/wb2api" "${INSTALL_DIR}/.wb2api.new"
  mv -f "${INSTALL_DIR}/.wb2api.new" "${INSTALL_DIR}/wb2api"
  ok "主程序已安装：${INSTALL_DIR}/wb2api（$(du -h "${INSTALL_DIR}/wb2api" | cut -f1)）"

  if [ "$NO_CLI" != "1" ]; then
    local name
    for name in login signin_bin credit; do
      if [ -f "${tmp}/extract/${name}" ]; then
        install -m 0755 "${tmp}/extract/${name}" "${INSTALL_DIR}/${name}"
      fi
    done
    local script
    for script in login.sh signin.sh credit.sh; do
      if [ -f "${tmp}/extract/${script}" ]; then
        install -m 0755 "${tmp}/extract/${script}" "${INSTALL_DIR}/${script}"
      fi
    done
    ok "命令行工具已安装"
  else
    log "已跳过命令行工具（--no-cli）"
  fi

  if [ -f "${tmp}/extract/VERSION" ]; then
    INSTALLED_VERSION="$(head -n 1 "${tmp}/extract/VERSION")"
  else
    INSTALLED_VERSION="$RELEASE_VERSION"
  fi
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

ensure_dirs() {
  mkdir -p "${INSTALL_DIR}/auths" "${INSTALL_DIR}/data"
  if [ "$SERVICE_USER" != "root" ]; then
    create_service_user
    chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR" 2>/dev/null || true
  fi
}

write_config() {
  local cfg="${INSTALL_DIR}/config.json"
  if [ -f "$cfg" ]; then
    log "沿用已有配置：$cfg（未改动）"
    [ -n "$API_KEY" ] || API_KEY="$(sed -n 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -n 1)"
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
Documentation=https://github.com/${RELEASE_REPO}
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
  if [ "$NO_SERVICE" = "1" ]; then return 0; fi
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
    log "如需彻底删除：curl -fsSL https://github.com/${RELEASE_REPO}/releases/latest/download/install.sh | sudo bash -s -- --uninstall --purge"
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
  echo "  版本     : ${INSTALLED_VERSION:-$RELEASE_VERSION}"
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
  echo "  重新升级 : curl -fsSL https://github.com/${RELEASE_REPO}/releases/latest/download/install.sh | sudo bash"
  echo "  卸载     : curl -fsSL https://github.com/${RELEASE_REPO}/releases/latest/download/install.sh | sudo bash -s -- --uninstall"
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

  ensure_tools

  if port_in_use "$PORT" && [ ! -f "${INSTALL_DIR}/config.json" ] && [ "$FORCE" != "1" ]; then
    die "端口 ${PORT} 已被占用。换端口：--port 8080（或 --force 强行继续）"
  fi

  ensure_dirs
  download_release
  write_config
  install_service
  health_check
  print_summary
}

# 允许被 source 进来做单元测试；直接执行和 curl | bash 都会进入 main。
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
