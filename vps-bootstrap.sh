#!/usr/bin/env bash
set -euo pipefail

# VPS 一键基础脚本（Debian/Ubuntu）
# 功能：
# 1) root 校验 + 系统校验
# 2) 设置时区 Asia/Shanghai
# 3) 创建普通用户并初始化 XDG 目录
# 4) 安装并配置 Xray（VLESS + REALITY），自动随机端口并输出导入链接
# 5) 可选安装 Docker 与 MetaTube（XDG 路径 + 自动重启）
# 6) 可选安装 Watchtower（自动更新容器）

SCRIPT_NAME="$(basename "$0")"

TARGET_USER="app"
INSTALL_DOCKER="false"
INSTALL_METATUBE="false"
METATUBE_HOST_PORT="8080"
ENABLE_WATCHTOWER="false"
TIMEZONE="Asia/Shanghai"
REALITY_SERVER_NAME="www.cloudflare.com"
REALITY_DEST="www.cloudflare.com:443"

OUTPUT_DIR="/root/bootstrap-output"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${OUTPUT_DIR}/result-${TIMESTAMP}.txt"
LATEST_FILE="${OUTPUT_DIR}/latest.txt"

usage() {
  cat <<EOF
Usage:
  sudo bash ${SCRIPT_NAME} [options]

Options:
  -h, --help                      Show this help
  --username <name>               Linux user to create/use (default: app)
  --install-docker <true|false>   Install Docker (default: false)
  --install-metatube <true|false> Install MetaTube (default: false; requires Docker)
  --metatube-host-port <port>     Host port for MetaTube (container is fixed to 8080)
  --enable-watchtower <true|false>Enable Watchtower auto-update (default: false)

Examples:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --username vps --install-docker true
  sudo bash ${SCRIPT_NAME} --install-docker true --install-metatube true --metatube-host-port 18080
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root/sudo 执行，例如：sudo bash ${SCRIPT_NAME}"
    exit 1
  fi
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
      --install-docker)
        INSTALL_DOCKER="${2:-}"
        shift 2
        ;;
      --install-metatube)
        INSTALL_METATUBE="${2:-}"
        shift 2
        ;;
      --metatube-host-port)
        METATUBE_HOST_PORT="${2:-}"
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

validate_bool() {
  local value="$1"
  local key="$2"
  if [[ "${value}" != "true" && "${value}" != "false" ]]; then
    err "${key} 必须是 true 或 false"
    exit 1
  fi
}

validate_inputs() {
  [[ -n "${TARGET_USER}" ]] || { err "--username 不能为空"; exit 1; }
  validate_bool "${INSTALL_DOCKER}" "--install-docker"
  validate_bool "${INSTALL_METATUBE}" "--install-metatube"
  validate_bool "${ENABLE_WATCHTOWER}" "--enable-watchtower"

  if [[ ! "${METATUBE_HOST_PORT}" =~ ^[0-9]+$ ]] || (( METATUBE_HOST_PORT < 1 || METATUBE_HOST_PORT > 65535 )); then
    err "--metatube-host-port 必须是 1-65535 的整数"
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
    *)
      err "仅支持 Debian/Ubuntu，当前系统: ${ID:-unknown}"
      exit 1
      ;;
  esac
}

install_base_packages() {
  log "安装基础依赖包"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release \
    tar unzip xz-utils jq qrencode openssl passwd
}

set_timezone() {
  log "设置时区 ${TIMEZONE}"
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "${TIMEZONE}"
  else
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata
  fi
}

ensure_user() {
  if id "${TARGET_USER}" >/dev/null 2>&1; then
    log "用户 ${TARGET_USER} 已存在，跳过创建"
  else
    log "创建用户 ${TARGET_USER}"
    useradd -m -s /bin/bash "${TARGET_USER}"
    # 生成随机初始密码并打印给用户；建议首次登录后立刻修改
    local init_pass
    init_pass="$(openssl rand -base64 18 | tr -d '\n')"
    echo "${TARGET_USER}:${init_pass}" | chpasswd
    log "用户 ${TARGET_USER} 初始密码: ${init_pass}"
  fi

  usermod -aG sudo "${TARGET_USER}"
}

ensure_xdg_dirs() {
  local home_dir
  home_dir="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  [[ -n "${home_dir}" ]] || { err "无法解析用户 Home"; exit 1; }

  log "初始化 ${TARGET_USER} 的 XDG 目录"
  install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${home_dir}/.ssh"
  install -d -m 755 -o "${TARGET_USER}" -g "${TARGET_USER}" \
    "${home_dir}/.config" \
    "${home_dir}/.local/share" \
    "${home_dir}/.local/state" \
    "${home_dir}/.cache" \
    "${home_dir}/.local/bin"
}

random_port() {
  shuf -i 10000-65535 -n 1
}

pick_free_port() {
  local p
  for _ in $(seq 1 50); do
    p="$(random_port)"
    if ! ss -lnt "( sport = :${p} )" | grep -q ":${p}"; then
      echo "${p}"
      return 0
    fi
  done
  err "无法找到空闲端口"
  exit 1
}

random_hex() {
  local bytes="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${bytes}" | tr -d '\n'
  else
    head -c "${bytes}" /dev/urandom | xxd -p -c "${bytes}" | tr -d '\n'
  fi
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsSL --max-time 8 https://api.ipify.org || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -4fsSL --max-time 8 https://ifconfig.me || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  echo "${ip}"
}

