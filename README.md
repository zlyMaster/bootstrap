# bootstrap

个人 VPS 搭建脚本仓库。

这个仓库用于存放不同用途的 VPS 初始化 / 搭建脚本，例如日常主力 VPS、流量节点 VPS、Xray 传输协议实验节点等。后续如果有新的 VPS 相关脚本，也可以继续放在这个仓库中统一维护。

> 这些脚本主要面向个人 VPS 环境。执行前建议先阅读脚本内容，确认脚本行为符合预期。

## 脚本列表

| 脚本                                      | 使用场景             | 说明                                                           |
| --------------------------------------- | ---------------- | ------------------------------------------------------------ |
| `vps-bootstrap.sh`                      | 主力日常 VPS         | 综合型 VPS 初始化脚本，适合有域名、使用 Caddy 作为 HTTPS 入口的日常 VPS。             |
| `vps-vless-reality-vision-bootstrap.sh` | 流量 VPS / 无域名 VPS | 安装并配置 `VLESS + TCP + REALITY + Vision`，适合没有域名、追求直连性能的轻量流量节点。 |
| `vps-xhttp-bootstrap.sh`                | XHTTP 实验节点       | 安装并配置 `VLESS + XHTTP + REALITY`，用于特定网络环境或协议测试。               |

## 系统要求

支持系统：

* Debian
* Ubuntu

推荐环境：

* root 权限
* `apt-get`
* `systemd`
* 可访问公网的 IPv4 或 IPv6
* 可以在 VPS 厂商面板中配置防火墙 / 安全组

大部分脚本会自动安装所需依赖。为了兼容 Debian / Ubuntu minimal 系统，下面的一行安装命令会先安装 `curl` 和 `ca-certificates`。

## 快速开始

### 主力 VPS 初始化

适合日常主力 VPS，尤其是有域名，并且希望通过 Caddy 统一管理 HTTPS 入口的服务器。

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-bootstrap.sh)
```

### VLESS + REALITY + Vision 流量节点

适合没有域名、主要作为流量节点使用的 VPS。

默认协议：

```text
VLESS + TCP + REALITY + Vision
```

一行安装命令：

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-vless-reality-vision-bootstrap.sh)
```

如果需要自定义端口、SNI 或 REALITY target，可以使用：

```bash
apt-get update && apt-get install -y curl ca-certificates && PORT=443 SNI=www.microsoft.com TARGET=www.microsoft.com:443 bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-vless-reality-vision-bootstrap.sh)
```

支持的环境变量：

| 变量          |                 默认值 | 说明                      |
| ----------- | ------------------: | ----------------------- |
| `PORT`      |               `443` | Xray 监听端口               |
| `SNI`       | `www.microsoft.com` | REALITY 使用的 server name |
| `TARGET`    |        `${SNI}:443` | REALITY 使用的目标站点         |
| `SERVER_IP` |                自动检测 | 如果自动获取公网 IP 失败，可以手动指定   |

安装完成后，客户端连接信息会写入：

```text
/root/xray-reality-vision-info.txt
```

如果 VPS 厂商有安全组 / 防火墙，需要在厂商面板中额外放行对应的 TCP 端口，默认是 `443/tcp`。

### VLESS + XHTTP + REALITY

适合测试 XHTTP，或者在特定网络环境下验证 XHTTP 传输效果。

```bash
apt-get update && apt-get install -y curl ca-certificates && bash <(curl -fsSL https://raw.githubusercontent.com/zlyMaster/bootstrap/main/vps-xhttp-bootstrap.sh)
```

## 协议选择建议

| 场景         | 推荐协议                             |
| ---------- | -------------------------------- |
| 有域名的主力 VPS | `VLESS + WS + TLS + Caddy`       |
| 无域名的流量 VPS | `VLESS + TCP + REALITY + Vision` |
| XHTTP 测试   | `VLESS + XHTTP + REALITY`        |
| 旧客户端兼容     | `VMess + WS + TLS`               |

一般建议：

* 主力 VPS 使用 `vps-bootstrap.sh`。
* 无域名流量节点使用 `vps-vless-reality-vision-bootstrap.sh`。
* `vps-xhttp-bootstrap.sh` 作为实验脚本或备用脚本保留。
* 不建议在同一个端口上重复运行多个代理脚本，除非已经明确规划好入口和反向代理关系。

## 常用命令

查看 Xray 状态：

```bash
systemctl status xray --no-pager
```

查看 Xray 日志：

```bash
journalctl -u xray -f
```

重启 Xray：

```bash
systemctl restart xray
```

查看监听端口：

```bash
ss -lntp
```

## 后续脚本命名规范

后续新增 VPS 搭建脚本时，建议使用以下命名格式：

```text
vps-<用途>-bootstrap.sh
```

示例：

```text
vps-docker-bootstrap.sh
vps-caddy-bootstrap.sh
vps-monitoring-bootstrap.sh
vps-media-bootstrap.sh
```

建议每个脚本尽量遵循以下规则：

* 启动时检查 root 权限。
* 兼容 Debian / Ubuntu minimal。
* 只安装必要依赖。
* 覆盖已有配置前自动备份。
* 安装完成后输出关键文件路径和常用管理命令。
* 支持通过环境变量进行非交互式配置。
* 在 README 中保留对应的一行安装命令。

## 注意事项

这些脚本可能会修改系统配置、安装软件包、启用系统服务、开放防火墙端口，或者覆盖已有应用配置文件。

在重要服务器上执行脚本前，建议先阅读脚本内容，并确认脚本行为符合预期。

## License

个人 VPS 搭建脚本。
如果后续希望开放给其他人复用，建议补充明确的开源许可证。
