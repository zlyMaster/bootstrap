#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

TIMEZONE="Asia/Shanghai"
TARGET_USER=""
USER_PASSWORD=""
BASE_DOMAIN=""

XRAY_MODE="" # vmess_ws_tls | vless_reality
XRAY_PORT=""

ENABLE_METATUBE=""
METATUBE_TOKEN=""
ENABLE_PLAYWRIGHT=""
PLAYWRIGHT_PORT=""
ENABLE_WATCHTOWER=""

REALITY_SERVER_NAME="www.cloudflare.com"
REALITY_DEST="www.cloudflare.com:443"
REALITY_UUID=""
REALITY_SHORT_ID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""

VMESS_UUID=""
VMESS_PATH=""

PUBLIC_IP=""
XRAY_SHARE_LINK=""

OUTPUT_DIR="/root/bootstrap-output"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${OUTPUT_DIR}/result-${TIMESTAMP}.txt"
LATEST_FILE="${OUTPUT_DIR}/latest.txt"

NON_INTERACTIVE="false"

usage() {
  cat <<USAGE
Usage:
  sudo bash ${SCRIPT_NAME} [options]

Options:
  -h, --help                       Show help
  --username <name>                Target Linux user
  --xray-mode <vmess_ws_tls|vless_reality>
  --xray-port <port>               Fixed xray inbound port
  --base-domain <domain>           Base domain (required for vmess_ws_tls/metatube/playwright)
  --enable-metatube <true|false>
  --metatube-token <token>
  --enable-playwright <true|false>
  --playwright-port <port>
  --enable-watchtower <true|false>

Notes:
  - No arguments => forced interactive wizard.
  - Baseline steps always executed: user + XDG + xray + firewall.
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
      --xray-mode)
        XRAY_MODE="${2:-}"
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

  if [[ -z "$XRAY_MODE" ]]; then
    echo "请选择 Xray 协议："
    echo "1) vmess + ws + tls (默认)"
    echo "2) vless + reality + tcp"
    local pick=""
    while true; do
      read -r -p "输入 1 或 2 [1]: " pick
      pick="${pick:-1}"
      case "$pick" in
        1) XRAY_MODE="vmess_ws_tls"; break ;;
        2) XRAY_MODE="vless_reality"; break ;;
        *) echo "请输入 1 或 2" ;;
      esac
    done
  fi

  if [[ -z "$XRAY_PORT" ]]; then
    read -r -p "Xray 端口（留空自动随机）: " XRAY_PORT
  fi

  if [[ -z "$ENABLE_METATUBE" ]]; then
    ENABLE_METATUBE="$(ask_yes_no '是否安装 MetaTube + Postgres?' 'n')"
  fi

  if [[ -z "$ENABLE_PLAYWRIGHT" ]]; then
    ENABLE_PLAYWRIGHT="$(ask_yes_no '是否配置 Playwright 反向代理入口?' 'n')"
  fi

  if [[ "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" || "$XRAY_MODE" == "vmess_ws_tls" ]]; then
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
    ENABLE_WATCHTOWER="$(ask_yes_no '是否安装 Watchtower?' 'y')"
  fi
}

