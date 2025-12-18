#!/bin/bash

# =========================
# Hysteria2 一键安装脚本（完整修复版）
# 作者：LittleDoraemon
# 
# =========================

export LANG=en_US.UTF-8

# --- 自动读取调用命令前设置的环境变量（支持 PORT=xxx bash hy2.sh） ---
load_env_vars() {
    eval "$(env | grep -E '^(PORT|UUID|RANGE_PORTS|NODE_NAME)=' | sed 's/^/export /')"
}
load_env_vars
# ----------------------------------------------------------

# 固定版本号
SINGBOX_VERSION="1.12.13"

# 项目信息常量
AUTHOR="LittleDoraemon"
VERSION="v1.0.2"

# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
blue="\e[1;34m"

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
blue() { echo -e "\e[1;34m$1\033[0m"; }

reading() {
    local prompt="$1"
    local varname="$2"
    echo -ne "$(red "$prompt")"
    read input_value
    printf -v "$varname" "%s" "$input_value"
}

# 基础路径
server_name="sing-box"
work_dir="/etc/sing-box"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"

# 默认值定义
DEFAULT_RANGE_PORTS=""
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)

# 默认节点名称常量
if [[ "${0##*/}" == *"hy2"* || "${0##*/}" == *"hysteria2"* ]]; then
    DEFAULT_NODE_NAME="$AUTHOR-hy2"
else
    DEFAULT_NODE_NAME="$AUTHOR"
fi

# Root 检查
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1

# 通用函数
command_exists() { command -v "$1" >/dev/null 2>&1; }

check_service() {
    local service_name=$1

    # Alpine
    if command_exists apk; then
        if rc-service "${service_name}" status >/dev/null 2>&1; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    fi

    # systemd
    if systemctl list-unit-files | grep -q "^${service_name}"; then
        if systemctl is-active --quiet "${service_name}"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    else
        yellow "not installed"
        return 2
    fi
}

# ----------------------------
# 判断是否进入非交互式模式
# ----------------------------
is_interactive_mode() {
    # 只要 PORT、UUID、RANGE_PORTS、NODE_NAME 任意一个非空
    # 就强制进入全自动安装模式（非交互）
    if [[ -n "$PORT" || -n "$UUID" || -n "$RANGE_PORTS" || -n "$NODE_NAME" ]]; then
        return 1   # 非交互式模式
    else
        return 0   # 交互式模式
    fi
}



# 检查 nginx 状态
check_nginx() {
    if command_exists nginx; then
        check_service "nginx"
        return $?
    else
        yellow "not installed"
        return 2
    fi
}

# 检查 sing-box 状态
check_singbox() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^sing-box.service"; then
        check_service "sing-box.service"
        return $?
    fi
    if command_exists apk && rc-service sing-box status >/dev/null 2>&1; then
        check_service "sing-box"
        return $?
    fi
    yellow "not installed"
    return 2
}

# 软件安装/卸载
manage_packages() {
    if [ $# -lt 2 ]; then
        red "未指定包或操作"
        return 1
    fi

    action=$1
    shift
    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} 已安装"
                continue
            fi
            yellow "正在安装 ${package}..."

            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk update && apk add "$package"
            else
                red "未知系统！"
                return 1
            fi

        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} 未安装"
                continue
            fi

            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "未知系统！"
                return 1
            fi
        fi
    done
    return 0
}

# 获取公网 IP
get_realip() {
    ip=$(curl -4 -sm 2 ip.sb)
    ipv6() { curl -6 -sm 2 ip.sb; }

    if [ -z "$ip" ]; then
        echo "[$(ipv6)]"
    elif curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        echo "[$(ipv6)]"
    else
        resp=$(curl -sm 8 "https://status.eooce.com/api/$ip" | jq -r '.status')
        if [ "$resp" = "Available" ]; then
            echo "$ip"
        else
            v6=$(ipv6)
            [ -n "$v6" ] && echo "[$v6]" || echo "$ip"
        fi
    fi
}

# 开放防火墙端口
allow_port() {
    has_ufw=0; has_firewalld=0; has_iptables=0; has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force allow "$1" >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port="$1" >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && iptables -I INPUT -p "${1#*/}" --dport "${1%/*}" -j ACCEPT 2>/dev/null
    [ "$has_ip6tables" -eq 1 ] && ip6tables -I INPUT -p "${1#*/}" --dport "${1%/*}" -j ACCEPT 2>/dev/null

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1
}

# ----------------- 安装 sing-box（核心部分） -----------------

