#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
TARGET_USER=""
USER_PASSWORD=""
BASE_DOMAIN=""

# Main proxy path:
#   VLESS Encryption + RAW + XTLS Vision
#   direct public IP, no TLS / REALITY / WS / XHTTP / Caddy in proxy data path
XRAY_PORT="${XRAY_PORT:-8443}"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"

ENABLE_METATUBE=""
METATUBE_TOKEN=""
ENABLE_PLAYWRIGHT=""
PLAYWRIGHT_PORT=""
ENABLE_WATCHTOWER=""
TCP_CC="${TCP_CC:-bbr}" # bbr | cubic | reno

PUBLIC_IP=""
URI_HOST=""
VLESS_UUID=""
VLESS_DECRYPTION=""
VLESS_ENCRYPTION=""
XRAY_SHARE_LINK=""
XRAY_VERSION=""

OUTPUT_DIR="/root/bootstrap-output"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${OUTPUT_DIR}/result-${TIMESTAMP}.txt"
LATEST_FILE="${OUTPUT_DIR}/latest.txt"

NON_INTERACTIVE="false"
USE_WHIPTAIL="false"

usage() {
  cat <<USAGE
Usage:
  sudo bash ${SCRIPT_NAME} [options]

Options:
  -h, --help                         Show help
  --username <name>                  Target Linux user
  --xray-port <port>                 Xray direct RAW port, default: 8443
  --base-domain <domain>             Base domain, e.g. jp.server.example.com
  --enable-metatube <true|false>
  --metatube-token <token>
  --enable-playwright <true|false>
  --playwright-port <port>
  --enable-watchtower <true|false>
  --tcp-cc <bbr|cubic|reno>          TCP congestion control, default: bbr

Proxy:
  VLESS Encryption + RAW + XTLS Vision
  Direct IP on TCP ${XRAY_PORT}; Caddy is NOT in the proxy path.

Notes:
  - No arguments => interactive wizard.
  - Caddy is installed only when MetaTube or Playwright needs HTTPS reverse proxy.
  - Caddy keeps TCP 443; Xray uses TCP ${XRAY_PORT} by default.
  - Watchtower requires Docker and will trigger Docker installation when enabled.
USAGE
}

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "必须使用 root/sudo 运行，例如：sudo -i 后再执行脚本"
    exit 1
  fi
}

check_os() {
  [[ -f /etc/os-release ]] || { err "缺少 /etc/os-release"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) err "仅支持 Debian/Ubuntu，当前: ${ID:-unknown}"; exit 1 ;;
  esac
}

validate_bool() {
  local v="$1" k="$2"
  [[ "$v" == "true" || "$v" == "false" ]] || {
    err "$k 必须是 true 或 false"
    exit 1
  }
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    NON_INTERACTIVE="false"
    return 0
  fi
  NON_INTERACTIVE="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --username)
        TARGET_USER="${2:-}"
        shift 2
        ;;
      --xray-port)
        XRAY_PORT="${2:-}"
        shift 2
        ;;
      --base-domain)
        BASE_DOMAIN="${2:-}"
        shift 2
        ;;
      --enable-metatube)
        ENABLE_METATUBE="${2:-}"
        shift 2
        ;;
      --metatube-token)
        METATUBE_TOKEN="${2:-}"
        shift 2
        ;;
      --enable-playwright)
        ENABLE_PLAYWRIGHT="${2:-}"
        shift 2
        ;;
      --playwright-port)
        PLAYWRIGHT_PORT="${2:-}"
        shift 2
        ;;
      --enable-watchtower)
        ENABLE_WATCHTOWER="${2:-}"
        shift 2
        ;;
      --tcp-cc)
        TCP_CC="${2:-}"
        shift 2
        ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done
}

