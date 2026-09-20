#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
TARGET_USER=""
USER_PASSWORD=""
BASE_DOMAIN=""

# Recommended default for daily VPS:
# vless_enc_raw = VLESS Encryption + RAW + Vision, direct IP, no TLS/REALITY.
XRAY_MODE="vless_enc_raw"
XRAY_PORT=""

ENABLE_METATUBE=""
METATUBE_TOKEN=""
ENABLE_PLAYWRIGHT=""
PLAYWRIGHT_PORT=""
ENABLE_WATCHTOWER=""
TCP_CC="bbr" # bbr | cubic | reno

VLESS_UUID=""
VLESS_ENC_DECRYPTION=""
VLESS_ENC_ENCRYPTION=""

PUBLIC_IP=""
XRAY_SHARE_LINK=""

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
  --xray-port <port>                 Fixed Xray inbound port
  --base-domain <domain>             Base domain, e.g. jp.server.example.com
  --enable-metatube <true|false>
  --metatube-token <token>
  --enable-playwright <true|false>
  --playwright-port <port>
  --enable-watchtower <true|false>
  --tcp-cc <bbr|cubic|reno>          TCP congestion control, default: bbr

Proxy:
  Fixed main mode: VLESS Encryption + RAW + Vision (direct IP, low latency)

Notes:
  - No arguments => interactive wizard.
  - Baseline steps always executed: user + XDG dirs + Xray + firewall + TCP CC.
  - Domain modes use Caddy on Docker for HTTPS certificates and reverse proxy.
USAGE
}

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "必须使用 root/sudo 运行，例如：sudo bash ${SCRIPT_NAME}"
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
  local v="$1"; local k="$2"
  [[ "$v" == "true" || "$v" == "false" ]] || { err "$k 必须是 true 或 false"; exit 1; }
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
  if [[ "$NON_INTERACTIVE" == "false" ]] && command -v whiptail >/dev/null 2>&1 && [[ -t 0 ]] && [[ -t 1 ]]; then
    USE_WHIPTAIL="true"
  fi
}

menu_yes_no() {
  local title="$1"
  local text="$2"
  local default_yes="$3"
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

interactive_wizard_if_needed() {
  if [[ "$NON_INTERACTIVE" != "false" ]]; then
    return
  fi

  echo
  echo "===== 交互向导 ====="

  if [[ -z "$XRAY_PORT" ]]; then
    read -r -p "Xray 端口（RAW直连留空默认443；Caddy占用443时自动随机）: " XRAY_PORT
  fi

  if [[ -z "$ENABLE_METATUBE" ]]; then
    ENABLE_METATUBE="$(menu_yes_no 'MetaTube' '是否安装 MetaTube + Postgres?' 'n')"
  fi

  if [[ -z "$ENABLE_PLAYWRIGHT" ]]; then
    ENABLE_PLAYWRIGHT="$(menu_yes_no 'Playwright' '是否配置 Playwright 反向代理入口?' 'n')"
  fi

  if requires_base_domain; then
    if [[ -z "$BASE_DOMAIN" ]]; then
      BASE_DOMAIN="$(ask_non_empty '请输入基础域名（如 jp.server.master.zeayii.org）: ')"
    fi
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

requires_base_domain() {
  [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]
}

uses_caddy() {
  [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]
}

validate_inputs() {
  [[ -n "$TARGET_USER" ]] || { err "目标用户名为空"; exit 1; }

  if [[ -n "$XRAY_PORT" ]] && ! is_valid_port "$XRAY_PORT"; then
    err "--xray-port 非法"
    exit 1
  fi

  if [[ -z "$ENABLE_METATUBE" ]]; then ENABLE_METATUBE="false"; fi
  if [[ -z "$ENABLE_PLAYWRIGHT" ]]; then ENABLE_PLAYWRIGHT="false"; fi
  if [[ -z "$ENABLE_WATCHTOWER" ]]; then ENABLE_WATCHTOWER="true"; fi

  validate_bool "$ENABLE_METATUBE" "--enable-metatube"
  validate_bool "$ENABLE_PLAYWRIGHT" "--enable-playwright"
  validate_bool "$ENABLE_WATCHTOWER" "--enable-watchtower"

  # Direct RAW mode prefers 443 for the same low-overhead path as the old
  # VMess+TCP node. If Caddy is needed by MetaTube/Playwright, leave the
  # Xray port empty here so configure_xray() can pick a free direct port.
  if [[ -z "$XRAY_PORT" && "$XRAY_MODE" == "vless_enc_raw" ]] && ! uses_caddy; then
    XRAY_PORT="443"
  fi

  case "$TCP_CC" in
    bbr|cubic|reno) ;;
    *) err "--tcp-cc 仅支持 bbr/cubic/reno"; exit 1 ;;
  esac

  if requires_base_domain; then
    [[ -n "$BASE_DOMAIN" ]] || { err "当前配置需要 --base-domain"; exit 1; }
  fi

  if [[ "$ENABLE_METATUBE" == "true" ]]; then
    [[ -n "$METATUBE_TOKEN" ]] || { err "启用 metatube 时必须提供 --metatube-token 或交互输入"; exit 1; }
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    is_valid_port "$PLAYWRIGHT_PORT" || { err "playwright 端口非法"; exit 1; }
  fi
}

