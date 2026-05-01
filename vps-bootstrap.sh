#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

TIMEZONE="Asia/Shanghai"
TARGET_USER=""
USER_PASSWORD=""
BASE_DOMAIN=""
ENABLE_METATUBE="false"
METATUBE_TOKEN=""
ENABLE_PLAYWRIGHT="false"
PLAYWRIGHT_PORT=""
XRAY_PORT=""

REALITY_SERVER_NAME="www.cloudflare.com"
REALITY_DEST="www.cloudflare.com:443"

XRAY_UUID=""
XRAY_SHORT_ID=""
XRAY_PRIVATE_KEY=""
XRAY_PUBLIC_KEY=""

PUBLIC_IP=""
VLESS_URL=""

OUTPUT_DIR="/root/bootstrap-output"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${OUTPUT_DIR}/result-${TIMESTAMP}.txt"
LATEST_FILE="${OUTPUT_DIR}/latest.txt"

usage() {
  cat <<USAGE
Usage:
  sudo bash ${SCRIPT_NAME} [options]

Options:
  -h, --help                     Show this help
  --username <name>              Target Linux user (optional; auto-detect in sudo mode)
  --base-domain <domain>         Base domain, e.g. vps.master.zeayii.org
  --enable-metatube <true|false> Deploy metatube + postgres + caddy + watchtower (default: false)
  --metatube-token <token>       Token used by metatube (required when metatube=true)
  --enable-playwright <true|false>Enable playwright reverse-proxy entry (default: false)
  --playwright-port <port>       Playwright service local port (required when playwright=true)
  --xray-port <port>             Fixed xray port (default: random free port)

Notes:
  - xray is always installed and uses IP + port in share link.
  - playwright image/container is NOT installed by this script; only caddy route + firewall rule are managed.
USAGE
}

log() { printf '[INFO] %s\n' "$*"; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

validate_bool() {
  local v="$1"; local k="$2"
  if [[ "$v" != "true" && "$v" != "false" ]]; then
    err "$k 必须是 true 或 false"
    exit 1
  fi
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "必须使用 root/sudo 执行，例如：sudo bash ${SCRIPT_NAME}"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "无法识别系统（缺少 /etc/os-release）"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) err "仅支持 Debian/Ubuntu，当前系统: ${ID:-unknown}"; exit 1 ;;
  esac
}

parse_args() {
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
      --xray-port)
        XRAY_PORT="${2:-}"
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
    err "两次输入不一致或为空，请重试。"
  done
}

resolve_target_user() {
  if [[ -n "$TARGET_USER" ]]; then
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
    log "检测到 sudo 用户: ${TARGET_USER}"
    return 0
  fi

  if [[ "$(id -un)" == "root" ]]; then
    read -r -p "当前为 root 直接执行，请输入目标用户名: " TARGET_USER
    if [[ -z "$TARGET_USER" ]]; then
      err "用户名不能为空"
      exit 1
    fi
    return 0
  fi

  err "无法识别目标用户，请使用 --username 指定"
  exit 1
}

