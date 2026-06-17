cat > /root/install-xray-xhttp-reality.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo -i"
  exit 1
fi

PORT="${PORT:-443}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
SNI="${SNI:-dash.cloudflare.com}"
TARGET="${TARGET:-dash.cloudflare.com:443}"

echo "==== 安装依赖 ===="
apt-get update
apt-get install -y curl wget socat openssl ca-certificates gnupg lsb-release unzip tar

echo "==== 安装官方 Xray ===="
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "==== 生成 UUID / REALITY 密钥 / ShortID ===="
UUID="$(/usr/local/bin/xray uuid)"
KEYS="$(/usr/local/bin/xray x25519)"

PRIVATE="$(printf '%s\n' "$KEYS" | awk -F': *' '
/^Private key[[:space:]]*:/ || /^PrivateKey[[:space:]]*:/ {
  print $2;
  exit
}')"

PUBLIC="$(printf '%s\n' "$KEYS" | awk -F': *' '
/^Public key[[:space:]]*:/ || /^PublicKey[[:space:]]*:/ || /^Password/ {
  print $2;
  exit
}' | awk '{print $1}')"

SHORTID="$(openssl rand -hex 8)"
SERVER_IP="$(curl -4 -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

if [ -z "$UUID" ] || [ -z "$PRIVATE" ] || [ -z "$PUBLIC" ] || [ -z "$SHORTID" ] || [ -z "$SERVER_IP" ]; then
  echo "参数生成失败："
  echo "UUID=$UUID"
  echo "PRIVATE=$PRIVATE"
  echo "PUBLIC=$PUBLIC"
  echo "SHORTID=$SHORTID"
  echo "SERVER_IP=$SERVER_IP"
  echo
  echo "xray x25519 原始输出："
  echo "$KEYS"
  exit 1
fi

echo "==== 写入 Xray 服务端配置 ===="
mkdir -p /usr/local/etc/xray
cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.$(date +%F-%H%M%S) 2>/dev/null || true

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-xhttp-reality",
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "auto"
        },
        "realitySettings": {
          "show": false,
          "target": "$TARGET",
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE",
          "shortIds": [
            "$SHORTID"
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

echo "==== 测试配置 ===="
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json

echo "==== 启动 Xray ===="
systemctl restart xray
systemctl enable xray

echo "==== 放行防火墙端口 ===="
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${PORT}/tcp 2>/dev/null || true
fi

echo "==== 输出客户端信息 ===="
cat > /root/xhttp-reality-info.txt <<EOF
UUID=$UUID
PublicKey=$PUBLIC
ShortId=$SHORTID
ServerIP=$SERVER_IP
Port=$PORT
Path=$XHTTP_PATH
SNI=$SNI

Share Link:
vless://$UUID@$SERVER_IP:$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORTID&type=xhttp&path=%2Fxhttp&mode=auto#XHTTP-REALITY-$SERVER_IP
EOF

cat /root/xhttp-reality-info.txt

echo
echo "==== 安装完成 ===="
echo "配置文件：/usr/local/etc/xray/config.json"
echo "客户端信息：/root/xhttp-reality-info.txt"
echo "查看状态：systemctl status xray --no-pager"
echo "查看日志：journalctl -u xray -f"
echo "查看端口：ss -lntp | grep $PORT"
SCRIPT

bash /root/install-xray-xhttp-reality.sh

cat /root/xhttp-reality-info.txt
