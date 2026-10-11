#!/bin/bash
set -euo pipefail
trap 'echo -e "\n❌ 脚本已中断，退出中..."; exit 1' INT TERM

USE_COLOR=true

# ===============================
# 流量上报（AstraLink 面板）相关路径与常量
# ===============================
HY_DIR="/usr/local/hysteria"
TRAFFIC_CONF="${HY_DIR}/traffic-report.conf"
TRAFFIC_SCRIPT="${HY_DIR}/traffic-report.sh"
TRAFFIC_STATE="${HY_DIR}/traffic-report.state"
TRAFFIC_STATS_PORT="19999"
TRAFFIC_REPORT_SERVICE="hysteria-traffic-report"

# ===============================
# 彩色输出函数
# ===============================
random_color() {
    local colors=("31" "32" "33" "34" "35" "36")
    local color=${colors[$RANDOM % ${#colors[@]}]}
    # 注意这里改成 >&2，这样彩色提示走 stderr，不会污染 stdout
    echo -e "\033[${color}m$1\033[0m" >&2
}

# ===============================
# 检测系统类型
# ===============================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
        VERSION_ID=${VERSION_ID:-unknown}
    else
        OS_TYPE="unknown"
        VERSION_ID="unknown"
    fi
    echo -e "$(random_color "检测到系统：${OS_TYPE} ${VERSION_ID}")"
}

# ===============================
# 安装依赖
# ===============================
install_custom_packages() {
    local pkgs=("wget" "curl" "tar" "gzip" "openssl" "jq" "lsof" "sudo" "cron")
    echo -e "$(random_color "安装必要依赖中...")"

    case "$OS_TYPE" in
        alpine)
            apk update && apk add --no-cache "${pkgs[@]}"
            ;;
        debian|ubuntu)
            # 非交互安装，避免 debconf 交互提示
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            # --no-install-recommends 大幅减少 dpkg 内存占用
            apt-get install -y --no-install-recommends \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                "${pkgs[@]}"
            ;;
        centos|rhel|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${pkgs[@]}"
            else
                yum install -y "${pkgs[@]}"
            fi
            ;;
        *)
            echo "❌ 未识别的系统类型：${OS_TYPE}"
            exit 1
            ;;
    esac
    echo -e "$(random_color "✅ 依赖安装完成")"
}

# ===============================
# 检查架构
# ===============================
check_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        i386|i686) echo "386" ;;
        *) echo "unsupported" ;;
    esac
}

# ===============================
# 下载 Hysteria
# ===============================
download_hysteria() {
    local arch="$1"
    local install_dir="/usr/local/hysteria"
    mkdir -p "$install_dir/certs"
    cd "$install_dir"

    if [ -f "hysteria-linux-${arch}" ]; then
        echo -e "$(random_color '⚠️ Hysteria 二进制已存在，尝试停止旧服务...')"
        pkill -f "hysteria-linux-${arch}" || true
        sleep 1
    fi

    echo -e "$(random_color '开始下载 Hysteria 最新版本...')"
    wget -q --show-progress -O "hysteria-linux-${arch}" "https://download.hysteria.network/app/latest/hysteria-linux-${arch}"
    chmod +x "hysteria-linux-${arch}"
    ln -sf "${install_dir}/hysteria-linux-${arch}" /usr/local/bin/hysteria
}

# ===============================
# 生成自签名证书
# ===============================
generate_certificate() {
    # 将 domain_name 改为局部变量，防止被其他彩色输出污染    
    local default_domain="download.microsoft.com"
    
    read -p "请输入域名 (默认 ${default_domain}): " input_domain < /dev/tty
    local domain_name=${input_domain:-$default_domain}
    local cert_dir="/usr/local/hysteria/certs"
    mkdir -p "$cert_dir"

    if [ ! -f "${cert_dir}/${domain_name}.crt" ] || [ ! -f "${cert_dir}/${domain_name}.key" ]; then
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "${cert_dir}/${domain_name}.key" \
            -out "${cert_dir}/${domain_name}.crt" \
            -subj "/CN=${domain_name}" -days 36500

        chmod 600 "${cert_dir}/${domain_name}."*
        
        random_color "✅ 自签名证书已生成：${domain_name}"
    else
        random_color "ℹ️ 证书已存在，跳过生成"
    fi

    # 关键修复：确保函数的返回值（最后一个echo）是纯净的域名
    echo "$domain_name" 
}