install_singbox() {
    clear
    purple "正在安装 Sing-box，请稍后..."

    # 架构识别
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   ARCH="amd64" ;;
        aarch64)  ARCH="arm64" ;;
        armv7l)   ARCH="armv7" ;;
        i386|i686) ARCH="i386" ;;
        mips64el) ARCH="mips64le" ;;
        riscv64)  ARCH="riscv64" ;;
        ppc64le)  ARCH="ppc64le" ;;
        s390x)    ARCH="s390x" ;;
        *) red "不支持的架构：$ARCH" && exit 1 ;;
    esac

    FILE="sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${FILE}"

    mkdir -p "$work_dir"

    echo "下载 Sing-box..."
    curl -L -o "$FILE" "$URL"

    echo "解压..."
    tar -xzf "$FILE" || { red "解压失败！"; exit 1; }

    # 找到解压后的目录
    extracted=$(find . -maxdepth 1 -type d -name "sing-box-*")
    extracted=$(echo "$extracted" | head -n 1 | tr -d '\r\n')

    echo "进入目录：$extracted"
    cd "$extracted"

    mv sing-box "${work_dir}/${server_name}"
    chmod +x "${work_dir}/${server_name}"

    cd ..
    rm -rf "$extracted" "$FILE"

    green "Sing-box 安装完成！"

    # ---------------------------
    # 非交互模式参数处理
    # ---------------------------
    is_interactive_mode
    if [ $? -eq 0 ]; then
        not_use_env=0
        echo "当前运行模式：交互式模式"
    else
        not_use_env=1
        echo "当前运行模式：非交互式模式"
    fi

    # 获取主端口
    PORT=$(get_port "$PORT" "$not_use_env")
    echo "获取到的 PORT：$PORT"

    # 获取 UUID
    UUID=$(get_uuid "$UUID" "$not_use_env")
    echo "获取到的 UUID：$UUID"

    # Hysteria2 使用 UUID 作为密码（你要求的行为）
    hy2_password="$UUID"

    # 获取跳跃端口范围
    RANGE_PORTS=$(get_range_ports "$RANGE_PORTS")

    # 订阅端口 = 主端口 + 1
    nginx_port=$((PORT + 1))
    export nginx_port
    echo "订阅端口 nginx_port = $nginx_port"

    # Hysteria2 主端口
    hy2_port=$PORT
    export hy2_port
    echo "hy2_port = $hy2_port"

    # 生成证书（无交互）
    openssl ecparam -genkey -name prime256v1 -out "$work_dir/private.key"
    openssl req -x509 -new -nodes -key "$work_dir/private.key" \
      -sha256 -days 3650 \
      -subj "/C=US/ST=CA/O=bing.com/CN=bing.com" \
      -out "$work_dir/cert.pem"

    allow_port "$hy2_port/udp"

    dns_strategy=$(ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || echo "prefer_ipv6")

    # 生成 config.json
    cat > "$config_dir" <<EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "local",
        "address": "local",
        "strategy": "$dns_strategy"
      }
    ]
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": $hy2_port,
      "users": [
        {
          "password": "$hy2_password"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "final": "direct" }
}
EOF

    green "配置文件已生成：$config_dir"
}

# =========================
# Part 3 / 5 — 服务管理 & 跳跃端口处理
# =========================

# Systemd 服务写入
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
}

# Alpine OpenRC 服务
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
}

# ------------------ 端口跳跃处理 ------------------

# 格式验证 "start-end"
is_valid_range_ports_format() {
    local range="$(echo "$1" | tr -d '\r' | xargs)"
    if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        return 0
    else
        return 1
    fi
}

# 验证范围合法性
is_valid_range_ports() {
    local range="$1"
    is_valid_range_ports_format "$range" || return 1

    local start="${BASH_REMATCH[1]}"
    local end="${BASH_REMATCH[2]}"

    [[ "$start" -ge 1 && "$end" -le 65535 ]] || return 1
    [[ "$start" -le "$end" ]] || return 1

    return 0
}

# 端口合法性
is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]
}

# 端口占用检测
is_port_occupied() {
    local port=$1
    lsof -i :"$port" &>/dev/null
}

# 获取 PORT
get_port() {
    local port="$1"
    local interactive="$2"

    # 如果环境变量已提供
    if [[ -n "$port" ]]; then
        is_valid_port "$port" || exit 1
        is_port_occupied "$port" && exit 1
        echo "$port"
        return
    fi

    # 否则随机生成
    while true; do
        local random_port=$(shuf -i 20000-60000 -n 1)
        is_port_occupied "$random_port" || { echo "$random_port"; return; }
    done
}

