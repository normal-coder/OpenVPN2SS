#!/bin/sh
set -u

LOG_DIR=/var/log/custom
OVPN_LOG="$LOG_DIR/ovpn.log"
SS_LOG="$LOG_DIR/shadowsocks.log"
DNS_LOG="$LOG_DIR/dnsmasq.log"
STATE_DIR=/run/openvpn2ss
UPSTREAM_DNS_FILE="$STATE_DIR/upstream-dns"
CONFIG_DIR="/etc/openvpn-config"

mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$OVPN_LOG" "$SS_LOG" "$DNS_LOG"
rm -f "$STATE_DIR/ready" "$STATE_DIR/dnsmasq.pid" "$UPSTREAM_DNS_FILE"

cleanup() {
    echo "Shutting down services..."
    [ -n "${SS_PID:-}" ] && kill "$SS_PID" 2>/dev/null
    [ -n "${DNS_PID:-}" ] && kill "$DNS_PID" 2>/dev/null
    [ -n "${OVPN_PID:-}" ] && kill "$OVPN_PID" 2>/dev/null
    [ -n "${LOG_TAIL_PID:-}" ] && kill "$LOG_TAIL_PID" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# Helper: format comma-separated fallback DNS into nameserver lines
append_fallback_dns() {
    if [ -n "${DNS_FALLBACK:-}" ]; then
        printf '%s\n' "$DNS_FALLBACK" | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | grep -v '^$' | sed 's/^/nameserver /'
    fi
}

# Helper: build initial upstream DNS file from DNS_SERVERS and DNS_FALLBACK
write_initial_upstream_dns() {
    {
        if [ -n "${DNS_SERVERS:-}" ]; then
            printf '%s\n' "$DNS_SERVERS" | tr ',' '\n' \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | grep -v '^$' | sed 's/^/nameserver /'
        fi
        append_fallback_dns
    } | awk '!seen[$0]++' > "$UPSTREAM_DNS_FILE"
}

# Helper: parse pushed DNS from OpenVPN log line
handle_pushed_dns() {
    line="$1"
    if [ -z "${DNS_SERVERS:-}" ]; then
        {
            printf '%s\n' "$line" | tr ',' '\n' \
                | sed -e 's/^[[:space:]]*//' -e "s/'$//" \
                | sed -n -e 's/^dhcp-option DNS //p' -e 's/^dhcp-option DNS6 //p' \
                | sed 's/^/nameserver /'
            append_fallback_dns
        } | awk '!seen[$0]++' > "$STATE_DIR/upstream-dns.tmp"

        if [ -s "$STATE_DIR/upstream-dns.tmp" ]; then
            mv "$STATE_DIR/upstream-dns.tmp" "$UPSTREAM_DNS_FILE"
            echo "Updated upstream DNS servers from OpenVPN push"
            if [ -f "$STATE_DIR/dnsmasq.pid" ]; then
                DNS_PID_RUNNING="$(cat "$STATE_DIR/dnsmasq.pid" 2>/dev/null || true)"
                if [ -n "$DNS_PID_RUNNING" ]; then
                    kill -HUP "$DNS_PID_RUNNING" 2>/dev/null || true
                fi
            fi
        else
            rm -f "$STATE_DIR/upstream-dns.tmp"
        fi
    fi
}

# ==============================================================================
# 1. 配置文件自动嗅探 (Auto-Discovery)
# ==============================================================================
OVPN_LIST=$(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.ovpn" 2>/dev/null)
OVPN_COUNT=$(printf '%s\n' "$OVPN_LIST" | grep -v '^$' | wc -l | tr -d ' ')

if [ "$OVPN_COUNT" -eq 0 ]; then
    echo "ERROR: 未在 $CONFIG_DIR 目录下找到任何 .ovpn 配置文件！" >&2
    echo "请将你的 OpenVPN 配置文件放入 config/openvpn/ 目录中。" >&2
    exit 1
elif [ "$OVPN_COUNT" -gt 1 ]; then
    echo "ERROR: 检测到多个 .ovpn 配置文件：" >&2
    printf '%s\n' "$OVPN_LIST" >&2
    echo "单容器实例仅支持一条 VPN 链路，请仅保留一个生效的 .ovpn 文件。" >&2
    exit 1
fi

TARGET_OVPN=$(printf '%s\n' "$OVPN_LIST" | head -n 1)
OVPN_FILENAME=$(basename "$TARGET_OVPN")
echo "Using OpenVPN config: $OVPN_FILENAME"

# 切换工作目录至配置文件所在目录，完美支持相对路径（ca.crt, ta.key 等）
cd "$CONFIG_DIR"

# ==============================================================================
# 2. 启动前静态配置自检 (Pre-flight Sanitizer)
# ==============================================================================
if grep -E -q '^[[:space:]]*(fragment|mssfix)' "$TARGET_OVPN"; then
    echo "===================================================================="
    echo "WARNING: 检测到配置文件中包含 'fragment' 或 'mssfix' 指令！"
    echo "若 OpenVPN 服务端未启用分片支持，会导致 FRAG_IN 报错并造成数据通道断流。"
    echo "若出现连接超时 (Operation timed out)，请从 .ovpn 中移除或注释这几行。"
    echo "===================================================================="
fi

if grep -E -q '^[[:space:]]*tls-auth' "$TARGET_OVPN"; then
    echo "INFO: 检测到使用了 tls-auth。若握手超时且无回包，请确认服务端是否需要 tls-crypt。"
fi

# ==============================================================================
# 3. 凭证解析与准备 (环境变量 + 文件双通道支持)
# ==============================================================================
OVPN_AUTH_ARGS=""
CONFIG_HAS_AUTH_USER_PASS=false
if grep -E -q '^[[:space:]]*auth-user-pass' "$TARGET_OVPN"; then
    CONFIG_HAS_AUTH_USER_PASS=true
fi

if [ -n "${VPN_PASSWORD:-}" ]; then
    # 优先使用环境变量注入凭据
    if [ -n "${VPN_USERNAME:-}" ]; then
        printf '%s\n%s\n' "$VPN_USERNAME" "$VPN_PASSWORD" > "$STATE_DIR/auth.creds"
        chmod 600 "$STATE_DIR/auth.creds"
        OVPN_AUTH_ARGS="--auth-user-pass $STATE_DIR/auth.creds"
        echo "Configured OpenVPN username & password from environment variables"
    else
        printf '%s\n' "$VPN_PASSWORD" > "$STATE_DIR/auth.creds"
        chmod 600 "$STATE_DIR/auth.creds"
        if [ "$CONFIG_HAS_AUTH_USER_PASS" = "true" ]; then
            OVPN_AUTH_ARGS="--auth-user-pass $STATE_DIR/auth.creds"
        else
            OVPN_AUTH_ARGS="--askpass $STATE_DIR/auth.creds"
        fi
        echo "Configured OpenVPN password from environment variable"
    fi
else
    # 自动探测密码文件
    PASS_FILES=$(find "$CONFIG_DIR" -maxdepth 1 -type f \( -iname "*pass*.txt" -o -iname "*pwd*.txt" \) 2>/dev/null)
    PASS_COUNT=$(printf '%s\n' "$PASS_FILES" | grep -v '^$' | wc -l | tr -d ' ')

    if [ "$PASS_COUNT" -eq 1 ]; then
        FOUND_PASS_FILE=$(printf '%s\n' "$PASS_FILES" | head -n 1)
        if [ "$CONFIG_HAS_AUTH_USER_PASS" = "true" ]; then
            OVPN_AUTH_ARGS="--auth-user-pass $FOUND_PASS_FILE"
        else
            OVPN_AUTH_ARGS="--askpass $FOUND_PASS_FILE"
        fi
        echo "Found and using password file: $(basename "$FOUND_PASS_FILE")"
    elif [ "$PASS_COUNT" -gt 1 ]; then
        echo "WARNING: 检测到多个密码文件，跳过自动加载。请使用单一命名或指定环境变量。"
    fi
fi

write_initial_upstream_dns

# 记录本次启动分隔符到持久化日志
echo "=== OpenVPN session started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" >> "$OVPN_LOG"
echo "=== Shadowsocks session started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" >> "$SS_LOG"
echo "=== dnsmasq session started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ===" >> "$DNS_LOG"

echo "Starting OpenVPN log monitor..."
tail -F -n 0 "$OVPN_LOG" 2>/dev/null | while read -r line; do
    case "$line" in
        *"Initialization Sequence Completed"*)
            touch "$STATE_DIR/ready"
            ;;
        *"PUSH_REPLY"*"dhcp-option DNS"*)
            handle_pushed_dns "$line"
            ;;
        *"TLS Error"*|*"AUTH_FAILED"*|*"FRAG_IN error"*)
            # 将核心异常日志同步输出到容器标准输出，方便统一查看
            echo "[openvpn] $line"
            ;;
    esac