install_xray() {
  log "安装 Xray Core（官方脚本）"
  bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
}

configure_xray() {
  log "生成 Xray VLESS+REALITY 配置"
  XRAY_PORT="$(pick_free_port)"
  XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"
  XRAY_SHORT_ID="$(random_hex 4)"

  local keys
  keys="$(xray x25519)"
  XRAY_PRIVATE_KEY="$(echo "${keys}" | awk '/Private key:/ {print $3}')"
  XRAY_PUBLIC_KEY="$(echo "${keys}" | awk '/Public key:/ {print $3}')"

  if [[ -z "${XRAY_PRIVATE_KEY}" || -z "${XRAY_PUBLIC_KEY}" ]]; then
    err "生成 REALITY 密钥失败"
    exit 1
  fi

  install -d -m 755 /usr/local/etc/xray
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${XRAY_PRIVATE_KEY}",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "${XRAY_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装，跳过安装"
  else
    log "安装 Docker（官方 get.docker.com）"
    curl -fsSL https://get.docker.com | sh
  fi

  systemctl enable --now docker
  usermod -aG docker "${TARGET_USER}" || true
}

install_metatube() {
  local home_dir stack_dir data_dir env_file compose_file token
  home_dir="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  stack_dir="${home_dir}/.config/docker/stacks/metatube"
  data_dir="${home_dir}/.local/share/metatube/postgres"
  env_file="${stack_dir}/.env"
  compose_file="${stack_dir}/compose.yaml"

  install -d -m 755 -o "${TARGET_USER}" -g "${TARGET_USER}" "${stack_dir}"
  install -d -m 755 -o "${TARGET_USER}" -g "${TARGET_USER}" "${data_dir}"

  token="$(random_hex 32)"

  cat > "${env_file}" <<EOF
METATUBE_TOKEN=${token}
METATUBE_HOST_PORT=${METATUBE_HOST_PORT}
TZ=${TIMEZONE}
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${env_file}"
  chmod 600 "${env_file}"

  cat > "${compose_file}" <<'EOF'
services:
  server:
    image: ghcr.io/metatube-community/metatube-server:latest
    container_name: metatube_server
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "${METATUBE_HOST_PORT}:8080"
    environment:
      - DATABASE_URL=postgres://metatube:${METATUBE_TOKEN}@postgres:5432/metatube
      - TOKEN=${METATUBE_TOKEN}
      - TZ=${TZ}

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
EOF

  sed -i "s#__DATA_DIR__#${data_dir}#g" "${compose_file}"
  chown "${TARGET_USER}:${TARGET_USER}" "${compose_file}"
  chmod 644 "${compose_file}"

  docker compose --env-file "${env_file}" -f "${compose_file}" up -d
}

install_watchtower() {
  log "部署 Watchtower（仅更新标记容器）"
  docker rm -f watchtower >/dev/null 2>&1 || true
  docker run -d \
    --name watchtower \
    --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --label com.centurylinklabs.watchtower.enable=true \
    ghcr.io/containrrr/watchtower:latest \
    --label-enable \
    --schedule "0 0 4 * * *" \
    --cleanup
}

write_outputs() {
  local public_ip vless_url qrcode_file
  public_ip="$(detect_public_ip)"

  vless_url="vless://${XRAY_UUID}@${public_ip}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${XRAY_PUBLIC_KEY}&sid=${XRAY_SHORT_ID}&type=tcp&headerType=none#vps-${public_ip}"

  install -d -m 700 "${OUTPUT_DIR}"
  qrcode_file="${OUTPUT_DIR}/vless-${TIMESTAMP}.png"

  qrencode -o "${qrcode_file}" "${vless_url}" || true

  cat > "${OUTPUT_FILE}" <<EOF
[Meta]
generated_at=${TIMESTAMP}
target_user=${TARGET_USER}
timezone=${TIMEZONE}

[Xray]
public_ip=${public_ip}
port=${XRAY_PORT}
uuid=${XRAY_UUID}
reality_server_name=${REALITY_SERVER_NAME}
reality_public_key=${XRAY_PUBLIC_KEY}
reality_short_id=${XRAY_SHORT_ID}
import_url=${vless_url}
qr_png=${qrcode_file}

[MetaTube]
enabled=${INSTALL_METATUBE}
host_port=${METATUBE_HOST_PORT}
EOF

  ln -sfn "${OUTPUT_FILE}" "${LATEST_FILE}"

  echo
  echo "================ 结果输出 ================"
  cat "${OUTPUT_FILE}"
  echo "========================================="
  echo "已保存: ${OUTPUT_FILE}"
  echo "快捷查看: ${LATEST_FILE}"
}

main() {
  parse_args "$@"
  require_root
  validate_inputs
  check_os

  if [[ "${INSTALL_METATUBE}" == "true" ]]; then
    INSTALL_DOCKER="true"
  fi

  install_base_packages
  set_timezone
  ensure_user
  ensure_xdg_dirs
  install_xray
  configure_xray

  if [[ "${INSTALL_DOCKER}" == "true" ]]; then
    install_docker
  fi

  if [[ "${INSTALL_METATUBE}" == "true" ]]; then
    install_metatube
  fi

  if [[ "${ENABLE_WATCHTOWER}" == "true" ]]; then
    if [[ "${INSTALL_DOCKER}" != "true" ]]; then
      err "启用 watchtower 需要 --install-docker true"
      exit 1
    fi
    install_watchtower
  fi

  write_outputs
  log "完成"
}

main "$@"
