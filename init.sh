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

# 3. 环境变量 (.env) 与编排配置智能交互
if [ -f ".env" ]; then
    echo "    [保留] .env 已存在，保留当前环境变量"
else
    echo "--> 正在生成 .env 环境变量配置文件..."
    DIR_NAME=$(basename "$PWD")
    DEFAULT_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12 || echo "ss_$(date +%s)")
    
    # 检测是否可交互（支持管道 curl ... | bash 模式下的 /dev/tty）
    INTERACTIVE=false
    TTY_DEV=""
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        INTERACTIVE=true
        TTY_DEV="/dev/tty"
    elif [ -t 0 ]; then
        INTERACTIVE=true
    fi

    ask_input() {
        prompt="$1"
        default_val="$2"
        var_name="$3"

        if [ "$INTERACTIVE" = "true" ]; then
            if [ -n "$TTY_DEV" ]; then
                printf "%s [回车默认: %s]: " "$prompt" "$default_val" > "$TTY_DEV"
                read -r user_val < "$TTY_DEV" || user_val=""
            else
                printf "%s [回车默认: %s]: " "$prompt" "$default_val"
                read -r user_val || user_val=""
            fi
            if [ -n "$user_val" ]; then
                eval "$var_name=\"\$user_val\""
            else
                eval "$var_name=\"\$default_val\""
            fi
        else
            eval "$var_name=\"\$default_val\""
        fi
    }

    ask_input "[?] 请输入 Project 分组名称 (OrbStack分组)" "$DIR_NAME" FINAL_PROJECT
    ask_input "[?] 请输入 Service 服务名称" "openvpn" FINAL_SERVICE
    ask_input "[?] 请输入容器名称" "openvpn-${DIR_NAME}" FINAL_CONTAINER
    ask_input "[?] 请输入宿主机映射端口" "5162" FINAL_PORT
    ask_input "[?] 请输入 Shadowsocks 连接密码" "$DEFAULT_PASS" FINAL_PASS

    # 若用户自定义了 Service Name，跨平台安全更新 docker-compose.yml 对应的服务声明
    if [ "$FINAL_SERVICE" != "openvpn" ] && [ -f "docker-compose.yml" ]; then
        sed "s/^[[:space:]]*openvpn:/  ${FINAL_SERVICE}:/" docker-compose.yml > docker-compose.yml.tmp && mv docker-compose.yml.tmp docker-compose.yml
        echo "    [配置] 已将 docker-compose.yml 服务名更新为: ${FINAL_SERVICE}"
    fi

    cat <<EOF > .env
# ==============================================================================
# OpenVPN2SS 环境变量配置 (自动生成)
# ==============================================================================
SS_PASSWORD=${FINAL_PASS}
SS_PORT=${FINAL_PORT}
CONTAINER_NAME=${FINAL_CONTAINER}
COMPOSE_PROJECT_NAME=${FINAL_PROJECT}

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
    echo "    [生成] .env 配置文件已就绪（容器名: ${FINAL_CONTAINER}，端口: ${FINAL_PORT}）"
fi

echo "=================================================================="
echo "          🎉 OpenVPN2SS 初始化完成！仅需最后两步："
echo "=================================================================="
echo " 1. 将你的 OpenVPN 文件 (*.ovpn 及证书) 放入 config/openvpn/ 目录"
echo " 2. 执行启动与体检："
echo "      make up       # 启动服务"
echo "      make doctor   # 一键健康检查"
echo "=================================================================="