ask_yes_no() {
  local prompt="$1" default="$2" ans=""
  while true; do
    read -r -p "${prompt} [${default}] " ans
    ans="${ans:-$default}"
    case "${ans,,}" in
      y|yes|true) echo "true"; return 0 ;;
      n|no|false) echo "false"; return 0 ;;
      *) echo "请输入 y/n" ;;
    esac
  done
}

init_ui_mode() {
  if [[ "$NON_INTERACTIVE" == "false" ]] \
    && command -v whiptail >/dev/null 2>&1 \
    && [[ -t 0 ]] && [[ -t 1 ]]; then
    USE_WHIPTAIL="true"
  fi
}

menu_yes_no() {
  local title="$1" text="$2" default_yes="$3"

  if [[ "$USE_WHIPTAIL" == "true" ]]; then
    if [[ "$default_yes" == "y" ]]; then
      if whiptail --title "$title" --yesno "$text" 10 70 3>&1 1>&2 2>&3; then
        echo "true"
      else
        echo "false"
      fi
    else
      if whiptail --title "$title" --yesno "$text" 10 70 --defaultno 3>&1 1>&2 2>&3; then
        echo "true"
      else
        echo "false"
      fi
    fi
    return 0
  fi

  ask_yes_no "$text" "$default_yes"
}

ask_non_empty() {
  local prompt="$1" v=""
  while true; do
    read -r -p "$prompt" v
    [[ -n "$v" ]] && { echo "$v"; return 0; }
    echo "输入不能为空"
  done
}

ask_port() {
  local prompt="$1" p=""
  while true; do
    read -r -p "$prompt" p
    is_valid_port "$p" && { echo "$p"; return 0; }
    echo "端口必须是 1-65535"
  done
}

prompt_confirmed_password() {
  local p1="" p2=""
  while true; do
    read -r -s -p "请输入新用户密码: " p1
    echo
    read -r -s -p "请再次输入确认: " p2
    echo
    if [[ -n "$p1" && "$p1" == "$p2" ]]; then
      USER_PASSWORD="$p1"
      return 0
    fi
    err "两次输入不一致或为空，请重试"
  done
}

resolve_target_user() {
  if [[ -n "$TARGET_USER" ]]; then
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
    log "检测到 sudo 用户: ${TARGET_USER}"
    return
  fi

  TARGET_USER="$(ask_non_empty '请输入目标用户名: ')"
}

uses_caddy() {
  [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]
}

needs_docker() {
  uses_caddy || [[ "$ENABLE_WATCHTOWER" == "true" ]]
}

interactive_wizard_if_needed() {
  if [[ "$NON_INTERACTIVE" != "false" ]]; then
    return
  fi

  echo
  echo "===== 交互向导 ====="
  echo "Xray 主代理固定为：VLESS Encryption + RAW + Vision"
  echo "Xray 默认端口：${XRAY_PORT}/tcp"
  echo

  if [[ -z "$ENABLE_METATUBE" ]]; then
    ENABLE_METATUBE="$(menu_yes_no 'MetaTube' '是否安装 MetaTube + Postgres?' 'n')"
  fi

  if [[ -z "$ENABLE_PLAYWRIGHT" ]]; then
    ENABLE_PLAYWRIGHT="$(menu_yes_no 'Playwright' '是否配置 Playwright 反向代理入口?' 'n')"
  fi

  if uses_caddy && [[ -z "$BASE_DOMAIN" ]]; then
    BASE_DOMAIN="$(ask_non_empty '请输入基础域名（如 jp.server.master.zeayii.org）: ')"
  fi

  if [[ "$ENABLE_METATUBE" == "true" && -z "$METATUBE_TOKEN" ]]; then
    read -r -s -p "请输入 MetaTube TOKEN: " METATUBE_TOKEN
    echo
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" && -z "$PLAYWRIGHT_PORT" ]]; then
    PLAYWRIGHT_PORT="$(ask_port '请输入 Playwright 内部端口: ')"
  fi

  if [[ -z "$ENABLE_WATCHTOWER" ]]; then
    ENABLE_WATCHTOWER="$(menu_yes_no 'Watchtower' '是否安装 Watchtower?' 'y')"
  fi
}

