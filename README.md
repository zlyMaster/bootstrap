# bootstrap

个人 VPS 搭建脚本仓库。

这个仓库用于维护日常主力 VPS、流量节点和协议实验节点的初始化脚本。当前主力脚本已经收敛到一个以**低连接延迟、IP 直连、减少中间层**为目标的 Xray 配置。

> 这些脚本主要面向个人 VPS。执行前建议先阅读脚本内容，并确认 VPS 厂商安全组、DNS 和客户端版本满足要求。

## 当前主力架构

`vps-master-bootstrap.sh` 的代理链路固定为：

```text
客户端
  │
  │ TCP 8443（默认）
  ▼
VLESS Encryption
  │
XTLS Vision
  │
RAW
  │
  ▼
Xray
```

主代理链路**不再使用**：

- REALITY
- TLS
- WebSocket
- XHTTP
- Caddy 反代
- Cloudflare Proxy/CDN

VLESS 的内容保护由 **VLESS Encryption** 提供。脚本通过官方 `xray vlessenc` 生成认证参数，并针对本仓库“性能优先、不追求流量伪装”的使用场景，将 Encryption 的随机 delay padding 收敛为固定最小 padding，避免人为增加首连抖动。

Caddy 仍然保留，但只服务于应用 HTTPS 入口：

```text
TCP 443
  │
Caddy
  ├── metatube.<base-domain>
  └── playwright.service.<base-domain>
```

因此默认端口分工是：

| 端口 | 用途 |
|---:|---|
| `22/tcp` | SSH |
| `443/tcp` | Caddy HTTPS（启用 MetaTube / Playwright 时） |
| `8443/tcp` | Xray VLESS Encryption + RAW + Vision |
| `Playwright 内部端口/tcp` | 保留原脚本行为，启用 Playwright 时同时放行 |

`8443` 只是 Xray 的监听端口，不影响 MetaTube / Playwright 继续通过标准 `https://域名`（443）访问。

## 脚本列表

| 脚本 | 使用场景 | 说明 |
|---|---|---|
| `vps-master-bootstrap.sh` | **主力日常 VPS** | **推荐。** `VLESS Encryption + RAW + Vision + BBR/fq`，代理走 IP 直连；Caddy 仅承载 MetaTube / Playwright HTTPS。 |
| `vps-vmess-tcp-bootstrap.sh` | 对照 / 流量节点 | `VMess + TCP + BBR + fq`，保留作兼容或性能对照。 |
| `vps-vless-reality-vision-bootstrap.sh` | REALITY 对照节点 | `VLESS + TCP + REALITY + Vision`，不再作为主力方案。 |
| `vps-xhttp-bootstrap.sh` | XHTTP 实验节点 | `VLESS + XHTTP + REALITY`，用于协议实验。 |

## 系统要求

支持：

- Debian
- Ubuntu
- root / sudo
- `systemd`
- `apt-get`
- 可访问公网
- VPS 厂商安全组允许所需端口

主力脚本会自动安装或配置：

- Xray（官方安装脚本）
- VLESS Encryption 参数
- BBR + fq（默认）
- UFW
- Docker / Docker Compose（需要 Caddy / Watchtower 时）
- Caddy（启用 MetaTube 或 Playwright 时）
- MetaTube + Postgres（可选）
- Playwright 反代入口（可选）
- Watchtower（可选）

## 新 VPS 换机建议顺序

如果 MetaTube / Playwright 使用域名，建议按下面顺序换机：

1. 创建新 VPS，拿到公网 IP。
2. 在 VPS 厂商安全组中确认允许：
   - `22/tcp`
   - `8443/tcp`
   - `443/tcp`（如果使用 Caddy）
3. 在 Cloudflare DNS 中把相关域名的 **A / AAAA** 更新到新 VPS。
4. Cloudflare 保持 **DNS Only（灰云）**。
5. 确认没有残留指向旧 VPS 的 AAAA 记录。
6. 在新 VPS 上执行主力一键脚本。
7. 导入脚本输出的 VLESS 分享链接 / 二维码到最新版客户端。

Cloudflare 灰云模式下，Cloudflare 只负责 DNS：

```text
域名 → Cloudflare DNS → 新 VPS IP → VPS:443 → Caddy
```

代理本身不走域名：

```text
客户端 → 新 VPS IP:8443 → Xray
```

两条链路互相独立。

## 快速开始

### 主力 VPS

推荐一行命令：

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-master-bootstrap.sh)
```

也可以使用 `wget`：

```bash
apt-get update && apt-get install -y wget ca-certificates && bash <(wget -qO- https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-master-bootstrap.sh)
```

默认 Xray 端口：

```text
8443/tcp
```

如确实需要覆盖：

```bash
XRAY_PORT=9443 bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-master-bootstrap.sh)
```

或者：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-master-bootstrap.sh) --xray-port 9443
```

### 非交互示例

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-master-bootstrap.sh) \
  --username master \
  --base-domain example.com \
  --enable-metatube false \
  --enable-playwright false \
  --enable-watchtower true \
  --tcp-cc bbr