# UUID 获取
get_uuid() {
    local uuid="$1"
    local interactive="$2"

    if [[ -z "$uuid" ]]; then
        echo "$DEFAULT_UUID"
    else
        echo "$uuid"
    fi
}

# 跳跃端口范围
get_range_ports() {
    local range="$1"

    [[ -z "$range" ]] && echo "" && return

    is_valid_range_ports "$range" || {
        red "RANGE_PORTS 格式无效，应为 start-end 并且范围合法！"
        exit 1
    }

    echo "$range"
}

# ----------------------
# 跳跃端口核心功能
# ----------------------

configure_port_jump() {
    local min_port=$1
    local max_port=$2

    allow_port "$min_port-$max_port/udp"

    # 提取 listen_port
    local listen_port=$(sed -n '/"listen_port"/s/.*: \([0-9]*\).*/\1/p' "$config_dir")

    # nftables 系统兼容
    if iptables -V 2>/dev/null | grep -q "nf_tables"; then
        iptables -t nat -A PREROUTING -p udp --dport "$min_port":"$max_port" -j DNAT --to-destination :"$listen_port"
        ip6tables -t nat -A PREROUTING -p udp --dport "$min_port":"$max_port" -j DNAT --to-destination :"$listen_port"
    else
        iptables -t nat -A PREROUTING -p udp --dport "$min_port":"$max_port" -j DNAT --to :"$listen_port"
        ip6tables -t nat -A PREROUTING -p udp --dport "$min_port":"$max_port" -j DNAT --to :"$listen_port"
    fi

    restart_singbox

    # 更新订阅链接
    if [[ -f "$client_dir" ]]; then
        local ip=$(get_realip)
        local uuid="$UUID"
        local node_name="$NODE_NAME"

        sed -i "/hysteria2:\/\//d" "$client_dir"
        echo "hysteria2://${uuid}@${ip}:${listen_port}/?insecure=1&alpn=h3&obfs=none&mport=${listen_port},${min_port}-${max_port}#${node_name}" >> "$client_dir"
        base64 -w0 "$client_dir" > "$work_dir/sub.txt"
    fi

    green "跳跃端口已配置：${min_port}-${max_port}"
}

# ----------------------
# 自动处理 RANGE_PORTS
# ----------------------

handle_range_ports() {
    echo "处理 RANGE_PORTS..."

    [[ -z "$RANGE_PORTS" ]] && return

    echo "RANGE_PORTS=$RANGE_PORTS"

    is_valid_range_ports_format "$RANGE_PORTS"
    if [[ $? -eq 0 ]]; then
        local min="${BASH_REMATCH[1]}"
        local max="${BASH_REMATCH[2]}"

        [[ "$max" -gt "$min" ]] || {
            red "RANGE_PORTS 无效：结束端口必须大于起始端口"
            return
        }

        yellow "自动配置端口跳跃：$min-$max"
        configure_port_jump "$min" "$max"
    else
        red "RANGE_PORTS 格式错误，应为 10000-20000"
    fi
}

# =========================
# Part 4 / 5 — 节点信息生成 & Nginx 配置
# =========================

# 生成节点与订阅信息
get_info() {
    yellow "\n正在检测服务器 IP...\n"
    local server_ip
    server_ip=$(get_realip)

    # 节点名称
    if [[ -n "$NODE_NAME" ]]; then
        node_name="$NODE_NAME"
    else
        node_name="$DEFAULT_NODE_NAME"
    fi

    # Hysteria2 URL（含跳跃端口时自动写入）
    if [[ -n "$RANGE_PORTS" ]]; then
        is_valid_range_ports_format "$RANGE_PORTS"
        if [[ $? -eq 0 ]]; then
            local min="${BASH_REMATCH[1]}"
            local max="${BASH_REMATCH[2]}"
            hysteria2_url="hysteria2://${UUID}@${server_ip}:${hy2_port}/?insecure=1&alpn=h3&obfs=none&mport=${hy2_port},${min}-${max}#${node_name}"
        else
            hysteria2_url="hysteria2://${UUID}@${server_ip}:${hy2_port}/?insecure=1&alpn=h3&obfs=none#${node_name}"
        fi
    else
        hysteria2_url="hysteria2://${UUID}@${server_ip}:${hy2_port}/?insecure=1&alpn=h3&obfs=none#${node_name}"
    fi

    echo "$hysteria2_url" > "$client_dir"
    echo ""
    purple "$hysteria2_url"

    base64 -w0 "$client_dir" > "${work_dir}/sub.txt"

    chmod 644 "${work_dir}/sub.txt"

    nginx_link="http://${server_ip}:${nginx_port}/${password}"

    yellow "\n======================== 提示 ========================\n"
    green "V2RayN / Shadowrocket / Clash 等均可导入订阅："
    purple "$nginx_link\n"
}