validate_inputs() {
  [[ -n "$TARGET_USER" ]] || { err "目标用户名为空"; exit 1; }

  is_valid_port "$XRAY_PORT" || {
    err "--xray-port 非法: ${XRAY_PORT}"
    exit 1
  }

  if [[ -z "$ENABLE_METATUBE" ]]; then ENABLE_METATUBE="false"; fi
  if [[ -z "$ENABLE_PLAYWRIGHT" ]]; then ENABLE_PLAYWRIGHT="false"; fi
  if [[ -z "$ENABLE_WATCHTOWER" ]]; then ENABLE_WATCHTOWER="true"; fi

  validate_bool "$ENABLE_METATUBE" "--enable-metatube"
  validate_bool "$ENABLE_PLAYWRIGHT" "--enable-playwright"
  validate_bool "$ENABLE_WATCHTOWER" "--enable-watchtower"

  case "$TCP_CC" in
    bbr|cubic|reno) ;;
    *) err "--tcp-cc 仅支持 bbr/cubic/reno"; exit 1 ;;
  esac

  if uses_caddy; then
    [[ -n "$BASE_DOMAIN" ]] || {
      err "启用 MetaTube/Playwright 时必须提供 --base-domain"
      exit 1
    }
  fi

  if [[ "$ENABLE_METATUBE" == "true" ]]; then
    [[ -n "$METATUBE_TOKEN" ]] || {
      err "启用 MetaTube 时必须提供 --metatube-token 或交互输入"
      exit 1
    }
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    is_valid_port "$PLAYWRIGHT_PORT" || {
      err "Playwright 端口非法"
      exit 1
    }
  fi
}

install_base_packages() {
  log "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    log "等待 apt/dpkg 锁释放..."
    sleep 5
  done

  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release \
    tar unzip xz-utils jq qrencode openssl passwd ufw \
    iproute2 procps whiptail
}

set_timezone() {
  log "设置时区 ${TIMEZONE}"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$TIMEZONE" || true
  else
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata || true
  fi
}

ensure_user() {
  if id "$TARGET_USER" >/dev/null 2>&1; then
    log "用户 ${TARGET_USER} 已存在"
  else
    log "创建用户 ${TARGET_USER}"
    useradd -m -s /bin/bash "$TARGET_USER"
    [[ -n "$USER_PASSWORD" ]] || prompt_confirmed_password
    echo "${TARGET_USER}:${USER_PASSWORD}" | chpasswd
  fi
  usermod -aG sudo "$TARGET_USER" || true
}

ensure_xdg_dirs() {
  local home_dir
  home_dir="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || { err "无法解析用户 Home"; exit 1; }

  log "初始化 ${TARGET_USER} 的 XDG 目录"
  install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "${home_dir}/.ssh"
  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "${home_dir}/.config" \
    "${home_dir}/.local/share" \
    "${home_dir}/.local/state" \
    "${home_dir}/.cache" \
    "${home_dir}/.local/bin"
}

detect_public_ip() {
  local ip=""

  ip="$(curl -4fsSL --max-time 8 https://api.ipify.org || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsSL --max-time 8 https://ifconfig.me || true)"
  [[ -n "$ip" ]] || ip="$(curl -6fsSL --max-time 8 https://api64.ipify.org || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  echo "$ip"
}

