#!/bin/bash
set -euo pipefail
trap 'echo -e "\n❌ 脚本已中断，退出中..."; exit 1' INT TERM

USE_COLOR=true

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
    local pkgs=("wget" "curl" "tar" "gzip" "openssl" "jq" "lsof" "sudo")
    echo -e "$(random_color "安装必要依赖中...")"

    case "$OS_TYPE" in
        alpine)
            apk update && apk add --no-cache "${pkgs[@]}"
            ;;
        debian|ubuntu)
            apt update -y && apt install -y "${pkgs[@]}"
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
    local default_domain="dl.google.com"
    
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
# 创建 Hysteria 配置文件
# ===============================
create_hysteria_config() {
    local port="$1"
    local password="$2"
    local domain_name="$3"
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
    url: https://www.bing.com/
    rewriteHost: true

ignoreClientBandwidth: false
EOF
    random_color "✅ Hysteria 2 配置文件已更新: /usr/local/hysteria/config.yaml"
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

    USE_COLOR=false
    create_hysteria_config "$port" "$password" "$domain_name"
    setup_service "$arch"
    USE_COLOR=true

    echo -e "$(random_color "🎉 Hysteria 安装与后台启动完成！")"
    echo "配置文件: /usr/local/hysteria/config.yaml"
    echo "证书路径: /usr/local/hysteria/certs/${domain_name}.crt"
    echo "后台管理：systemctl start/stop hysteria 或 rc-service hysteria start/stop"

    IPV4=$(curl -s -4 ifconfig.me)
    echo ""
    echo "节点 ： hysteria2://${password}@${IPV4}:${port}/?insecure=1&sni=${domain_name}#Hysteria2"
    echo ""
}

main