# ===============================
# 配置端口
# ===============================
configure_port() {
    local port
    read -p "请输入 Hysteria 监听端口（默认 30303）: " input < /dev/tty
    port=${input:-30303}
    local pid
    pid=$(lsof -t -iUDP:"$port" || true)
    if [[ -n "$pid" ]]; then
        echo "⚠️ 端口 $port 已被占用，尝试停止旧服务 (PID: $pid)"
        pkill -f "hysteria-linux-$(uname -m)" || kill -9 $pid || true
        sleep 1
    fi
    echo "$port"
}

# ===============================
# 配置密码
# ===============================
configure_password() {
    read -p "请输入 Hysteria 密码（默认 Passw1rd1234）: " input < /dev/tty
    password=${input:-Passw1rd1234}
    echo "$password"
}

# ===============================
# 配置流量上报地址（询问部分的最后一项）
# ===============================
configure_traffic_report() {
    local input
    read -p "请输入流量上报面板地址（例如 astralink.lmx0125.top，留空则不上报）: " input < /dev/tty
    # 去除首尾空白与末尾斜杠
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    TRAFFIC_PANEL="${input%/}"
    echo "$TRAFFIC_PANEL"
}

# ===============================
# 随机密钥
# ===============================
random_secret() {
    local length="${1:-24}"
    openssl rand -hex "$length"
}

# ===============================
# 关闭流量上报（本次填了留空时调用）
# ===============================
clear_traffic_report() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${TRAFFIC_REPORT_SERVICE}.timer" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${TRAFFIC_REPORT_SERVICE}.service"
        rm -f "/etc/systemd/system/${TRAFFIC_REPORT_SERVICE}.timer"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "/etc/cron.d/${TRAFFIC_REPORT_SERVICE}"
    if [ -f /etc/crontabs/root ]; then
        sed -i '\#/hysteria/traffic-report.sh#d' /etc/crontabs/root 2>/dev/null || true
    fi
    rm -f /etc/periodic/5min/traffic-report 2>/dev/null || true
    rm -f "$TRAFFIC_CONF" "$TRAFFIC_SCRIPT" "$TRAFFIC_STATE"
    random_color "ℹ️ 未填写面板地址，已关闭流量上报"
}

