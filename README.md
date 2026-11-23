# OpenVPN2SS

> 在复杂网络环境中，不同目标网络往往会使用 OpenVPN 做接入管制。
>
> OpenVPN 客户端经常会与 Surge、Clash 等本地网络调试代理工具存在 DNS 抢占与全局路由冲突问题。当存在多套独立的 VPN 网络时，还需频繁在不同配置间切换，操作繁琐。

OpenVPN2SS 将 OpenVPN 客户端在独立的 Docker 容器中转化为本地 `ss://` 代理协议。每个容器暴露独立的本地 SS 端口，并由 Clash/Surge 等网络工具做域名分流，可彻底解决 DNS 抢占、多套网络频繁切换及环境冲突问题。

## 目录结构

```bash
.
├── Dockerfile                   # 镜像源文件（集成 OpenVPN 2.7、ssserver 1.24 与 dnsmasq）
├── docker-compose.yml           # Docker Compose 编排文件
├── docker-entrypoint.sh         # 容器自适应嗅探、配置预检与守护脚本
├── Makefile                     # 常用运维与一键诊断命令集合
├── .env.example                 # 环境变量配置模板
├── config                       # 配置文件目录
│   ├── openvpn                  # OpenVPN 配置文件目录（gitignore 保护）
│   ├── shadowsocks.json.example # Shadowsocks 自定义参考模板（可选）
│   └── dnsmasq.d                # dnsmasq 自定义解析目录（选配）
│       ├── custom.conf.example  # 自定义内网域名/泛解析模板
│       └── README.md
├── logs                         # 持久化日志目录（gitignore 保护）
│   ├── ovpn.log                 # OpenVPN 详细握手与网络日志
│   ├── shadowsocks.log          # Shadowsocks 运行日志
│   └── dnsmasq.log              # dnsmasq 解析日志
└── README.md
```

## 快速起步

### 方式一：一键快速初始化 (推荐新手，无需完整 Clone 仓库)

只需在空目录中运行一行安装脚本，即可自动拉取必要配置、创建目录并交互式配置密码端口：

```bash
curl -fsSL https://raw.githubusercontent.com/normal-coder/openvpn2ss/main/init.sh | bash
```

脚本执行完成后，直接进入 [第 2 步：放入 VPN 文件](#2-放入-openvpn-配置文件) 即可。

---

### 方式二：Git 仓库部署

#### 1. 克隆并初始化环境

```bash
git clone https://github.com/normal-coder/openvpn2ss.git
cd openvpn2ss
cp .env.example .env
```

编辑 `.env` 中的 `SS_PASSWORD` 与 `SS_PORT`。

#### 2. 放入 OpenVPN 配置文件

将你的 OpenVPN 连接所需文件直接放入 `config/openvpn/` 目录中。容器启动时会**自动自适应识别**：

* **单文件模式（推荐）**：直接放入你的 `client.ovpn`（内嵌证书与密钥），容器会自动使用，无需拆分！
* **多文件模式**：放入 `*.ovpn` 以及同目录下的证书（`ca.crt`、`user.crt`、`user.key`、`ta.key` 等），容器会自动切换相对路径解析，无需重命名或修改路径。
* **认证凭证**：
  * 可直接在 `.env` 中设置 `VPN_PASSWORD`（免文件更便捷）；
  * 或在目录中放置密码文件（自动匹配 `*pass*.txt` 或 `*pwd*.txt`）。

> **约束提示**：单个容器实例承载一条 VPN 隧道，`config/openvpn/` 目录下请仅保留 1 个生效的 `*.ovpn` 配置文件。

### 2. 环境变量配置

复制环境变量模板：

```bash
cp .env.example .env
```

编辑 `.env` 文件：

```dotenv
# Shadowsocks 连接密码（必填）
SS_PASSWORD=your_secure_password

# 宿主机映射端口（容器内固定监听 5162，外部按需指定）
SS_PORT=5162

# OpenVPN 认证密码（可选，免创建密码文件）
# VPN_PASSWORD=your_vpn_password

# 容器名前缀（默认 openvpn，多实例部署时用于区分）
NAME_PREFIX=openvpn

# 是否启用内置 dnsmasq 解析器（推荐 true）
ENABLE_DNSMASQ=true
```

### 3. 一键启动

使用 Makefile 或原生 Docker Compose 启动：

```bash
# 启动服务
make up

# 一键健康检查与诊断
make doctor
```

---

## 常用管理命令 (Makefile)

项目配套了开箱即用的 Makefile，免去记忆冗长命令：

| 命令 | 说明 |
| :--- | :--- |
| `make up` | 启动所有服务并在后台运行 |
| `make down` | 停止并移除容器和网络 |
| `make restart` | 重启所有服务 |
| `make build` | 本地重新构建 Docker 镜像 |
| `make logs` | 实时跟踪综合控制台日志（stdout） |
| `make logs-vpn` | 实时跟踪 OpenVPN 底层持久化日志（`logs/ovpn.log`） |
| `make logs-ss` | 实时跟踪 Shadowsocks 服务端日志 |
| `make logs-dns` | 实时跟踪 dnsmasq 服务端日志 |
| `make clean-logs`| 清理 `logs/` 目录下的所有历史持久化日志 |
| `make doctor` | 一键进行健康体检（容器状态、tun0 网卡、端口监听与 DNS） |
| `make shell` | 进入运行中的容器内部终端 |

---

## DNS 解析分工与自定义配置

容器内置 dnsmasq 解析服务，分为三级解析链路：

1. **内部 DNS（自动获取）**：OpenVPN 建立连接后，服务端推送的内网 DNS 自动生效。
2. **公共 DNS（兜底保底）**：通过 `DNS_FALLBACK` 配置公共 DNS（默认包含 223.5.5.5, 114.114.114.114），防止目标内部 DNS 未配置公网转发时外网瘫痪。
3. **私有域名解析（选配）**：若部分特殊测试域名在内部 DNS 未做解析，可复制 `config/dnsmasq.d/custom.conf.example` 为 `custom.conf`：
   ```conf
   # 将域名或泛域名直接指向特定内部 IP
   address=/service.internal.example.com/192.0.2.10
   ```

---

## 核心排查与避坑指南

1. **TLS 握手 60 秒超时 (TLS key negotiation failed)**：
   * **端口与防火墙**：确认目标服务器的 UDP/TCP 端口可达。
   * **多端登录互踢**：确认本地没有其他 OpenVPN GUI 客户端正占用同一账号连接。
   * **tls-crypt 与 tls-auth**：现代服务端大多采用 `tls-crypt`，若配置写为 `tls-auth` 且 direction 错误，服务端会由于安全防御特性直接静默丢包（表现为 60s 超时且 0 回包）。请对齐官方下发的原始配置。
   * **代理软件冲突**：若在 Mac 上开启了 Surge / Clash 增强模式，请确认发往 OpenVPN 远端服务器的连接处于 `DIRECT`（直连）策略，避免 UDP 数据包被代理节点吞没。
2. **数据通道断流与超时 (Operation timed out / FRAG_IN error)**：
   * 检查 `.ovpn` 中是否遗留了 `fragment 1300` 或 `mssfix` 指令。官方 GUI 客户端通常会忽略该选项，但在 Linux 下强制执行分片，若服务端未开启分片会导致数据通道彻底断流。