```

只有启用 MetaTube 或 Playwright 时才需要 `--base-domain`。

## Xray 配置说明

主力脚本安装官方 Xray 后，会检查：

```bash
xray help | grep vlessenc
```

只有当前 Core 支持 `vlessenc` 才会继续。

查看版本：

```bash
xray version
```

如果 PATH 中没有：

```bash
/usr/local/bin/xray version
```

检查 systemd 实际使用的二进制：

```bash
systemctl cat xray | grep ExecStart
```

### VLESS Encryption

脚本调用：

```bash
xray vlessenc
```

从官方输出中选择 **X25519 authentication** 对应的 `decryption` / `encryption` 配对。

为了符合本仓库“低延迟优先、不追求额外流量伪装”的目标，脚本保留官方生成的：

- VLESS Encryption 算法
- `native` 模式
- session / 0-RTT 设置
- X25519 认证材料

同时将 padding 收敛为：

```text
100-35-35
```

即固定 35 字节 padding，不再添加随机 delay。

服务端：

```text
settings.decryption = <生成后的 decryption>
flow = xtls-rprx-vision
streamSettings.method = raw
streamSettings.security = none
```

客户端：

```text
settings.encryption = <匹配的 encryption>
flow = xtls-rprx-vision
RAW
security = none
```

VLESS Encryption 启用后，可以在公网链路上使用 `streamSettings.security = none`，因为协议层自身已经保护 VLESS payload。

## 客户端

建议使用支持当前 VLESS Encryption 的新版客户端 / Xray Core。

安装完成后，脚本会生成：

```text
/root/bootstrap-output/latest.txt
```

其中包含：

- VPS IP
- Xray 端口
- VLESS 分享链接
- Xray 版本
- 客户端配置路径

二维码：

```text
/root/bootstrap-output/xray-<timestamp>.png
```

完整 Xray 客户端配置：

```text
/root/bootstrap-output/xray-client-<timestamp>.json
```

客户端模板默认本地监听：

```text
127.0.0.1:10808
```

使用 Xray `socks` inbound；当前 Xray 的该 inbound 同时兼容：

- SOCKS4 / SOCKS4a / SOCKS5
- HTTP Proxy

并启用 SOCKS UDP：

```json
"udp": true
```

因此不需要再为了 HTTP / SOCKS 单独开两个本地端口。

## Caddy / MetaTube / Playwright

新的主代理链路**不经过 Caddy**。

Caddy 只在下面任意功能启用时安装：

- MetaTube
- Playwright HTTPS 反向代理

Caddy 继续监听：

```text
443/tcp
```

MetaTube：

```text
https://metatube.<base-domain>
```

Playwright：

```text
https://playwright.service.<base-domain>
```

调用方不需要显式写 `:443`。

## BBR / TCP

默认：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

可选：

```text
--tcp-cc bbr
--tcp-cc cubic
--tcp-cc reno
```

查看状态：

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.core.default_qdisc
```

## 常用命令

查看 Xray：

```bash
systemctl status xray --no-pager
```

查看日志：

```bash
journalctl -u xray -f
```

重启：

```bash
systemctl restart xray
```

校验配置：

```bash
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

查看监听端口：

```bash
ss -lntp
```

查看最新安装结果：

```bash
cat /root/bootstrap-output/latest.txt
```

## Cloudflare

推荐保持：

```text
DNS Only / 灰云
```

换 VPS 时主要更新 DNS 记录中的新 IP。

重点检查：

- A 记录是否已指向新 IPv4。
- AAAA 是否仍指向旧 VPS。
- 如果使用 CNAME，确认最终 A / AAAA 目标正确。
- Caddy 首次申请 HTTPS 证书前，域名应已经能解析到新 VPS。

Xray 主代理连接直接使用 VPS IP，不依赖 Cloudflare DNS。

## 其他协议脚本

仓库中的 VMess、REALITY、XHTTP 脚本可以继续保留作为测试或兼容用途，但不再作为主力 VPS 的默认选择。

### VMess + TCP

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-vmess-tcp-bootstrap.sh)
```

### VLESS + REALITY + Vision

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-vless-reality-vision-bootstrap.sh)
```

### VLESS + XHTTP + REALITY

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-xhttp-bootstrap.sh)
```

## 流媒体解锁检测

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -L -s check.unlock.media)
```

## 注意事项

脚本会：

- 安装软件包。
- 修改 Xray 配置。
- 配置 BBR / TCP 拥塞控制。
- 配置 UFW。
- 可能安装 Docker / Caddy / MetaTube / Watchtower。
- 在启用相关功能时开放对应端口。

如果 VPS 厂商另有安全组 / 云防火墙，还需要在厂商控制台同步放行端口。

在重要服务器执行前，建议阅读脚本并确认配置。

## License

本项目基于 MIT License 开源，详情见 [LICENSE](./LICENSE)。
