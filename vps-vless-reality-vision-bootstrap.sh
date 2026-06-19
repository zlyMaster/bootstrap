#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Xray VLESS + TCP + REALITY + Vision 一键安装脚本
# 适配：Debian / Ubuntu minimal
#
# 默认协议：
#   VLESS + TCP(RAW) + REALITY + XTLS Vision
#
# 可选环境变量：
#   PORT=443
#   SNI=www.microsoft.com
#   TARGET=www.microsoft.com:443
#   SERVER_IP=1.2.3.4
#
# 示例：
#   PORT=443 SNI=www.microsoft.com TARGET=www.microsoft.com:443 bash vps-vless-reality-vision-bootstrap.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行，例如：sudo -i 后再执行脚本"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "当前系统未检测到 apt-get，本脚本仅支持 Debian / Ubuntu"
  exit 1
fi

echo
echo "==== 开启并持久化 BBR ===="
modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr >/etc/modules-load.d/bbr.conf

cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system

echo
echo "==== 检查 BBR 状态 ===="
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.core.default_qdisc

PORT="${PORT:-443}"
SNI="${SNI:-www.microsoft.com}"
TARGET="${TARGET:-${SNI}:443}"
FLOW="xtls-rprx-vision"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
INFO_FILE="/root/xray-reality-vision-info.txt"

echo "============================================================"
echo "安装配置："
echo "  协议：VLESS + TCP + REALITY + Vision"
echo "  端口：${PORT}"
echo "  SNI ：${SNI}"
echo "  目标：${TARGET}"
echo "============================================================"
echo

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
  echo "端口非法：${PORT}"
  exit 1
fi

echo "==== 安装基础依赖 ===="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates openssl unzip tar

echo
echo "==== 安装 / 更新官方 Xray ===="
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

if [ ! -x "${XRAY_BIN}" ]; then
  echo "Xray 安装失败：未找到 ${XRAY_BIN}"
  exit 1
fi

echo
echo "==== 生成 UUID / REALITY 密钥 / ShortID ===="
UUID="$("${XRAY_BIN}" uuid)"
KEYS="$("${XRAY_BIN}" x25519)"

PRIVATE_KEY="$(printf '%s\n' "${KEYS}" | awk -F': *' '
  /PrivateKey/ || /Private key/ {
    print $2
    exit
  }
' | awk '{print $1}')"

PUBLIC_KEY="$(printf '%s\n' "${KEYS}" | awk -F': *' '
  /PublicKey/ || /Public key/ {
    print $2
    exit
  }
' | awk '{print $1}')"

SHORT_ID="$(openssl rand -hex 8)"

if [ -z "${UUID}" ] || [ -z "${PRIVATE_KEY}" ] || [ -z "${PUBLIC_KEY}" ] || [ -z "${SHORT_ID}" ]; then
  echo "参数生成失败"
  echo
  echo "UUID=${UUID}"
  echo "PRIVATE_KEY=${PRIVATE_KEY}"
  echo "PUBLIC_KEY=${PUBLIC_KEY}"
  echo "SHORT_ID=${SHORT_ID}"
  echo
  echo "xray x25519 原始输出："
  echo "${KEYS}"
  exit 1
fi

echo "UUID      = ${UUID}"
echo "PublicKey = ${PUBLIC_KEY}"
echo "ShortID   = ${SHORT_ID}"

echo
echo "==== 获取服务器公网 IP ===="
if [ -z "${SERVER_IP:-}" ]; then
  SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
fi

if [ -z "${SERVER_IP:-}" ]; then
  SERVER_IP="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
fi

if [ -z "${SERVER_IP:-}" ]; then
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

if [ -z "${SERVER_IP:-}" ]; then
  echo "无法自动获取服务器 IP，请手动指定："
  echo "  SERVER_IP=你的服务器IP bash vps-vless-reality-vision-bootstrap.sh"
  exit 1
fi

if [[ "${SERVER_IP}" == *:* ]]; then
  URI_HOST="[${SERVER_IP}]"
else
  URI_HOST="${SERVER_IP}"
fi

echo "Server IP = ${SERVER_IP}"

echo
echo "==== 写入 Xray 服务端配置 ===="
mkdir -p "${XRAY_CONFIG_DIR}"

if [ -f "${XRAY_CONFIG}" ]; then
  BACKUP="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "${XRAY_CONFIG}" "${BACKUP}"
  echo "已备份旧配置：${BACKUP}"
fi

cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision-in",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "${FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${TARGET}",
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
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
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

echo
echo "==== 测试 Xray 配置 ===="
"${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"

echo
echo "==== 启动 Xray 服务 ===="
systemctl daemon-reload || true
systemctl enable xray
systemctl restart xray

if systemctl is-active --quiet xray; then
  echo "Xray 已启动"
else
  echo "Xray 启动失败，请查看日志："
  echo "  journalctl -u xray -xe --no-pager"
  exit 1
fi

echo
echo "==== 尝试放行本机防火墙端口 ===="

if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  echo "已尝试添加 ufw 规则：${PORT}/tcp"
fi

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  echo "已尝试添加 firewalld 规则：${PORT}/tcp"
fi

echo
echo "==== 生成客户端连接信息 ===="

SHARE_LINK="vless://${UUID}@${URI_HOST}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=${FLOW}&spx=%2F#VLESS-REALITY-VISION-${SERVER_IP}"

cat > "${INFO_FILE}" <<EOF
Xray VLESS + TCP + REALITY + Vision

ServerIP=${SERVER_IP}
Port=${PORT}
UUID=${UUID}
Flow=${FLOW}

Reality:
  SNI=${SNI}
  Target=${TARGET}
  PublicKey=${PUBLIC_KEY}
  ShortID=${SHORT_ID}
  Fingerprint=chrome
  SpiderX=/

Share Link:
${SHARE_LINK}

Server Config:
${XRAY_CONFIG}

Commands:
  systemctl status xray --no-pager
  journalctl -u xray -f
  systemctl restart xray
EOF

chmod 600 "${INFO_FILE}"

cat "${INFO_FILE}"

echo
echo "============================================================"
echo "安装完成"
echo
echo "客户端信息文件：${INFO_FILE}"
echo "服务端配置文件：${XRAY_CONFIG}"
echo
echo "注意：如果 VPS 厂商有安全组，请在厂商面板额外放行 TCP ${PORT}"
echo "============================================================"
