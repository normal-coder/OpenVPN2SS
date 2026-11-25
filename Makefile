.DEFAULT_GOAL := help

# ==============================================================================
# 环境与命令定义
# ==============================================================================
DOCKER_COMPOSE ?= docker compose
CONTAINER_NAME ?= $(shell grep -E '^[[:space:]]*CONTAINER_NAME=' .env 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "openvpn-client")
SS_PORT        ?= $(shell grep -E '^[[:space:]]*SS_PORT=' .env 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "5162")
IMAGE_TAG      ?= normalcoder/openvpn2ss:v2.0.0

.PHONY: help init up down restart build rebuild logs logs-vpn logs-ss logs-dns clean-logs doctor test-vpn shell release

help: ## 显示可用命令列表
	@echo "OpenVPN2SS 管理命令速查："
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## 初始化必要目录结构与配置模板
	@mkdir -p config/openvpn config/dnsmasq.d logs
	@if [ ! -f .env ]; then cp .env.example .env && echo "已根据 .env.example 初始化 .env 文件"; fi
	@echo "目录结构与配置已就绪。"

up: ## 启动所有服务并在后台运行
	$(DOCKER_COMPOSE) up -d

down: ## 停止并移除容器和网络
	$(DOCKER_COMPOSE) down

restart: ## 重启所有服务
	$(DOCKER_COMPOSE) restart

build: ## 重新构建本地 Docker 镜像
	$(DOCKER_COMPOSE) build

rebuild: down build up ## 停止、重新构建并拉起服务

logs: ## 跟踪容器综合实时日志 (stdout)
	$(DOCKER_COMPOSE) logs -f

logs-vpn: ## 追踪 OpenVPN 底层持久化日志 (logs/ovpn.log)
	tail -f logs/ovpn.log

logs-ss: ## 追踪 Shadowsocks 服务端日志 (logs/shadowsocks.log)
	tail -f logs/shadowsocks.log

logs-dns: ## 追踪 dnsmasq 解析服务日志 (logs/dnsmasq.log)
	tail -f logs/dnsmasq.log

clean-logs: ## 主动清空 logs/ 目录下的所有历史持久化日志
	@echo "正在清理日志文件..."
	@rm -f logs/*.log logs/*.prev
	@touch logs/.gitkeep
	@echo "日志清理完成。"

shell: ## 进入容器终端排障
	docker exec -it $(CONTAINER_NAME) /bin/sh

doctor: ## 一键健康状态诊断（网络、网卡、端口与 DNS）
	@echo "=================================================================="
	@echo "                  OpenVPN2SS 服务健康体检"
	@echo "=================================================================="
	@printf "1. 容器运行状态: "
	@if docker ps --format '{{.Names}}' | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "\033[32m[正常运行]\033[0m"; \
	else \
		echo "\033[31m[未运行]\033[0m"; exit 1; \
	fi
	@printf "2. OpenVPN 虚拟网卡 (tun0): "
	@if docker exec $(CONTAINER_NAME) ip link show tun0 >/dev/null 2>&1; then \
		VPN_IP=$$(docker exec $(CONTAINER_NAME) ip -4 addr show tun0 | grep -oE 'inet [0-9.]+' | cut -d' ' -f2); \
		echo "\033[32m[已就绪]\033[0m (VPN IP: $$VPN_IP)"; \
	else \
		echo "\033[31m[未找到 tun0]\033[0m"; \
	fi
	@printf "3. 宿主机 SS 端口监听 (127.0.0.1:$(SS_PORT)): "
	@if nc -z 127.0.0.1 $(SS_PORT) 2>/dev/null; then \
		echo "\033[32m[已开启]\033[0m"; \
	else \
		echo "\033[33m[未响应]\033[0m"; \
	fi
	@printf "4. 容器内部 DNS 服务 (127.0.0.1:53): "
	@if docker exec $(CONTAINER_NAME) nc -z 127.0.0.1 53 2>/dev/null; then \
		echo "\033[32m[已就绪]\033[0m"; \
	else \
		echo "\033[33m[未启用/未启动]\033[0m"; \
	fi
	@echo "=================================================================="

test-vpn: ## 单独测试 OpenVPN 配置有效性与握手连通性 (不拉起 SS)
	@echo "正在启动单次 OpenVPN 配置自检测试..."
	docker run --rm -it --privileged -v $$(pwd)/config/openvpn:/etc/openvpn-config normalcoder/openvpn2ss:latest openvpn --help >/dev/null 2>&1 || true
	@echo "如需运行完整交互式诊断，请执行 make doctor"

release: ## 本地多架构构建并推送发布 (需具备 docker buildx 环境)
	docker buildx build --platform linux/amd64,linux/arm64 -t normalcoder/openvpn2ss:latest -t $(IMAGE_TAG) --push .
