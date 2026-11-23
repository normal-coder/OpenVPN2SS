# dnsmasq 自定义配置目录

当 `ENABLE_DNSMASQ=true` 时，容器内的 dnsmasq 服务会自动加载此目录下所有以 `.conf` 结尾的配置文件（只读挂载）。

在此目录中放置的 `.conf` 文件已被 `.gitignore` 忽略，避免内网敏感域名与 IP 泄露。

## 配置分工说明

1. **内网 DNS（默认自动获取）**：OpenVPN 连接成功后，服务端自动推送的内网 DNS 将作为 dnsmasq 的主上游。
2. **公共 DNS（兜底 Fallback）**：通过环境变量 `DNS_FALLBACK` 配置（默认包括 223.5.5.5, 114.114.114.114），防止内网 DNS 未覆盖公网域名时解析失效。
3. **自定义解析（纯选配）**：仅在特殊私有域名（如测试环境或服务内部未部署 DNS 递归解析器）时，参考 `custom.conf.example` 新建 `.conf` 文件配置。

## 快速上手

复制模板文件：
```bash
cp custom.conf.example custom.conf
```

在 `custom.conf` 中填入你的自定义解析规则即可：
```conf
# 将整个泛域名 *.internal.example.com 指向内网服务 IP
address=/internal.example.com/192.0.2.10

# 将特定域名查询转发给指定的内网 DNS 服务器
server=/corp.example.com/10.0.0.2
```