done &
LOG_TAIL_PID=$!

sleep 1

echo "Starting OpenVPN ($OVPN_FILENAME)..."
openvpn --config "$TARGET_OVPN" $OVPN_AUTH_ARGS >>"$OVPN_LOG" 2>&1 &
OVPN_PID=$!

TIMEOUT="${VPN_READY_TIMEOUT:-60}"
ELAPSED=0
echo "Waiting for VPN tunnel readiness (timeout: ${TIMEOUT}s)..."

# 诊断建议生成器
print_diagnostics() {
    echo "============================= [故障智能诊断] =============================" >&2
    if grep -q "TLS Error: TLS key negotiation failed" "$OVPN_LOG" 2>/dev/null; then
        echo "诊断发现: TLS 握手 60s 超时（服务端无应答）。" >&2
        echo "排查建议:" >&2
        echo "  1. 确认目标服务器的 UDP/TCP 端口可达（检查防火墙/云安全组）；" >&2
        echo "  2. 确认本机没有其他 OpenVPN 客户端正在连接此账号（服务端常限制单点登录）；" >&2
        echo "  3. 确认是否应使用 'tls-crypt' 替代 'tls-auth'，或检查 key-direction 参数；" >&2
        echo "  4. 若使用 Surge / Clash，确认目标 IP 是否为直连 (DIRECT) 且未被拦截 UDP。" >&2
    elif grep -q "FRAG_IN error" "$OVPN_LOG" 2>/dev/null; then
        echo "诊断发现: 发生分片协议错误 (FRAG_IN error)。" >&2
        echo "排查建议: 服务端未启用分片支持，请从 .ovpn 配置文件中删除 'fragment' 和 'mssfix' 指令！" >&2
    elif grep -q "AUTH_FAILED" "$OVPN_LOG" 2>/dev/null; then
        echo "诊断发现: 身份认证失败 (AUTH_FAILED)。" >&2
        echo "排查建议: 请检查你的用户名或密码是否正确配置。" >&2
    fi
    echo "==========================================================================" >&2
    echo "=== Recent OpenVPN log ===" >&2
    tail -n 20 "$OVPN_LOG" >&2
}