configure_tcp_cc() {
  log "配置 TCP 拥塞控制: ${TCP_CC}"

  if [[ "$TCP_CC" == "bbr" ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr >/etc/modules-load.d/bbr.conf
  fi

  cat >/etc/sysctl.d/99-bootstrap-net.conf <<EOFCC
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${TCP_CC}
EOFCC

  sysctl --system >/dev/null || true

  log "TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  log "qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
}

install_xray() {
  log "安装 / 更新官方 Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  [[ -x "$XRAY_BIN" ]] || {
    err "Xray 安装失败：未找到 ${XRAY_BIN}"
    exit 1
  }

  XRAY_VERSION="$("$XRAY_BIN" version | head -n1 || true)"
  log "${XRAY_VERSION}"

  if ! "$XRAY_BIN" help 2>/dev/null | grep -qE '(^|[[:space:]])vlessenc([[:space:]]|$)'; then
    err "当前 Xray 不支持 vlessenc，请升级到支持 VLESS Encryption 的新版 Xray"
    exit 1
  fi
}

performance_padding_profile() {
  # Keep protocol/auth/session fields generated by `xray vlessenc`,
  # but replace traffic-shaping padding with the minimum valid 35-byte
  # fixed padding and remove artificial random delay.
  local value="$1"
  local -a parts=()
  local last_index

  IFS='.' read -r -a parts <<<"$value"
  if (( ${#parts[@]} < 4 )); then
    return 1
  fi

  last_index=$((${#parts[@]} - 1))

  printf '%s.%s.%s.100-35-35.%s\n' \
    "${parts[0]}" \
    "${parts[1]}" \
    "${parts[2]}" \
    "${parts[$last_index]}"
}

generate_vless_encryption() {
  local raw section generated_decryption generated_encryption

  log "通过 xray vlessenc 生成 VLESS Encryption 参数"
  raw="$("$XRAY_BIN" vlessenc 2>&1)" || {
    err "xray vlessenc 执行失败"
    echo "$raw" >&2
    exit 1
  }

  # Current Xray prints X25519 first, then ML-KEM-768.
  # Prefer the X25519 authentication group for smaller auth material and lower overhead.
  section="$(printf '%s\n' "$raw" | awk '
    /Authentication:[[:space:]]*X25519/ { found=1; next }
    found && /Authentication:/ { exit }
    found { print }
  ')"

  # Defensive fallback if wording changes but the first generated pair is still usable.
  [[ -n "$section" ]] || section="$raw"

  generated_decryption="$(printf '%s\n' "$section" \
    | sed -nE 's/^[[:space:]]*"decryption"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n1)"

  generated_encryption="$(printf '%s\n' "$section" \
    | sed -nE 's/^[[:space:]]*"encryption"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n1)"

  if [[ -z "$generated_decryption" || -z "$generated_encryption" ]]; then
    err "无法解析 xray vlessenc 输出"
    echo "$raw" >&2
    exit 1
  fi

  VLESS_DECRYPTION="$(performance_padding_profile "$generated_decryption")" || {
    err "无法生成低延迟 decryption 配置"
    exit 1
  }

  VLESS_ENCRYPTION="$(performance_padding_profile "$generated_encryption")" || {
    err "无法生成低延迟 encryption 配置"
    exit 1
  }

  [[ "$VLESS_DECRYPTION" == mlkem768x25519plus.* ]] || {
    err "生成的 decryption 格式异常"
    exit 1
  }

  [[ "$VLESS_ENCRYPTION" == mlkem768x25519plus.* ]] || {
    err "生成的 encryption 格式异常"
    exit 1
  }
}

configure_xray() {
  log "配置 Xray：VLESS Encryption + RAW + Vision"

  PUBLIC_IP="$(detect_public_ip)"
  [[ -n "$PUBLIC_IP" ]] || {
    err "无法自动获取服务器公网 IP"
    exit 1
  }

  if [[ "$PUBLIC_IP" == *:* ]]; then
    URI_HOST="[${PUBLIC_IP}]"
  else
    URI_HOST="${PUBLIC_IP}"
  fi

  VLESS_UUID="$("$XRAY_BIN" uuid)"
  [[ -n "$VLESS_UUID" ]] || {
    err "UUID 生成失败"
    exit 1
  }

  generate_vless_encryption

  install -d -m 755 "$XRAY_CONFIG_DIR"

  if [[ -f "$XRAY_CONFIG" ]]; then
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.${TIMESTAMP}"
    log "已备份旧 Xray 配置"
  fi

  cat >"$XRAY_CONFIG" <<JSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-enc-raw-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${VLESS_DECRYPTION}"
      },
      "streamSettings": {
        "method": "raw",
        "security": "none",
        "rawSettings": {
          "acceptProxyProtocol": false,
          "header": {
            "type": "none"
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
JSON

  log "校验 Xray 配置"
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"

  systemctl daemon-reload || true
  systemctl enable xray
  systemctl restart xray

  if ! systemctl is-active --quiet xray; then
    err "Xray 启动失败"
    journalctl -u xray -n 80 --no-pager || true
    exit 1
  fi

  XRAY_SHARE_LINK="vless://${VLESS_UUID}@${URI_HOST}:${XRAY_PORT}?encryption=${VLESS_ENCRYPTION}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#xray-vless-enc-raw"
}

install_docker_and_compose() {
  if ! command -v docker >/dev/null 2>&1; then
    log "安装 Docker"
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker 已安装"
  fi

  systemctl enable --now docker
  usermod -aG docker "$TARGET_USER" || true

  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends docker-compose-plugin
  fi
}

get_home() {
  getent passwd "$TARGET_USER" | cut -d: -f6
}

ensure_edge_network() {
  docker network inspect edge >/dev/null 2>&1 \
    || docker network create edge >/dev/null
}

write_caddy_stack() {
  local home_dir stack_dir compose_file caddyfile
  home_dir="$(get_home)"
  stack_dir="${home_dir}/.config/docker/stacks/caddy"
  compose_file="${stack_dir}/compose.yaml"
  caddyfile="${stack_dir}/Caddyfile"

  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$stack_dir" \
    "${home_dir}/.local/share/caddy/data" \
    "${home_dir}/.config/caddy"

  cat >"$compose_file" <<YAML
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ${stack_dir}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${home_dir}/.local/share/caddy/data:/data
      - ${home_dir}/.config/caddy:/config
    networks:
      - edge

networks:
  edge:
    external: true
YAML

  {
    echo "{"
    echo "  email admin@${BASE_DOMAIN}"
    echo "}"
    echo

    if [[ "$ENABLE_METATUBE" == "true" ]]; then
      echo "metatube.${BASE_DOMAIN} {"
      echo "  reverse_proxy metatube:8080"
      echo "}"
      echo
    fi

    if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
      echo "playwright.service.${BASE_DOMAIN} {"
      echo "  reverse_proxy host.docker.internal:${PLAYWRIGHT_PORT}"
      echo "}"
      echo
    fi
  } >"$caddyfile"

  chown "$TARGET_USER:$TARGET_USER" "$compose_file" "$caddyfile"
  chmod 644 "$compose_file" "$caddyfile"

  docker compose -f "$compose_file" up -d
}

write_metatube_stack() {
  local home_dir stack_dir data_dir env_file compose_file
  home_dir="$(get_home)"
  stack_dir="${home_dir}/.config/docker/stacks/metatube"
  data_dir="${home_dir}/.local/share/metatube/postgres"
  env_file="${stack_dir}/.env"
  compose_file="${stack_dir}/compose.yaml"

  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" \
    "$stack_dir" "$data_dir"

  cat >"$env_file" <<ENV
METATUBE_TOKEN=${METATUBE_TOKEN}
TZ=${TIMEZONE}
ENV
  chown "$TARGET_USER:$TARGET_USER" "$env_file"
  chmod 600 "$env_file"

  cat >"$compose_file" <<'YAML'
services:
  metatube:
    image: ghcr.io/metatube-community/metatube-server:latest
    container_name: metatube
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - TOKEN=${METATUBE_TOKEN}
      - TZ=${TZ}
    command: >
      -dsn postgres://metatube:${METATUBE_TOKEN}@postgres:5432/metatube?sslmode=disable
      -port 8080
      -db-auto-migrate
      -db-prepared-stmt
    networks:
      - metatube_internal
      - edge

  postgres:
    image: postgres:17
    container_name: metatube_postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=metatube
      - POSTGRES_PASSWORD=${METATUBE_TOKEN}
      - POSTGRES_DB=metatube
      - TZ=${TZ}
    volumes:
      - __DATA_DIR__:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U metatube -d metatube"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - metatube_internal

networks:
  metatube_internal:
  edge:
    external: true
YAML

  sed -i "s#__DATA_DIR__#${data_dir}#g" "$compose_file"
  chown "$TARGET_USER:$TARGET_USER" "$compose_file"
  chmod 644 "$compose_file"

  docker compose --env-file "$env_file" -f "$compose_file" up -d
}

write_watchtower_stack() {
  local home_dir stack_dir compose_file
  home_dir="$(get_home)"
  stack_dir="${home_dir}/.config/docker/stacks/watchtower"
  compose_file="${stack_dir}/compose.yaml"

  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$stack_dir"

  cat >"$compose_file" <<'YAML'
services:
  watchtower:
    image: ghcr.io/containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --schedule "0 0 3 * * *" --cleanup
YAML

  chown "$TARGET_USER:$TARGET_USER" "$compose_file"
  chmod 644 "$compose_file"

  docker compose -f "$compose_file" up -d
}

precheck_conflicts() {
  log "预检查端口"

  if ss -lnt "( sport = :${XRAY_PORT} )" | grep -q ":${XRAY_PORT}"; then
    if ! systemctl is-active --quiet xray; then
      err "Xray 端口 ${XRAY_PORT} 已被其他服务占用"
      exit 1
    fi
  fi

  if uses_caddy; then
    if ss -lnt '( sport = :443 )' | grep -q ':443'; then
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy$'; then
        err "443 端口已被其他服务占用，无法部署 Caddy"
        exit 1
      fi
    fi
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if ! ss -lnt "( sport = :${PLAYWRIGHT_PORT} )" | grep -q ":${PLAYWRIGHT_PORT}"; then
      log "提示: Playwright ${PLAYWRIGHT_PORT} 尚未监听；反代会先创建，待服务启动后生效"
    fi
  fi
}

configure_ufw() {
  log "配置 UFW"
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  ufw allow 22/tcp >/dev/null
  ufw allow "${XRAY_PORT}/tcp" >/dev/null

  if uses_caddy; then
    ufw allow 443/tcp >/dev/null
  fi

  # Preserve the existing behavior: if Playwright is enabled, its configured
  # host port is also allowed directly in UFW in addition to the Caddy entry.
  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    ufw allow "${PLAYWRIGHT_PORT}/tcp" >/dev/null
  fi

  ufw --force enable >/dev/null
}

print_stage_summary() {
  echo
  echo "========== 参数汇总 =========="
  echo "[基础]"
  echo "target_user=${TARGET_USER}"
  echo "timezone=${TIMEZONE}"
  echo
  echo "[Xray]"
  echo "mode=vless_encryption_raw_vision"
  echo "port=${XRAY_PORT}"
  echo "transport=raw"
  echo "transport_security=none"
  echo "protocol_encryption=vless_encryption"
  echo
  echo "[MetaTube]"
  echo "enable=${ENABLE_METATUBE}"
  if [[ "$ENABLE_METATUBE" == "true" ]]; then
    echo "domain=metatube.${BASE_DOMAIN}"
  fi
  echo
  echo "[Playwright]"
  echo "enable=${ENABLE_PLAYWRIGHT}"
  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    echo "domain=playwright.service.${BASE_DOMAIN}"
    echo "origin_port=${PLAYWRIGHT_PORT}"
  fi
  echo
  echo "[Watchtower]"
  echo "enable=${ENABLE_WATCHTOWER}"
  echo
  echo "[Network]"
  echo "tcp_cc=${TCP_CC}"
  echo
  echo "[Firewall]"
  echo "allow=22/tcp,${XRAY_PORT}/tcp$(uses_caddy && printf ',443/tcp')$( [[ "$ENABLE_PLAYWRIGHT" == "true" ]] && printf ',%s/tcp' "$PLAYWRIGHT_PORT" )"
  echo "=============================="
  echo
}

write_outputs() {
  local qrcode_file client_config_file
  install -d -m 700 "$OUTPUT_DIR"

  qrcode_file="${OUTPUT_DIR}/xray-${TIMESTAMP}.png"
  client_config_file="${OUTPUT_DIR}/xray-client-${TIMESTAMP}.json"

  qrencode -o "$qrcode_file" "$XRAY_SHARE_LINK" || true

  cat >"$client_config_file" <<CLIENTJSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "address": "${PUBLIC_IP}",
        "port": ${XRAY_PORT},
        "id": "${VLESS_UUID}",
        "flow": "xtls-rprx-vision",
        "encryption": "${VLESS_ENCRYPTION}"
      },
      "streamSettings": {
        "method": "raw",
        "security": "none",
        "rawSettings": {
          "header": {
            "type": "none"
          }
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
CLIENTJSON

  chmod 600 "$client_config_file"

  cat >"$OUTPUT_FILE" <<EOF2
[Meta]
generated_at=${TIMESTAMP}
target_user=${TARGET_USER}
timezone=${TIMEZONE}

[Xray]
version=${XRAY_VERSION}
mode=vless_encryption_raw_vision
public_ip=${PUBLIC_IP}
port=${XRAY_PORT}
share_link=${XRAY_SHARE_LINK}
server_config=${XRAY_CONFIG}
client_config=${client_config_file}

[Domain]
base_domain=${BASE_DOMAIN}
metatube_domain=$( [[ "$ENABLE_METATUBE" == "true" ]] && echo "metatube.${BASE_DOMAIN}" || echo "" )
playwright_domain=$( [[ "$ENABLE_PLAYWRIGHT" == "true" ]] && echo "playwright.service.${BASE_DOMAIN}" || echo "" )

[Switch]
metatube=${ENABLE_METATUBE}
playwright=${ENABLE_PLAYWRIGHT}
watchtower=${ENABLE_WATCHTOWER}

[Network]
tcp_cc=${TCP_CC}

[Artifact]
qr_png=${qrcode_file}
EOF2

  ln -sfn "$OUTPUT_FILE" "$LATEST_FILE"

  echo
  echo "================ 执行结果 ================"
  cat "$OUTPUT_FILE"
  echo "=========================================="
  echo "结果文件: ${OUTPUT_FILE}"
  echo "快捷查看: ${LATEST_FILE}"
  echo "分享链接: ${XRAY_SHARE_LINK}"
  echo "二维码: ${qrcode_file}"
  echo "客户端 Xray 配置: ${client_config_file}"
  echo "客户端本地端口: 127.0.0.1:10808（同端口支持 SOCKS / HTTP；SOCKS UDP 已开启）"
}

main() {
  parse_args "$@"
  require_root
  check_os

  resolve_target_user
  init_ui_mode
  interactive_wizard_if_needed
  validate_inputs

  install_base_packages
  set_timezone
  ensure_user
  ensure_xdg_dirs

  precheck_conflicts
  configure_tcp_cc

  if needs_docker; then
    install_docker_and_compose
  fi

  if uses_caddy; then
    ensure_edge_network
  fi

  print_stage_summary

  install_xray
  configure_xray

  if uses_caddy; then
    write_caddy_stack
  fi

  if [[ "$ENABLE_METATUBE" == "true" ]]; then
    write_metatube_stack
  fi

  if [[ "$ENABLE_WATCHTOWER" == "true" ]]; then
    write_watchtower_stack
  fi

  configure_ufw
  write_outputs

  log "完成"
}

main "$@"