# ----------------------------
# 生成 Nginx 配置让订阅可用
# ----------------------------

add_nginx_conf() {

    if ! command_exists nginx; then
        red "未安装 nginx，无法提供订阅服务"
        return 1
    fi

    manage_service "nginx" "stop"
    pkill nginx 2>/dev/null

    mkdir -p /etc/nginx/conf.d

    [[ -f "/etc/nginx/conf.d/sing-box.conf" ]] &&
        cp /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak.sb

cat > /etc/nginx/conf.d/sing-box.conf << EOF
server {
    listen $nginx_port;
    listen [::]:$nginx_port;
    server_name _;

    add_header Cache-Control "no-cache, no-store, must-revalidate";
    add_header Pragma "no-cache";
    add_header Expires "0";

    location = /$password {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
    }

    location / {
        return 404;
    }
}
EOF

    # 修复 nginx.conf include
    if [[ -f /etc/nginx/nginx.conf ]]; then
        if ! grep -q "include /etc/nginx/conf.d/" /etc/nginx/nginx.conf; then
            sed -i '/http {/a \    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        fi
    fi

    nginx -t 2>/dev/null
    if [[ $? -eq 0 ]]; then
        systemctl restart nginx 2>/dev/null || nginx -s reload
        green "Nginx 订阅服务已启用"
    else
        yellow "Nginx 配置失败，但不影响节点使用"
    fi
}

# ----------------------------
# 各项服务（封装）
# ----------------------------

manage_service() {
    local svc="$1"
    local action="$2"

    if command_exists systemctl; then
        systemctl "$action" "$svc"
        return $?
    elif command_exists rc-service; then
        rc-service "$svc" "$action"
        return $?
    fi

    return 1
}

start_nginx() { manage_service nginx start; }
restart_nginx() { manage_service nginx restart; }

start_singbox() { manage_service sing-box start; }
restart_singbox() { manage_service sing-box restart; }

# ----------------------------
# 主安装结束后启动服务与订阅
# ----------------------------

start_service_after_finish_sb() {

    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
    else
        red "未知启动系统，不支持！"
        exit 1
    fi

    sleep 4

    handle_range_ports   # 自动跳跃端口
    sleep 2

    get_info             # 生成节点链接
    add_nginx_conf       # 配置订阅
}

# =========================
# Part 5 / 5 — 菜单系统 & 主入口
# =========================

# ----------------------------
# 修改节点配置菜单
# ----------------------------

change_config() {
    clear

    green "=== 修改节点配置 ==="
    skyblue "----------------------------------"
    echo -e "${green}1.${re} 修改端口"
    echo -e "${green}2.${re} 修改 UUID"
    echo -e "${green}3.${re} 修改节点名称"
    echo -e "${green}4.${re} 添加端口跳跃"
    echo -e "${green}5.${re} 删除端口跳跃"
    echo -e "${purple}0.${re} 返回主菜单"
    skyblue "----------------------------------"

    reading "请输入选项: " choice

    case "$choice" in
        1)
            reading "请输入新端口：" new_port
            is_valid_port "$new_port" || { red "端口无效"; return; }
            sed -i "s/\"listen_port\": [0-9]*/\"listen_port\": $new_port/" "$config_dir"
            restart_singbox
            green "端口修改成功：$new_port"
            ;;
        2)
            reading "请输入新 UUID：" new_uuid
            sed -i "s/\"password\": \".*\"/\"password\": \"$new_uuid\"/" "$config_dir"
            restart_singbox
            green "UUID 修改成功！"
            ;;
        3)
            reading "请输入新节点名称：" new_name
            sed -i "s/#.*/#$new_name/" "$client_dir"
            base64 -w0 "$client_dir" > "$work_dir/sub.txt"
            green "节点名称已修改"
            ;;
        4)
            reading "起始端口：" min
            reading "结束端口：" max
            configure_port_jump "$min" "$max"
            ;;
        5)
            iptables -t nat -F PREROUTING 2>/dev/null
            sed -i 's/&mport=[^#]*//' "$client_dir"
            base64 -w0 "$client_dir" > "$work_dir/sub.txt"
            green "跳跃端口已删除"
            ;;
        0)
            return
            ;;
        *)
            red "无效选择"
            ;;
    esac
}