while [ ! -f "$STATE_DIR/ready" ]; do
    if ! kill -0 "$OVPN_PID" 2>/dev/null; then
        echo "ERROR: OpenVPN process exited unexpectedly during startup!" >&2
        print_diagnostics
        exit 1
    fi
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "ERROR: VPN tunnel not established within ${TIMEOUT}s" >&2
        print_diagnostics
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
echo "VPN tunnel established and routes ready (${ELAPSED}s)"

# ==============================================================================
# 4. DNS 服务启动与接管 (dnsmasq)
# ==============================================================================
ENABLE_DNSMASQ="${ENABLE_DNSMASQ:-false}"
DNS_PID=""

if [ "$ENABLE_DNSMASQ" = "true" ]; then
    echo "Starting dnsmasq service..."
    if [ ! -s "$UPSTREAM_DNS_FILE" ]; then
        echo "WARNING: No upstream DNS configured or pushed yet. dnsmasq will rely on /etc/hosts and custom config files."
        touch "$UPSTREAM_DNS_FILE"
    fi

    dnsmasq --keep-in-foreground \
        --conf-file=/dev/null \
        --conf-dir=/etc/dnsmasq.d,*.conf \
        --resolv-file="$UPSTREAM_DNS_FILE" \
        --listen-address=127.0.0.1 --port=53 \
        --log-facility=- 2>&1 | tee -a "$DNS_LOG" &
    DNS_PID=$!
    echo "$DNS_PID" > "$STATE_DIR/dnsmasq.pid"

    DNS_WAIT=0
    while ! nc -z 127.0.0.1 53 2>/dev/null; do
        if [ "$DNS_WAIT" -ge 10 ]; then
            echo "ERROR: dnsmasq failed to start on 127.0.0.1:53" >&2
            exit 1
        fi
        sleep 0.5
        DNS_WAIT=$((DNS_WAIT + 1))
    done
    echo "dnsmasq started successfully on 127.0.0.1:53"

    # Direct container resolver to local dnsmasq
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# ==============================================================================
# 5. Shadowsocks 服务端启动
# ==============================================================================
FINAL_CONFIG="$STATE_DIR/shadowsocks.json"
BASE_CONFIG="/etc/shadowsocks.json"