install_base_packages() {
  log "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
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

random_port() { shuf -i 10000-65535 -n 1; }

pick_free_port() {
  local p
  for _ in $(seq 1 50); do
    p="$(random_port)"
    if ! ss -lnt "( sport = :${p} )" | grep -q ":${p}"; then
      echo "$p"
      return 0
    fi
  done
  err "无法找到空闲端口"
  exit 1
}

random_hex() { openssl rand -hex "${1:-16}" | tr -d '\n'; }

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://api.ipify.org || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsSL --max-time 8 https://ifconfig.me || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

configure_tcp_cc() {
  log "配置 TCP 拥塞控制: ${TCP_CC}"

  cat > /etc/sysctl.d/99-bootstrap-net.conf <<EOFCC
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${TCP_CC}
EOFCC

  sysctl --system >/dev/null || true
}

install_xray() {
  log "安装 Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

generate_vless_encryption() {
  local xray_bin keys private_key password
  xray_bin="$(command -v xray || true)"
  [[ -x "$xray_bin" ]] || xray_bin="/usr/local/bin/xray"

  keys="$("${xray_bin}" x25519 2>/dev/null | tr -d '\r' || true)"
  private_key="$(printf '%s\n' "$keys" | awk -F': *' '
    /^PrivateKey[[:space:]]*:/ || /^Private key[[:space:]]*:/ {
      print $2
      exit
    }
  ' | awk '{print $1}')"
  password="$(printf '%s\n' "$keys" | awk -F': *' '
    /^Password/ || /^Public key[[:space:]]*:/ || /^PublicKey[[:space:]]*:/ {
      print $2
      exit
    }
  ' | awk '{print $1}')"

  [[ -n "$private_key" && -n "$password" ]] || {
    err "生成 VLESS Encryption X25519 认证参数失败"
    echo "$keys" >&2
    exit 1
  }

  # Performance-oriented profile:
  # - X25519 authentication: smaller/faster than static ML-KEM authentication.
  # - native: no extra traffic-obfuscation transform.
  # - 0rtt: reuse server-issued tickets on subsequent connections.
  # - 100-35-35: Xray's minimum valid first padding, with NO delay/jitter block.
  # - 43200s: tickets remain valid for roughly 6-12 hours, reducing full handshakes.
  VLESS_ENC_DECRYPTION="mlkem768x25519plus.native.43200s.100-35-35.${private_key}"
  VLESS_ENC_ENCRYPTION="mlkem768x25519plus.native.0rtt.100-35-35.${password}"
}

configure_xray_vless_enc_raw() {
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  generate_vless_encryption

  cat > /usr/local/etc/xray/config.json <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${VLESS_ENC_DECRYPTION}"
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
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
JSON

  XRAY_SHARE_LINK="vless://${VLESS_UUID}@${PUBLIC_IP}:${XRAY_PORT}?encryption=${VLESS_ENC_ENCRYPTION}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#xray-vless-enc-raw"
}

configure_xray() {
  install -d -m 755 /usr/local/etc/xray
  PUBLIC_IP="$(detect_public_ip)"
  [[ -n "$XRAY_PORT" ]] || XRAY_PORT="$(pick_free_port)"

  configure_xray_vless_enc_raw

  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
  systemctl enable --now xray
  systemctl restart xray
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

get_home() { getent passwd "$TARGET_USER" | cut -d: -f6; }

ensure_edge_network() {
  docker network inspect edge >/dev/null 2>&1 || docker network create edge >/dev/null
}

write_caddy_stack() {
  local home_dir stack_dir compose_file caddyfile
  home_dir="$(get_home)"
  stack_dir="${home_dir}/.config/docker/stacks/caddy"
  compose_file="${stack_dir}/compose.yaml"
  caddyfile="${stack_dir}/Caddyfile"

  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$stack_dir" "${home_dir}/.local/share/caddy/data" "${home_dir}/.config/caddy"

  cat > "$compose_file" <<YAML
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
  } > "$caddyfile"

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

  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$stack_dir" "$data_dir"

  cat > "$env_file" <<ENV
METATUBE_TOKEN=${METATUBE_TOKEN}
TZ=${TIMEZONE}
ENV
  chown "$TARGET_USER:$TARGET_USER" "$env_file"
  chmod 600 "$env_file"

  cat > "$compose_file" <<'YAML'
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

  cat > "$compose_file" <<'YAML'
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
  log "预检查"

  if [[ -n "$XRAY_PORT" ]]; then
    if ss -lnt "( sport = :${XRAY_PORT} )" | grep -q ":${XRAY_PORT}"; then
      if ! systemctl is-active --quiet xray; then
        err "xray 端口 ${XRAY_PORT} 已被占用"
        exit 1
      fi
    fi
  fi

  if uses_caddy; then
    if ss -lnt '( sport = :443 )' | grep -q ':443'; then
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy$'; then
        err "443 端口已被其他服务占用，无法部署 caddy"
        exit 1
      fi
    fi
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if ! ss -lnt "( sport = :${PLAYWRIGHT_PORT} )" | grep -q ":${PLAYWRIGHT_PORT}"; then
      log "提示: playwright ${PLAYWRIGHT_PORT} 尚未监听，反代会先创建，待服务启动后生效"
    fi
  fi
}

configure_ufw() {
  log "配置 UFW"
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  if [[ "$XRAY_MODE" == "vless_enc_raw" && "$XRAY_PORT" != "443" ]]; then
    ufw allow "${XRAY_PORT}/tcp" >/dev/null
  fi
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
  echo "mode=${XRAY_MODE}"
  echo "port=${XRAY_PORT:-random}"
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
  echo "[防火墙]"
  echo "allow=22/tcp,443/tcp$( [[ "$XRAY_MODE" == "vless_enc_raw" && "$XRAY_PORT" != "443" ]] && printf ',%s/tcp' "$XRAY_PORT" )$( [[ "$ENABLE_PLAYWRIGHT" == "true" ]] && printf ',%s/tcp' "$PLAYWRIGHT_PORT" )"
  echo "=============================="
  echo
}

write_outputs() {
  local qrcode_file client_config_file=""
  install -d -m 700 "$OUTPUT_DIR"
  qrcode_file="${OUTPUT_DIR}/xray-${TIMESTAMP}.png"
  qrencode -o "$qrcode_file" "$XRAY_SHARE_LINK" || true

  if [[ "$XRAY_MODE" == "vless_enc_raw" ]]; then
    client_config_file="${OUTPUT_DIR}/xray-client-${TIMESTAMP}.json"
    cat > "$client_config_file" <<CLIENTJSON
{
  "log": { "loglevel": "warning" },
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
        "encryption": "${VLESS_ENC_ENCRYPTION}",
        "flow": "xtls-rprx-vision"
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
  fi

  cat > "$OUTPUT_FILE" <<EOF2
[Meta]
generated_at=${TIMESTAMP}
target_user=${TARGET_USER}
timezone=${TIMEZONE}

[Xray]
mode=${XRAY_MODE}
public_ip=${PUBLIC_IP}
port=${XRAY_PORT}
share_link=${XRAY_SHARE_LINK}
client_config=${client_config_file}

[Domain]
base_domain=${BASE_DOMAIN}
xray_domain=
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
  echo "========================================="
  echo "结果文件: ${OUTPUT_FILE}"
  echo "快捷查看: ${LATEST_FILE}"
  echo "分享链接: ${XRAY_SHARE_LINK}"
  if [[ -n "$client_config_file" ]]; then
    echo "客户端配置: ${client_config_file}（127.0.0.1:10808 同端口支持 SOCKS/HTTP，SOCKS UDP 已开启）"
  fi
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

  if uses_caddy; then
    install_docker_and_compose
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
  configure_tcp_cc
  write_outputs
  log "完成"
}

main "$@"