validate_inputs() {
  [[ -n "$TARGET_USER" ]] || { err "目标用户名为空"; exit 1; }

  case "$XRAY_MODE" in
    vmess_ws_tls|vless_reality) ;;
    "") XRAY_MODE="vmess_ws_tls" ;;
    *) err "--xray-mode 仅支持 vmess_ws_tls 或 vless_reality"; exit 1 ;;
  esac

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

  if [[ "$XRAY_MODE" == "vmess_ws_tls" || "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    [[ -n "$BASE_DOMAIN" ]] || { err "需要 --base-domain"; exit 1; }
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
    tar unzip xz-utils jq qrencode openssl passwd ufw
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

install_xray() {
  log "安装 Xray"
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

configure_xray_vless_reality() {
  REALITY_UUID="$(cat /proc/sys/kernel/random/uuid)"
  REALITY_SHORT_ID="$(random_hex 4)"

  local xray_bin keys
  xray_bin="$(command -v xray || true)"
  [[ -x "$xray_bin" ]] || xray_bin="/usr/local/bin/xray"

  keys="$(${xray_bin} x25519 2>/dev/null | tr -d '\r' || true)"
  REALITY_PRIVATE_KEY="$(echo "$keys" | sed -nE 's/^[[:space:]]*Private[[:space:]_]*[Kk]ey:[[:space:]]*([A-Za-z0-9+/_=-]+).*/\1/p' | head -n1)"
  REALITY_PUBLIC_KEY="$(echo "$keys" | sed -nE 's/^[[:space:]]*(Public[[:space:]_]*[Kk]ey|Password \(PublicKey\)):[[:space:]]*([A-Za-z0-9+/_=-]+).*/\2/p' | head -n1)"

  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || { err "生成 REALITY 密钥失败"; exit 1; }

  cat > /usr/local/etc/xray/config.json <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision" }],
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
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
JSON

  XRAY_SHARE_LINK="vless://${REALITY_UUID}@${PUBLIC_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#xray-vless-reality"
}

configure_xray_vmess_ws_tls() {
  VMESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  VMESS_PATH="/$(random_hex 6)"

  cat > /usr/local/etc/xray/config.json <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${VMESS_UUID}", "alterId": 0 }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${VMESS_PATH}" }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
JSON

  XRAY_SHARE_LINK="vmess://$(printf '{\"v\":\"2\",\"ps\":\"xray-vmess-ws-tls\",\"add\":\"xray.%s\",\"port\":\"443\",\"id\":\"%s\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"xray.%s\",\"path\":\"%s\",\"tls\":\"tls\",\"sni\":\"xray.%s\",\"alpn\":\"\"}' "$BASE_DOMAIN" "$VMESS_UUID" "$BASE_DOMAIN" "$VMESS_PATH" "$BASE_DOMAIN" | base64 -w0)"
}

configure_xray() {
  install -d -m 755 /usr/local/etc/xray
  PUBLIC_IP="$(detect_public_ip)"
  [[ -n "$XRAY_PORT" ]] || XRAY_PORT="$(pick_free_port)"

  case "$XRAY_MODE" in
    vless_reality) configure_xray_vless_reality ;;
    vmess_ws_tls) configure_xray_vmess_ws_tls ;;
  esac

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

    if [[ "$XRAY_MODE" == "vmess_ws_tls" ]]; then
      echo "xray.${BASE_DOMAIN} {"
      echo "  reverse_proxy 127.0.0.1:${XRAY_PORT}"
      echo "}"
      echo
    fi

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

  if [[ "$XRAY_MODE" == "vmess_ws_tls" || "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    if ss -lnt '( sport = :443 )' | grep -q ':443'; then
      if ! docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
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
  ufw allow "${XRAY_PORT}/tcp" >/dev/null
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
  if [[ "$XRAY_MODE" == "vmess_ws_tls" ]]; then
    echo "domain=xray.${BASE_DOMAIN}"
  fi
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
  echo "[防火墙]"
  echo "allow=22/tcp,443/tcp,${XRAY_PORT:-dynamic}/tcp$( [[ "$ENABLE_PLAYWRIGHT" == "true" ]] && printf ',%s/tcp' "$PLAYWRIGHT_PORT" )"
  echo "=============================="
  echo
}

write_outputs() {
  local qrcode_file
  install -d -m 700 "$OUTPUT_DIR"
  qrcode_file="${OUTPUT_DIR}/xray-${TIMESTAMP}.png"
  qrencode -o "$qrcode_file" "$XRAY_SHARE_LINK" || true

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

[Domain]
base_domain=${BASE_DOMAIN}
xray_domain=$( [[ "$XRAY_MODE" == "vmess_ws_tls" ]] && echo "xray.${BASE_DOMAIN}" || echo "" )
metatube_domain=$( [[ "$ENABLE_METATUBE" == "true" ]] && echo "metatube.${BASE_DOMAIN}" || echo "" )
playwright_domain=$( [[ "$ENABLE_PLAYWRIGHT" == "true" ]] && echo "playwright.service.${BASE_DOMAIN}" || echo "" )

[Switch]
metatube=${ENABLE_METATUBE}
playwright=${ENABLE_PLAYWRIGHT}
watchtower=${ENABLE_WATCHTOWER}

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
}

main() {
  parse_args "$@"
  require_root
  check_os

  resolve_target_user
  interactive_wizard_if_needed
  validate_inputs

  install_base_packages
  set_timezone
  ensure_user
  ensure_xdg_dirs

  precheck_conflicts

  if [[ "$XRAY_MODE" == "vmess_ws_tls" || "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
    install_docker_and_compose
    ensure_edge_network
  fi

  print_stage_summary

  install_xray
  configure_xray

  if [[ "$XRAY_MODE" == "vmess_ws_tls" || "$ENABLE_METATUBE" == "true" || "$ENABLE_PLAYWRIGHT" == "true" ]]; then
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
