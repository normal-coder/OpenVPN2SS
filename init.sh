#!/bin/sh
set -eu

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/normal-coder/openvpn2ss/main}"

echo "=================================================================="
echo "          OpenVPN2SS 极速初始化安装脚本 (v2.0)"
echo "=================================================================="

# 1. 确保必要的目录结构
echo "--> 正在初始化目录结构..."
mkdir -p config/openvpn config/dnsmasq.d logs

# 2. 下载核心编排与管理文件 (安全机制：已存在则跳过，绝不覆盖用户修改)
download_if_missing() {
    file="$1"
    url="$2"
    if [ -f "$file" ]; then
        echo "    [保留] $file 已存在，跳过下载"
    else
        echo "    [下载] 正在获取 $file ..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$url" -o "$file"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$file" "$url"
        else
            echo "ERROR: 系统未安装 curl 或 wget，无法下载文件！" >&2
            exit 1
        fi
    fi
}

download_if_missing "docker-compose.yml" "$REPO_RAW/docker-compose.yml"
download_if_missing "Makefile" "$REPO_RAW/Makefile"
download_if_missing "config/dnsmasq.d/custom.conf.example" "$REPO_RAW/config/dnsmasq.d/custom.conf.example"
download_if_missing "config/shadowsocks.json.example" "$REPO_RAW/config/shadowsocks.json.example"

# 3. 环境变量 (.env) 智能配置
if [ -f ".env" ]; then
    echo "    [保留] .env 已存在，保留当前环境变量"
else
    echo "--> 正在生成 .env 环境变量配置文件..."
    DEFAULT_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12 || echo "ss_$(date +%s)")
    
    # 检测是否为交互式终端环境
    if [ -t 0 ]; then
        printf "请输入 Shadowsocks 连接密码 [回车默认随机密码: %s]: " "$DEFAULT_PASS"
        read -r USER_PASS || USER_PASS=""
        [ -n "$USER_PASS" ] && FINAL_PASS="$USER_PASS" || FINAL_PASS="$DEFAULT_PASS"

        printf "请输入宿主机映射端口 [回车默认 5162]: "
        read -r USER_PORT || USER_PORT=""
        [ -n "$USER_PORT" ] && FINAL_PORT="$USER_PORT" || FINAL_PORT="5162"

        printf "请输入容器名前缀 [回车默认 openvpn]: "
        read -r USER_PREFIX || USER_PREFIX=""
        [ -n "$USER_PREFIX" ] && FINAL_PREFIX="$USER_PREFIX" || FINAL_PREFIX="openvpn"
    else
        FINAL_PASS="$DEFAULT_PASS"
        FINAL_PORT="5162"
        FINAL_PREFIX="openvpn"
    fi

    cat <<EOF > .env
# ==============================================================================
# OpenVPN2SS 环境变量配置 (自动生成)
# ==============================================================================
SS_PASSWORD=${FINAL_PASS}
SS_PORT=${FINAL_PORT}
NAME_PREFIX=${FINAL_PREFIX}

# --- 目录路径自定义 (可选，留空使用当前工程目录) ---
# OVPN_CONFIG_DIR=./config/openvpn
# DNS_CONFIG_DIR=./config/dnsmasq.d
# LOG_DIR=./logs

# --- OpenVPN 凭证 (可选，免创建密码文件直接在此填写) ---
# VPN_PASSWORD=
# VPN_USERNAME=

# --- 高级网络选项 (选配) ---
SS_METHOD=aes-256-gcm
VPN_READY_TIMEOUT=60
ENABLE_DNSMASQ=true
EOF
    echo "    [生成] .env 配置文件已就绪（密码: ${FINAL_PASS}，端口: ${FINAL_PORT}）"
fi

echo "=================================================================="
echo "          🎉 OpenVPN2SS 初始化完成！仅需最后两步："
echo "=================================================================="
echo " 1. 将你的 OpenVPN 文件 (*.ovpn 及证书) 放入 config/openvpn/ 目录"
echo " 2. 执行启动与体检："
echo "      make up       # 启动服务"
echo "      make doctor   # 一键健康检查"
echo "=================================================================="