# ----------------------------
# 查看节点信息（显示 URL 和订阅）
# ----------------------------

check_nodes() {
    clear
    purple "================ 节点信息 ================"
    if [[ -f "$client_dir" ]]; then
        while IFS= read -r l; do purple "$l"; done < "$client_dir"
    else
        red "未找到节点信息！"
    fi
    purple "=========================================="
}

# ----------------------------
# 菜单界面
# ----------------------------

menu() {
    clear
    blue "==============================================="
    blue "         Sing-box 一键管理脚本（HY2版）"
    blue "               作者：$AUTHOR"
    yellow "               版本：$VERSION"
    blue "==============================================="
    echo ""

    purple "Nginx 状态: $(check_nginx)"
    purple "Sing-box 状态: $(check_singbox)"
    echo ""

    green "1. 安装 Sing-box (HY2)"
    red   "2. 卸载 Sing-box"
    echo "----------------------------------------"
    green "3. 管理 Sing-box"
    green "4. 查看节点信息"
    echo "----------------------------------------"
    green "5. 修改节点配置"
    green "6. 管理订阅服务"
    echo "----------------------------------------"
    purple "7. SSH 工具箱（老王）"
    echo "----------------------------------------"
    red "0. 退出脚本"
    echo "----------------------------------------"

    reading "请输入选择 (0-7): " choice
}

# ----------------------------
# 管理订阅服务（开关订阅）
# ----------------------------

disable_open_sub() {
    clear
    green "=== 管理订阅服务 ==="
    echo ""
    green "1. 关闭订阅"
    green "2. 开启订阅"
    green "3. 修改订阅端口"
    purple "0. 返回主菜单"

    reading "请输入选择: " s

    case "$s" in
        1)
            systemctl stop nginx 2>/dev/null
            green "订阅服务已关闭"
            ;;
        2)
            systemctl start nginx
            green "订阅服务已开启"
            ;;
        3)
            reading "新订阅端口：" new_sub_port
            is_valid_port "$new_sub_port" || { red "端口无效"; return; }
            sed -i "s/listen [0-9]*/listen $new_sub_port/" /etc/nginx/conf.d/sing-box.conf
            systemctl restart nginx
            green "订阅端口修改成功"
            ;;
        0)
            return
            ;;
        *)
            red "无效选择"
            ;;
    esac
}

# ----------------------------
# Sing-box 服务管理
# ----------------------------

manage_singbox() {
    clear
    green "=== Sing-box 服务管理 ==="
    echo ""
    echo -e "${green}1.${re} 启动 Sing-box"
    echo -e "${green}2.${re} 停止 Sing-box"
    echo -e "${green}3.${re} 重启 Sing-box"
    echo -e "${purple}0.${re} 返回"

    reading "请输入选择：" m

    case "$m" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) return ;;
        *) red "无效选择" ;;
    esac
}

# ----------------------------
# 卸载 Sing-box
# ----------------------------

uninstall_singbox() {
    reading "确定要卸载 Sing-box？(y/n): " u
    [[ "$u" != "y" ]] && { purple "取消卸载"; return; }

    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null

    rm -rf /etc/sing-box
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/nginx/conf.d/sing-box.conf

    green "Sing-box 已卸载"
}

# ----------------------------
# 主循环
# ----------------------------

main_loop() {
    while true; do
        menu
        case "$choice" in
            1)
                install_common_packages
                install_singbox
                start_service_after_finish_sb
                ;;
            2) uninstall_singbox ;;
            3) manage_singbox ;;
            4) check_nodes ;;
            5) change_config ;;
            6) disable_open_sub ;;
            7)
                clear
                bash <(curl -Ls ssh_tool.eooce.com)
                ;;
            0) exit 0 ;;
            *) red "无效选项！" ;;
        esac
        read -n 1 -s -r -p $'\033[1;91m按任意键返回菜单...\033[0m'
    done
}

# ----------------------------
# 主入口 main()
# ----------------------------

main() {
    is_interactive_mode
    if [[ $? -eq 1 ]]; then
        # 非交互模式（自动安装）
        quick_install

        # 自动安装完成后，停在原地等待用户按任意键
        green "\n非交互模式安装已完成！"
        read -n 1 -s -r -p $'\033[1;92m按任意键进入主菜单...\033[0m'

        # 进入主菜单（交互模式）
        main_loop
        return
    fi

    # 若为交互模式，从一开始就进入菜单
    main_loop
}


main