validate_inputs() {
  [[ -n "$TARGET_USER" ]] || { err "目标用户名为空"; exit 1; }
  validate_bool "$ENABLE_METATUBE" "--enable-metatube"
  validate_bool "$ENABLE_PLAYWRIGHT" "--enable-playwright"

  if [[ -n "$XRAY_PORT" ]] && ! is_valid_port "$XRAY_PORT"; then
    err "--xray-port 必须是 1-65535"
    exit 1
  fi

  if [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if [[ -z "$BASE_DOMAIN" ]]; then
      read -r -p "请输入基础域名（如 vps.master.zeayii.org）: " BASE_DOMAIN
    fi
    [[ -n "$BASE_DOMAIN" ]] || { err "基础域名不能为空"; exit 1; }
  fi

  if [[ "$ENABLE_METATUBE" == "true" && -z "$METATUBE_TOKEN" ]]; then
    read -r -s -p "请输入 MetaTube TOKEN: " METATUBE_TOKEN
    echo
    [[ -n "$METATUBE_TOKEN" ]] || { err "MetaTube TOKEN 不能为空"; exit 1; }
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if [[ -z "$PLAYWRIGHT_PORT" ]]; then
      read -r -p "请输入 Playwright 本机服务端口: " PLAYWRIGHT_PORT
    fi
    if ! is_valid_port "$PLAYWRIGHT_PORT"; then
      err "Playwright 端口必须是 1-65535"
      exit 1
    fi
  fi
}

install_base_packages() {
  log "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release \
    tar unzip xz-utils jq qrencode openssl passwd \
    ufw
}

set_timezone() {
  log "设置时区 ${TIMEZONE}"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$TIMEZONE"
  else
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata
  fi
}

ensure_user() {
  if id "$TARGET_USER" >/dev/null 2>&1; then
    log "用户 ${TARGET_USER} 已存在"
  else
    log "创建用户 ${TARGET_USER}"
    useradd -m -s /bin/bash "$TARGET_USER"
    if [[ -z "$USER_PASSWORD" ]]; then
      prompt_confirmed_password
    fi
    echo "${TARGET_USER}:${USER_PASSWORD}" | chpasswd
    log "用户 ${TARGET_USER} 创建完成"
  fi
  usermod -aG sudo "$TARGET_USER"
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

random_hex() {
  local bytes="${1:-16}"
  openssl rand -hex "$bytes" | tr -d '\n'
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsSL --max-time 8 https://ifconfig.me || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  echo "$ip"
}

install_xray() {
  log "安装 Xray Core"
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

configure_xray() {
  log "生成 Xray VLESS+REALITY 配置"
  if [[ -z "$XRAY_PORT" ]]; then
    XRAY_PORT="$(pick_free_port)"
  fi
  XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
  XRAY_SHORT_ID="$(random_hex 4)"

  local keys xray_bin
  xray_bin="$(command -v xray || true)"
  if [[ -z "$xray_bin" && -x /usr/local/bin/xray ]]; then
    xray_bin="/usr/local/bin/xray"
  fi
  [[ -n "$xray_bin" ]] || { err "未找到 xray 可执行文件"; exit 1; }

  keys="$(${xray_bin} x25519 2>/dev/null | tr -d '\r' || true)"
  XRAY_PRIVATE_KEY="$(echo "$keys" | sed -nE 's/^[[:space:]]*Private[[:space:]_]*[Kk]ey:[[:space:]]*([A-Za-z0-9+/_=-]+).*/\1/p' | head -n1)"
  XRAY_PUBLIC_KEY="$(echo "$keys" | sed -nE 's/^[[:space:]]*(Public[[:space:]_]*[Kk]ey|Password \(PublicKey\)):[[:space:]]*([A-Za-z0-9+/_=-]+).*/\2/p' | head -n1)"

  [[ -n "$XRAY_PRIVATE_KEY" && -n "$XRAY_PUBLIC_KEY" ]] || { err "生成 REALITY 密钥失败"; exit 1; }

  install -d -m 755 /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${XRAY_UUID}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SERVER_NAME}"],
          "privateKey": "${XRAY_PRIVATE_KEY}",
          "shortIds": ["${XRAY_SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
JSON

  "${xray_bin}" run -test -config /usr/local/etc/xray/config.json
  systemctl enable --now xray
  systemctl restart xray
}

install_docker_and_compose() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装"
  else
    log "安装 Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker
  usermod -aG docker "$TARGET_USER" || true

  if ! docker compose version >/dev/null 2>&1; then
    log "安装 docker-compose-plugin"
    apt-get update -y
    apt-get install -y --no-install-recommends docker-compose-plugin
  fi
}

get_home() {
  getent passwd "$TARGET_USER" | cut -d: -f6
}

ensure_edge_network() {
  if ! docker network inspect edge >/dev/null 2>&1; then
    docker network create edge >/dev/null
  fi
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

write_caddy_stack() {
  local home_dir stack_dir compose_file caddyfile
  home_dir="$(get_home)"
  stack_dir="${home_dir}/.config/docker/stacks/caddy"
  compose_file="${stack_dir}/compose.yaml"
  caddyfile="${stack_dir}/Caddyfile"

  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "$stack_dir"
  install -d -m 755 -o "$TARGET_USER" -g "$TARGET_USER" "${home_dir}/.local/share/caddy/data" "${home_dir}/.config/caddy"

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
    fi
  } > "$caddyfile"

  chown "$TARGET_USER:$TARGET_USER" "$compose_file" "$caddyfile"
  chmod 644 "$compose_file" "$caddyfile"

  docker compose -f "$compose_file" up -d
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

configure_ufw() {
  log "配置 UFW 最小开放规则"
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow "${XRAY_PORT}/tcp" >/dev/null

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    ufw allow "${PLAYWRIGHT_PORT}/tcp" >/dev/null
  fi

  ufw --force enable >/dev/null
}

precheck_conflicts() {
  log "预检查端口冲突"
  if [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if ss -lnt '( sport = :443 )' | grep -q ':443'; then
      if ! docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
        err "检测到 443 端口已被其他服务占用，无法部署 caddy"
        exit 1
      fi
    fi
  fi

  if [[ -n "$XRAY_PORT" ]] && ss -lnt "( sport = :${XRAY_PORT} )" | grep -q ":${XRAY_PORT}"; then
    if ! systemctl is-active --quiet xray; then
      err "xray 端口 ${XRAY_PORT} 已占用"
      exit 1
    fi
  fi

  if [[ "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if ! ss -lnt "( sport = :${PLAYWRIGHT_PORT} )" | grep -q ":${PLAYWRIGHT_PORT}"; then
      log "提示: playwright 端口 ${PLAYWRIGHT_PORT} 当前未监听，caddy 路由会先创建，待你的私有服务启动后生效"
    fi
  fi
}

print_stage_summary() {
  echo
  echo "========== 参数汇总 =========="
  echo "[基础]"
  echo "target_user=${TARGET_USER}"
  echo "timezone=${TIMEZONE}"
  echo
  echo "[Xray]"
  echo "install=true"
  echo "xray_port=${XRAY_PORT:-random}"
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
  echo "[防火墙]"
  echo "allow=22/tcp,443/tcp,${XRAY_PORT:-dynamic}/tcp${ENABLE_PLAYWRIGHT:+,${PLAYWRIGHT_PORT}/tcp}"
  echo "=============================="
  echo
}

write_outputs() {
  local qrcode_file
  PUBLIC_IP="$(detect_public_ip)"
  VLESS_URL="vless://${XRAY_UUID}@${PUBLIC_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp&headerType=none#vps-${PUBLIC_IP}"

  install -d -m 700 "$OUTPUT_DIR"
  qrcode_file="${OUTPUT_DIR}/vless-${TIMESTAMP}.png"
  qrencode -o "$qrcode_file" "$VLESS_URL" || true

  cat > "$OUTPUT_FILE" <<EOF2
[Meta]
generated_at=${TIMESTAMP}
target_user=${TARGET_USER}
timezone=${TIMEZONE}

[Xray]
public_ip=${PUBLIC_IP}
port=${XRAY_PORT}
uuid=${XRAY_UUID}
reality_server_name=${REALITY_SERVER_NAME}
reality_public_key=${XRAY_PUBLIC_KEY}
reality_short_id=${XRAY_SHORT_ID}
import_url=${VLESS_URL}
qr_png=${qrcode_file}

[MetaTube]
enabled=${ENABLE_METATUBE}
domain=$( [[ "$ENABLE_METATUBE" == "true" ]] && echo "metatube.${BASE_DOMAIN}" || echo "" )

[Playwright]
enabled=${ENABLE_PLAYWRIGHT}
domain=$( [[ "$ENABLE_PLAYWRIGHT" == "true" ]] && echo "playwright.service.${BASE_DOMAIN}" || echo "" )
origin_port=${PLAYWRIGHT_PORT}
EOF2

  ln -sfn "$OUTPUT_FILE" "$LATEST_FILE"

  echo
  echo "================ 执行结果 ================"
  cat "$OUTPUT_FILE"
  echo "========================================="
  echo "结果文件: ${OUTPUT_FILE}"
  echo "快捷查看: ${LATEST_FILE}"
  echo "分享链接: ${VLESS_URL}"
}

main() {
  parse_args "$@"
  require_root
  check_os
  resolve_target_user
  validate_inputs

  install_base_packages
  set_timezone
  ensure_user
  ensure_xdg_dirs

  precheck_conflicts
  print_stage_summary

  install_xray
  configure_xray

  if [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    install_docker_and_compose
    ensure_edge_network
    write_caddy_stack
  fi

  if [[ "$ENABLE_METATUBE" == "true" ]]; then
    write_metatube_stack
    write_watchtower_stack
  fi

  configure_ufw
  write_outputs
  log "完成"
}

main "$@"