if [ ! -f "$BASE_CONFIG" ]; then
    # 若镜像未内置或未挂载，动态生成默认配置 (固定监听 5162，外部映射端口由宿主 Compose 决定)
    cat <<EOF > "$BASE_CONFIG"
{
    "server": "0.0.0.0",
    "server_port": 5162,
    "local_address": "127.0.0.1",
    "local_port": 5162,
    "password": "__SS_PASSWORD__",
    "timeout": 300,
    "method": "aes-256-gcm"
}
EOF
fi

cp "$BASE_CONFIG" "$FINAL_CONFIG"

# 动态密码注入
if [ -n "${SS_PASSWORD:-}" ]; then
    awk -v p="$SS_PASSWORD" '{gsub(/__SS_PASSWORD__/, p); print}' "$BASE_CONFIG" > "$FINAL_CONFIG"
fi

# 动态加密方式覆盖 (可选)
if [ -n "${SS_METHOD:-}" ]; then
    sed -i "s/\"method\": *\"[^\"]*\"/\"method\": \"$SS_METHOD\"/g" "$FINAL_CONFIG"
fi

if grep -q '__SS_PASSWORD__' "$FINAL_CONFIG" 2>/dev/null; then
    echo "ERROR: SS_PASSWORD environment variable is not set and /etc/shadowsocks.json contains '__SS_PASSWORD__'" >&2
    exit 1
fi

set -- ssserver -c "$FINAL_CONFIG"

echo "Starting Shadowsocks server..."
"$@" 2>&1 | tee -a "$SS_LOG" &
SS_PID=$!

# ==============================================================================
# 6. 服务保活与守护循环
# ==============================================================================
while true; do
    if ! kill -0 "$SS_PID" 2>/dev/null; then
        echo "ERROR: ssserver exited" >&2
        exit 1
    fi
    if ! kill -0 "$OVPN_PID" 2>/dev/null; then
        echo "ERROR: openvpn exited" >&2
        kill "$SS_PID" 2>/dev/null
        [ -n "$DNS_PID" ] && kill "$DNS_PID" 2>/dev/null
        exit 1
    fi
    if [ -n "$DNS_PID" ] && ! kill -0 "$DNS_PID" 2>/dev/null; then
        echo "ERROR: dnsmasq exited" >&2
        kill "$SS_PID" 2>/dev/null
        kill "$OVPN_PID" 2>/dev/null
        exit 1
    fi
    sleep 5
done
