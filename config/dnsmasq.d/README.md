# dnsmasq 自定义配置目录

当 `ENABLE_DNSMASQ=true` 时，容器内的 dnsmasq 服务会自动加载此目录下所有以 `.conf` 结尾的配置文件（只读挂载）。

在此目录中放置的 `.conf` 文件已被 `.gitignore` 忽略，避免内网敏感域名与 IP 泄露。

## 配置示例

在当前目录下创建自定义配置文件，例如 `custom.conf`：

```conf
# 1. 泛域名 / 域名解析重定向（该域名及其所有子域名均解析到指定 IP）
address=/internal.example.com/192.0.2.10

# 2. 分流解析（Split-DNS）：将特定内网域名的查询转发给指定的内网 DNS 服务器
server=/corp.example.com/10.8.0.1

# 3. 指定上游公共 DNS 示例（若需要单独指定特定域名的公共解析）
# server=/public.example.com/223.5.5.5
```

## 注意事项

1. **单主机映射**：如果你只需要映射单个主机名，也可以直接在 `docker-compose.yml` 中使用 `extra_hosts`。dnsmasq 默认会自动读取容器内的 `/etc/hosts`。
2. **通配符/子域解析**：`extra_hosts` 仅支持单个主机名精确匹配，若需要泛解析（如 `*.internal.example.com`），请在此目录创建 `.conf` 文件并使用 `address=` 指令。
3. **路由配套**：DNS 仅负责将域名解析为目标 IP。如果解析出的 IP 不在 VPN 服务端默认下发的内网子网路由中，请在客户端的 `.ovpn` 配置文件中添加对应的 `route` 指令（例如 `route 192.0.2.10 255.255.255.255`），否则流量将不会经过 VPN 隧道。