# ===============================
# 安装流量上报脚本与定时任务
# ===============================
setup_traffic_report() {
    local panel="$1"
    local stats_secret="$2"
    local scheme="https"
    local host="$panel"
    local node_key
    node_key=$(random_secret 24)

    # 兼容直接粘贴带协议的地址
    case "$host" in
        http://*)  scheme="http";  host="${host#http://}" ;;
        https://*) scheme="https"; host="${host#https://}" ;;
    esac
    host="${host%/}"

    mkdir -p "$HY_DIR"

    cat > "$TRAFFIC_CONF" <<EOF
# AstraLink 流量上报配置（由 install.sh 生成）
# NODE_KEY 需要填写到 AstraLink 后台对应节点的 params.report_key 中
PANEL_SCHEME="${scheme}"
PANEL_HOST="${host}"
NODE_KEY="${node_key}"
STATS_ADDR="127.0.0.1"
STATS_PORT="${TRAFFIC_STATS_PORT}"
STATS_SECRET="${stats_secret}"
STATE="${TRAFFIC_STATE}"
REPORT_PATH="/api/v1/node/report"
EOF
    chmod 600 "$TRAFFIC_CONF"

    cat > "$TRAFFIC_SCRIPT" <<'REPORTER'
#!/bin/bash
# =====================================================================
# AstraLink 节点流量上报（install.sh 生成）
# 读取 Hysteria2 内置 trafficStats，按客户端身份计算增量后上报到面板。
# 上报失败时保留上一次的快照，下次自动补报，不会丢流量。
# =====================================================================
set -uo pipefail

CONF="/usr/local/hysteria/traffic-report.conf"
[ -r "$CONF" ] || exit 0
. "$CONF"

: "${PANEL_SCHEME:=https}"
: "${PANEL_HOST:?未配置 PANEL_HOST}"
: "${NODE_KEY:?未配置 NODE_KEY}"
: "${STATS_SECRET:?未配置 STATS_SECRET}"
: "${STATS_ADDR:=127.0.0.1}"
: "${STATS_PORT:=19999}"
: "${STATE:=/usr/local/hysteria/traffic-report.state}"
: "${REPORT_PATH:=/api/v1/node/report}"

log() { logger -t hysteria-traffic-report "$*" 2>/dev/null || true; }

# 1. 读取 Hysteria2 流量统计（不清零，靠本地快照算增量）
current=$(curl -s -m 10 -H "Authorization: ${STATS_SECRET}" \
    "http://${STATS_ADDR}:${STATS_PORT}/traffic" 2>/dev/null || true)
[ -n "$current" ] || { log "读取 trafficStats 失败"; exit 0; }
printf '%s' "$current" | jq -e . >/dev/null 2>&1 || { log "trafficStats 返回非法 JSON"; exit 0; }

snapshot=$(printf '%s' "$current" | jq -c '
    to_entries
    | map({ key: .key, value: { tx: (.value.tx // 0), rx: (.value.rx // 0) } })
    | from_entries' 2>/dev/null) || snapshot="{}"
[ -n "$snapshot" ] || snapshot="{}"

previous="{}"
[ -s "$STATE" ] && previous=$(cat "$STATE" 2>/dev/null || echo "{}")
printf '%s' "$previous" | jq -e . >/dev/null 2>&1 || previous="{}"

# 2. 计算增量；计数器小于快照说明进程重启过，该身份本次跳过
delta=$(jq -cn --argjson cur "$snapshot" --argjson prev "$previous" '
    ($prev // {}) as $p
    | [ ($cur | to_entries[])
        | .key as $id
        | (.value.tx // 0) as $tx
        | (.value.rx // 0) as $rx
        | ($p[$id].tx // 0) as $ptx
        | ($p[$id].rx // 0) as $prx
        | select($tx >= $ptx and $rx >= $prx)
        | { key: $id, value: { tx: ($tx - $ptx), rx: ($rx - $prx) } } ]
    | map(select(.value.tx > 0 or .value.rx > 0))
    | from_entries
    | { traffic: . }' 2>/dev/null) || delta='{"traffic":{}}'
[ -n "$delta" ] || delta='{"traffic":{}}'

# 3. 没有增量时只刷新快照
if [ "$delta" = '{"traffic":{}}' ]; then
    printf '%s\n' "$snapshot" > "$STATE"
    exit 0
fi

# 4. 上报成功后才落盘快照，失败则下次补报
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST \
    -H "Content-Type: application/json" \
    -H "X-Node-Key: ${NODE_KEY}" \
    -d "$delta" \
    "${PANEL_SCHEME}://${PANEL_HOST}${REPORT_PATH}" 2>/dev/null || echo "000")

case "$code" in
    200|204)
        printf '%s\n' "$snapshot" > "$STATE"
        log "上报成功"
        ;;
    *)
        log "上报失败（HTTP ${code}），保留快照下次补报"
        ;;
esac
REPORTER
    chmod +x "$TRAFFIC_SCRIPT"

    # 定时任务：优先 systemd timer，其次 cron
    if command -v systemctl >/dev/null 2>&1; then
        cat > "/etc/systemd/system/${TRAFFIC_REPORT_SERVICE}.service" <<EOF
[Unit]
Description=AstraLink Hysteria2 Traffic Report
After=network-online.target hysteria.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${TRAFFIC_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
        cat > "/etc/systemd/system/${TRAFFIC_REPORT_SERVICE}.timer" <<EOF
[Unit]
Description=Run AstraLink Hysteria2 traffic report every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload || true
        systemctl enable --now "${TRAFFIC_REPORT_SERVICE}.timer" >/dev/null 2>&1 || true
        random_color "✅ 已创建流量上报定时任务（systemd timer，每 5 分钟）"
    else
        local cron_line=""
        if [ -d /etc/periodic ]; then
            # Alpine：busybox cron 读取 /etc/crontabs/root
            mkdir -p /etc/crontabs /etc/periodic/5min
            local entry="*/5 * * * * ${TRAFFIC_SCRIPT}"
            if [ -f /etc/crontabs/root ]; then
                sed -i '\#/hysteria/traffic-report.sh#d' /etc/crontabs/root 2>/dev/null || true
            fi
            printf '%s\n' "$entry" >> /etc/crontabs/root
            cp "$TRAFFIC_SCRIPT" /etc/periodic/5min/traffic-report
            chmod +x /etc/periodic/5min/traffic-report
            cron_line="$entry"
            rc-service crond start >/dev/null 2>&1 || true
            rc-update add crond default >/dev/null 2>&1 || true
        else
            printf '*/5 * * * * root %s\n' "$TRAFFIC_SCRIPT" > "/etc/cron.d/${TRAFFIC_REPORT_SERVICE}"
            chmod 644 "/etc/cron.d/${TRAFFIC_REPORT_SERVICE}"
            cron_line="*/5 * * * * root ${TRAFFIC_SCRIPT}"
            service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
        fi
        random_color "✅ 已创建流量上报定时任务（cron：${cron_line}）"
    fi

    random_color "✅ 流量上报已开启"
}

# ===============================
# 系统调优（UDP 缓冲）
# ===============================
# Linux 默认 net.core.rmem_max/wmem_max 只有 208KB，而 QUIC 需要 MB 级缓冲：
# quic-go 会请求 8MB，但内核会把它静默截断到 rmem_max。在 100ms 以上 RTT
# 的链路上 BDP 往往是几个 MB，缓冲太小会持续丢包 —— 表现为单条连接还能跑，
# 一旦并发几条流（测速站、多线程下载）吞吐就塌到接近 0。
#
# 这两个值是**上限而不是预留**（空闲时基本不占内存），但小机器上仍要省着给：
# 负载高时那个 UDP socket 真的会涨到接近上限，netdev_max_backlog 也会压住
# 相应数量的 skb。所以按 MemTotal 分档，并只动 max（quic-go 会显式设置每个
# socket 的缓冲，*_default 只影响其它 UDP socket，小机器上不值得放大）。
#
# 档位取自实测：64MB 机器上 hysteria2 常驻约 40MB，给 8MB 上限仍然有余量；
# 128MB 起给满 16MB（100Mbps × 166ms 的 BDP 约 2MB，16MB 只是上限、不会常驻）。
tune_system() {
    local conf="/etc/sysctl.d/99-hysteria.conf"
    local mem_mb buf_max backlog
    mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)

    if [ -z "${mem_mb:-}" ] || [ "$mem_mb" -lt 64 ]; then
        # <64MB 或探测不到：只给 BDP 之上的最小余量
        buf_max=4194304; backlog=4096
    elif [ "$mem_mb" -lt 128 ]; then
        # 64-127MB（实测常驻约 40MB）：8MB 上限足够
        buf_max=8388608; backlog=8192
    else
        # >=128MB：给满 16MB
        buf_max=16777216; backlog=16384
    fi

    echo -e "$(random_color "应用系统调优（内存 ${mem_mb:-未知}MB → UDP 缓冲上限 $((buf_max / 1048576))MB）...")"

    cat > "$conf" <<EOF
# Added by hysteria2-linux-setup.
# UDP socket buffer ceiling, scaled to this machine's RAM. quic-go asks for
# 8MB and the kernel silently caps that at net.core.*mem_max, whose 208KB
# default makes a long-RTT connection drop packets as soon as more than one
# flow runs. These are limits, not reservations: idle cost is zero.
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.core.netdev_max_backlog = ${backlog}
net.core.default_qdisc = fq
EOF

    if command -v sysctl >/dev/null 2>&1; then
        sysctl -w net.core.rmem_max=${buf_max} \
                 net.core.wmem_max=${buf_max} \
                 net.core.netdev_max_backlog=${backlog} >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    fi
    echo -e "$(random_color "✅ UDP 缓冲上限已设为 $((buf_max / 1048576))MB（/etc/sysctl.d/99-hysteria.conf，重启后依然生效）")"
}

# ===============================
# 创建 Hysteria 配置文件
# ===============================
create_hysteria_config() {
    local port="$1"
    local password="$2"
    local domain_name="$3"
    local stats_secret="${4:-}"
    local cert_dir="/usr/local/hysteria/certs"

    mkdir -p /usr/local/hysteria
    
    [ -f /usr/local/hysteria/config.yaml ] && mv /usr/local/hysteria/config.yaml /usr/local/hysteria/config.yaml.bak

    cat > /usr/local/hysteria/config.yaml <<EOF
listen: :${port}

tls:
  cert: ${cert_dir}/${domain_name}.crt
  key: ${cert_dir}/${domain_name}.key

auth:
  type: password
  password: "${password}"

masquerade:
  type: proxy
  proxy:
    url: https://download.microsoft.com/
    rewriteHost: true

# 长 RTT / 高 BDP 链路：上游默认的 standard profile 会明显跑不满，
# aggressive 是官方对高带宽时延积链路的推荐值（跑不动可改回 conservative）。
congestion:
  type: bbr
  bbrProfile: aggressive

# 默认接收窗口偏小，长 RTT 下单条流就会被窗口卡住；以下是上游文档的推荐值。
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

ignoreClientBandwidth: false
EOF
    random_color "✅ Hysteria 2 配置文件已更新: /usr/local/hysteria/config.yaml"

    # 需要流量上报时，追加 Hysteria2 内置流量统计服务（仅监听本机）
    if [ -n "$stats_secret" ]; then
        cat >> /usr/local/hysteria/config.yaml <<EOF

trafficStats:
  listen: 127.0.0.1:${TRAFFIC_STATS_PORT}
  secret: "${stats_secret}"
EOF
        random_color "✅ 已开启流量统计（trafficStats: 127.0.0.1:${TRAFFIC_STATS_PORT}）"
    fi
}

# ===============================
# 创建 systemd / openrc 服务
# ===============================
setup_service() {
    local arch="$1"
    local service_name="hysteria"

    if command -v systemctl >/dev/null 2>&1; then
        echo -e "$(random_color '创建/更新 systemd 服务...')"
        cat > /etc/systemd/system/${service_name}.service <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=/usr/local/hysteria/hysteria-linux-${arch} -c /usr/local/hysteria/config.yaml server
Restart=always
RestartSec=3
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${service_name}
        systemctl restart ${service_name}
        echo -e "$(random_color "✅ Hysteria 服务已启动/重启")"

    elif command -v rc-update >/dev/null 2>&1; then
        echo -e "$(random_color '创建/更新 OpenRC 服务...')"
        cat > /etc/init.d/${service_name} <<EOF
#!/sbin/openrc-run

command="/usr/local/hysteria/hysteria-linux-${arch}"
command_args="-c /usr/local/hysteria/config.yaml server"
pidfile="/run/hysteria.pid"
name="hysteria"

depend() {
    need net
}

supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
respawn_reason="exit signal crash"

EOF
        chmod +x /etc/init.d/${service_name}
        rc-update add ${service_name} default
        rc-service ${service_name} restart
        echo -e "$(random_color "✅ Hysteria 服务已启动/重启")"
    else
        echo "⚠️ 未检测到 systemd 或 OpenRC，请手动运行："
        echo "/usr/local/hysteria/hysteria-linux-${arch} -c /usr/local/hysteria/config.yaml server &"
    fi
}

# ===============================
# 清理功能
# ===============================
cleanup() {
    local service_name="hysteria"
    local install_dir="/usr/local/hysteria"
    
    echo -e "$(random_color '开始清理 Hysteria 相关文件和配置...')"

    # 1. 停止并禁用服务 (Systemd/OpenRC)
    echo -e "$(random_color '1/3. 停止并禁用 Hysteria 服务...')"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop ${service_name} || true
        systemctl disable ${service_name} || true
        rm -f /etc/systemd/system/${service_name}.service
        systemctl daemon-reload
        echo -e "$(random_color '   - Systemd 服务已清理。')"
    elif command -v rc-update >/dev/null 2>&1; then
        rc-service ${service_name} stop || true
        rc-update del ${service_name} default || true
        rm -f /etc/init.d/${service_name}
        echo -e "$(random_color '   - OpenRC 服务已清理。')"
    else
        # 尝试通过进程名称停止（如果服务管理不可用）
        pkill -f "hysteria-linux-" || true
        echo -e "$(random_color '   - 未检测到 Systemd/OpenRC，尝试通过 pkill 停止进程。')"
    fi
    sleep 1 # 等待进程彻底退出

    # 2. 删除 Hysteria 本体和配置文件
    echo -e "$(random_color '2/3. 删除 Hysteria 安装目录和符号链接...')"
    if [ -d "$install_dir" ]; then
        rm -rf "$install_dir"
        echo -e "$(random_color "   - 目录 $install_dir 已删除。")"
    fi
    
    if [ -L "/usr/local/bin/hysteria" ]; then
        rm -f /usr/local/bin/hysteria
        echo -e "$(random_color '   - 符号链接 /usr/local/bin/hysteria 已删除。')"
    fi
    
    # 3. 删除日志和PID文件 (虽然脚本没有创建，但最好覆盖)
    echo -e "$(random_color '3/3. 检查并删除其他残留文件...')"
    rm -f /run/hysteria.pid || true

    pkill -f "hysteria-linux-" || true
    
    echo -e "$(random_color "✅ Hysteria 相关文件和配置已彻底清理！")"
    exit 0
}

# ===============================
# 主程序入口
# ===============================
main() {
    detect_os
    install_custom_packages

    if [[ -d "/usr/local/hysteria" ]]; then
        read -r -p "$(random_color "ℹ️ 检测到 Hysteria 已安装。您是否要卸载 (cleanup)？(y/N/continue): ")" choice < /dev/tty
        
        case "$choice" in
            y|Y)
                detect_os
                cleanup
                ;;
            c|C|continue|CONTINUE)
                echo -e "$(random_color '继续执行安装/更新流程...')"
                ;;
            *)
                echo -e "\n❌ 操作取消，退出中..."
                exit 0
                ;;
        esac
    fi

    arch=$(check_architecture)
    if [ "$arch" = "unsupported" ]; then
        echo "❌ 不支持的架构 $(uname -m)"
        exit 1
    fi

    download_hysteria "$arch"
    domain_name=$(generate_certificate)
    port=$(configure_port)
    password=$(configure_password)
    traffic_panel=$(configure_traffic_report)

    stats_secret=""
    [ -n "$traffic_panel" ] && stats_secret=$(random_secret 24)

    USE_COLOR=false
    create_hysteria_config "$port" "$password" "$domain_name" "$stats_secret"
    tune_system
    setup_service "$arch"

    if [ -n "$traffic_panel" ]; then
        setup_traffic_report "$traffic_panel" "$stats_secret"
    else
        clear_traffic_report
    fi
    USE_COLOR=true

    echo -e "$(random_color "🎉 Hysteria 安装与后台启动完成！")"
    echo "配置文件: /usr/local/hysteria/config.yaml"
    echo "系统调优: /etc/sysctl.d/99-hysteria.conf（UDP 缓冲上限按内存自动分档）"
    echo "证书路径: /usr/local/hysteria/certs/${domain_name}.crt"
    echo "后台管理：systemctl start/stop hysteria 或 rc-service hysteria start/stop"

    IPV4=$(curl -s -4 ifconfig.me)
    echo ""
    echo "节点 ： hysteria2://${password}@${IPV4}:${port}/?insecure=1&sni=${domain_name}#Hysteria2"
    echo ""

    if [ -n "$traffic_panel" ]; then
        node_key=$(grep -m1 '^NODE_KEY=' "$TRAFFIC_CONF" 2>/dev/null | cut -d'"' -f2 || true)
        echo "----------------------------------------"
        echo "流量上报：已开启（面板 ${traffic_panel}）"
        echo "上报脚本：${TRAFFIC_SCRIPT}（每 5 分钟执行一次，失败自动补报）"
        echo "NODE_KEY：${node_key}"
        echo "请把该 NODE_KEY 填到 AstraLink 后台对应节点的 params.report_key 中，"
        echo "面板即可按上报的身份累计每个用户的流量；若面板尚未接入上报接口，"
        echo "节点可先手动执行一次确认联通：bash ${TRAFFIC_SCRIPT}"
        echo "----------------------------------------"
    fi
}

main

