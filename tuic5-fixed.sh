#!/bin/bash
export LANG=en_US.UTF-8

# ======================================================================
# Sing-box TUIC5 一键脚本（共存增强版）
# 作者：littleDoraemon
#
# 特性：
# - TUIC5 协议（uuid = password）
# - NAT 跳跃端口（仅服务器侧实现、范围显示在节点名称 tag）
# - 节点名称继承 hy2 逻辑（国家代码 + ISP）
# - 与 HY2 完全共存（目录、服务、订阅、URL 完全独立）
# - 自动模式 + 交互模式
# - 完整菜单体系（与 hy2 一致）
# - 订阅系统：sub.txt / sub.json / base64 / Nginx
# ======================================================================


# ======================================================================
# 自动模式环境变量（可传入：PORT UUID RANGE_PORTS NODE_NAME）
# ======================================================================
load_env_vars() {
    while IFS='=' read -r key value; do
        case "$key" in
            PORT|UUID|RANGE_PORTS|NODE_NAME)
                if [[ -n "$value" && "$value" =~ ^[a-zA-Z0-9\.\-\:_/]+$ ]]; then
                    export "$key=$value"
                fi
                ;;
        esac
    done < <(env | grep -E '^(PORT|UUID|RANGE_PORTS|NODE_NAME)=')
}
load_env_vars


# ======================================================================
# 自动/手动模式判断
# ======================================================================
is_interactive_mode() {
    if [[ -n "$PORT" || -n "$UUID" || -n "$RANGE_PORTS" || -n "$NODE_NAME" ]]; then
        return 1  # 自动模式
    else
        return 0  # 手动模式
    fi
}


# ======================================================================
# 全局路径（TUIC5 独立实例，避免与 HY2 冲突）
# ======================================================================
SINGBOX_VERSION="1.12.13"
AUTHOR="littleDoraemon"
VERSION="v1.0-tuic5"

# TUIC5 使用独立目录
work_dir="/etc/sing-box-tuic5"

# 核心文件路径
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"

# 订阅文件
sub_file="${work_dir}/sub.txt"
sub_port_file="${work_dir}/sub.port"

DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid)
DEFAULT_NODE_SUFFIX="tuic5"


# ======================================================================
# UI 颜色 + 渐变文本（复刻 hy2）
# ======================================================================
re="\033[0m"
white()  { echo -e "\033[1;37m$1\033[0m"; }
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
blue()   { echo -e "\e[1;34m$1\033[0m"; }

gradient() {
    local text="$1"
    local colors=(196 202 208 214 220 190 82 46 51 39 33 99 129 163)
    local i=0
    for ((n=0; n<${#text}; n++)); do
        printf "\033[38;5;${colors[i]}m%s\033[0m" "${text:n:1}"
        i=$(((i+1) % ${#colors[@]}))
    done
    echo
}

red_input() { printf "\e[1;91m%s\033[0m" "$1"; }
err()       { red "[错误] $1" >&2; }


# ======================================================================
# Root 权限检查
# ======================================================================
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行脚本"
    exit 1
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }


# ======================================================================
# 安装基础依赖
# ======================================================================
install_common_packages() {

    local pkgs="tar jq openssl lsof curl coreutils qrencode nginx"
    local need_update=1

    for p in $pkgs; do
        if ! command_exists "$p"; then

            if [[ $need_update -eq 1 ]]; then
                if command_exists apt; then apt update -y
                elif command_exists yum; then yum makecache -y
                elif command_exists dnf; then ddnf makecache -y
                elif command_exists apk; then apk update
                fi
                need_update=0
            fi

            yellow "安装依赖：$p"
            if command_exists apt; then apt install -y "$p"
            elif command_exists yum; then yum install -y "$p"
            elif command_exists dnf; then dnf install -y "$p"
            elif command_exists apk; then apk add "$p"
            fi
        fi
    done
}


# ======================================================================
# URL 编码 / 解码
# ======================================================================
urlencode() { printf "%s" "$1" | jq -sRr @uri; }
urldecode() { printf '%b' "${1//%/\\x}"; }

# ======================================================================
# ======================== 端口工具函数 ================================
# ======================================================================

# 端口是否合法
is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

# 判断端口是否占用
is_port_occupied() {
    ss -tuln | grep -q ":$1 " && return 0
    lsof -i :"$1" &>/dev/null && return 0
    return 1
}

# 自动/手动获取可用端口（与 hy2 完全一致）
get_port() {
    local p="$1"

    # 若外部传入，则校验即可
    if [[ -n "$p" ]]; then
        is_valid_port "$p" || { err "端口无效"; exit 1; }
        is_port_occupied "$p" && { err "端口已被占用"; exit 1; }
        echo "$p"
        return
    fi

    # 若未传入 → 自动随机
    while true; do
        rp=$(shuf -i 1-65535 -n 1)
        ! is_port_occupied "$rp" && { echo "$rp"; return; }
    done
}

# ======================================================================
# 跳跃端口区间格式检查（例如：10000-20000）
# ======================================================================
is_valid_range() {
    [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    local min="${BASH_REMATCH[1]}"
    local max="${BASH_REMATCH[2]}"
    is_valid_port "$min" && is_valid_port "$max" && [[ $min -lt $max ]]
}

# ======================================================================
# 删除 NAT 跳跃端口规则（IPv4 + IPv6）
# ======================================================================
remove_nat_jump_rules() {

    while iptables -t nat -C PREROUTING -m comment --comment "tuic_jump" &>/dev/null; do
        iptables -t nat -D PREROUTING -m comment --comment "tuic_jump"
    done

    while ip6tables -t nat -C PREROUTING -m comment --comment "tuic_jump" &>/dev/null; do
        ip6tables -t nat -D PREROUTING -m comment --comment "tuic_jump"
    done

    green "跳跃端口 NAT 规则已删除"
}

# ======================================================================
# 添加 NAT 跳跃端口规则（核心逻辑）
# ======================================================================
add_jump_rule() {
    local min="$1"
    local max="$2"
    local listen_port="$3"

    # IPv4 NAT 映射
    iptables -t nat -A PREROUTING \
        -p udp --dport ${min}:${max} \
        -m comment --comment "tuic_jump" \
        -j DNAT --to-destination :${listen_port}

    # IPv6 NAT 映射
    ip6tables -t nat -A PREROUTING \
        -p udp --dport ${min}:${max} \
        -m comment --comment "tuic_jump" \
        -j DNAT --to-destination :${listen_port}

    green "已添加 NAT 映射：${min}-${max} → ${listen_port}"
}

# ======================================================================
# URL 节点名称更新（在 #tag 中附加区间）
# 格式：CN-ISP(10000-20000)
# ======================================================================
update_node_tag_for_jump() {
    local range="$1"

    [[ ! -f "$client_dir" ]] && return

    local old_url=$(cat "$client_dir")
    local url_body="${old_url%%#*}"
    local old_tag="${old_url#*#}"

    # 对 tag 解码
    local decoded=$(urldecode "$old_tag")

    # 删除原 tag 中的 "(xxx-xxx)" 信息
    decoded=$(echo "$decoded" | sed 's/(.*)//')

    # 添加跳跃区间
    local new_tag="${decoded}(${range})"
    local encoded_tag=$(urlencode "$new_tag")

    echo "${url_body}#${encoded_tag}" > "$client_dir"

    green "URL tag 更新为：${new_tag}"
}

# ======================================================================
# 删除跳跃端口区间（仅还原 tag，不影响节点名称）
# ======================================================================
remove_jump_tag() {
    [[ ! -f "$client_dir" ]] && return

    local old_url=$(cat "$client_dir")
    local url_body="${old_url%%#*}"
    local tag="${old_url#*#}"

    local decoded=$(urldecode "$tag")

    # 去除 "(xxx-xxx)"
    decoded=$(echo "$decoded" | sed 's/(.*)//')

    local encoded=$(urlencode "$decoded")

    echo "${url_body}#${encoded}" > "$client_dir"

    green "URL tag 已恢复为：${decoded}"
}

# ======================================================================
# 删除跳跃端口（NAT + 订阅 + URL）
# ======================================================================
remove_jump_ports() {

    remove_nat_jump_rules
    remove_jump_tag

    # 订阅重建（维持 sub.port 不变）
    uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")
    tuic_port=$(jq -r '.inbounds[0].listen_port' "$config_dir")

    if [[ -f "$sub_port_file" ]]; then
        sub_port=$(cat "$sub_port_file")
    else
        sub_port=$((tuic_port + 1))
    fi

    ipv4=$(curl -4 -s https://api.ipify.org)
    ipv6=$(curl -6 -s https://api64.ipify.org)
    [[ -n "$ipv4" ]] && server="$ipv4" || server="[$ipv6]"

    echo "http://${server}:${sub_port}/${uuid}" > "$sub_file"
    base64 -w0 "$sub_file" > "${work_dir}/sub_base64.txt"

cat > "${work_dir}/sub.json" <<EOF
{
  "tuic5": "http://${server}:${sub_port}/${uuid}"
}
EOF

    green "跳跃端口已完全删除"
}

# ======================================================================
# 启用跳跃端口（TUIC5 核心 NAT 功能）
# ======================================================================
configure_port_jump() {
    local min="$1"
    local max="$2"

    local listen_port
    listen_port=$(jq -r '.inbounds[0].listen_port' "$config_dir")

    [[ -z "$listen_port" ]] && { err "无法读取 TUIC5 主端口"; return; }

    green "启用跳跃端口区间：${min}-${max}"

    # 放行 INPUT
    iptables -C INPUT -p udp --dport ${min}:${max} -j ACCEPT &>/dev/null || \
        iptables -I INPUT -p udp --dport ${min}:${max} -j ACCEPT

    ip6tables -C INPUT -p udp --dport ${min}:${max} -j ACCEPT &>/dev/null || \
        ip6tables -I INPUT -p udp --dport ${min}:${max} -j ACCEPT

    # 删除旧 NAT 规则
    remove_nat_jump_rules

    # 添加 NAT 映射
    add_jump_rule "$min" "$max" "$listen_port"

    # 更新 URL 节点名称 tag
    update_node_tag_for_jump "${min}-${max}"

    # 更新订阅（区间不写入订阅，只写节点名）
    uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")

    if [[ -f "$sub_port_file" ]]; then
        sub_port=$(cat "$sub_port_file")
    else
        sub_port=$((listen_port + 1))
    fi

    ipv4=$(curl -4 -s https://api.ipify.org)
    ipv6=$(curl -6 -s https://api64.ipify.org)
    [[ -n "$ipv4" ]] && server="$ipv4" || server="[$ipv6]"

cat > "$sub_file" <<EOF
# TUIC5 订阅（跳跃端口：${min}-${max}）
http://${server}:${sub_port}/${uuid}
EOF

    base64 -w0 "$sub_file" > "${work_dir}/sub_base64.txt"

cat > "${work_dir}/sub.json" <<EOF
{
  "tuic5": "http://${server}:${sub_port}/${uuid}"
}
EOF

    systemctl restart sing-box-tuic5
    green "跳跃端口已成功启用！"
}
# ======================================================================
# TUIC5 安装模块（独立实例，支持 HY2 共存）
# ======================================================================
install_tuic5() {

    clear
    purple "开始安装 Sing-box TUIC5（独立实例，共存版）..."
    mkdir -p "$work_dir"

    # ==================================================================
    # 1. 检测系统架构
    # ==================================================================
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)   ARCH="amd64" ;;
        aarch64)  ARCH="arm64" ;;
        armv7l)   ARCH="armv7" ;;
        i386|i686) ARCH="i386" ;;
        riscv64)  ARCH="riscv64" ;;
        mips64el) ARCH="mips64le" ;;
        *)
            err "不支持的 CPU 架构：$ARCH"
            exit 1
            ;;
    esac

    FILE="sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${FILE}"

    yellow "下载 Sing-box 程序：$URL"

    curl -fSL --retry 3 --retry-delay 2 --connect-timeout 10 -o "$FILE" "$URL" \
        || { err "下载失败，请检查网络或 GitHub 访问情况"; exit 1; }

    tar -xzf "$FILE" || { err "解压失败"; exit 1; }
    rm -f "$FILE"

    extracted=$(find . -maxdepth 1 -type d -name "sing-box-*")
    mv "$extracted/sing-box" "$work_dir/sing-box"
    chmod +x "$work_dir/sing-box"
    rm -rf "$extracted"

    green "Sing-box 程序安装完成！路径：$work_dir/sing-box"


    # ==================================================================
    # 2. 自动 / 手动模式处理 TUIC 端口与 UUID
    # ==================================================================
    is_interactive_mode
    if [[ $? -eq 1 ]]; then
        white "自动模式：使用环境变量或自动生成配置"
        TUIC_PORT=$(get_port "$PORT")

        if [[ -n "$UUID" ]]; then
            is_valid_uuid "$UUID" || { err "UUID 格式无效"; exit 1; }
        else
            UUID="$DEFAULT_UUID"
        fi
    else
        white "交互模式：请手动输入配置"

        # 手动输入 TUIC 主端口
        while true; do
            read -rp "$(red_input '请输入 TUIC5 主端口：')" USER_PORT
            if is_valid_port "$USER_PORT" && ! is_port_occupied "$USER_PORT"; then
                TUIC_PORT="$USER_PORT"
                break
            else
                red "端口无效或占用，请重试"
            fi
        done

        # 输入 UUID
        while true; do
            read -rp "$(red_input '请输入 UUID（留空 = 自动生成）：')" USER_UUID
            if [[ -z "$USER_UUID" ]]; then
                UUID="$DEFAULT_UUID"
                green "自动生成 UUID：$UUID"
                break
            fi
            if is_valid_uuid "$USER_UUID"; then
                UUID="$USER_UUID"
                break
            else
                red "UUID 格式无效，请重新输入"
            fi
        done
    fi

    PASSWORD="$UUID"   # 你指定的规则：uuid = password

    allow_port "$TUIC_PORT"


    # ==================================================================
    # 3. 自动探测 DNS（与 hy2 一致）
    # ==================================================================
    ipv4_ok=false
    ipv6_ok=false
    ping -4 -c1 -W1 8.8.8.8 >/dev/null 2>&1 && ipv4_ok=true
    ping -6 -c1 -WW1 2001:4860:4860::8888 >/dev/null 2>&1 && ipv6_ok=true

    if $ipv4_ok && $ipv6_ok; then
        dns_servers_json='
      { "tag": "dns-ipv4", "address": "8.8.8.8" },
      { "tag": "dns-ipv6", "address": "2001:4860:4860::8888" }'
        dns_strategy="prefer_ipv4"
    elif $ipv4_ok; then
        dns_servers_json='{ "tag": "dns-ipv4", "address": "8.8.8.8" }'
        dns_strategy="prefer_ipv4"
    else
        dns_servers_json='{ "tag": "dns-ipv6", "address": "2001:4860:4860::8888" }'
        dns_strategy="prefer_ipv6"
    fi


    # ==================================================================
    # 4. 生成自签 TLS 证书
    # ==================================================================
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -x509 -new -nodes \
        -key "${work_dir}/private.key" \
        -sha256 -days 3650 \
        -subj "/C=US/ST=CA/O=bing.com/CN=bing.com" \
        -out "${work_dir}/cert.pem"

    green "TLS 证书已生成"


    # ==================================================================
    # 5. 写入 TUIC5 配置文件
    # ==================================================================
cat > "$config_dir" <<EOF
{
  "log": {
    "level": "error",
    "output": "$work_dir/sb.log"
  },

  "dns": {
    "strategy": "$dns_strategy",
    "servers": [
      $dns_servers_json
    ]
  },

  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic5",
      "listen": "::",
      "listen_port": $TUIC_PORT,

      "users": [
        { "uuid": "$UUID", "password": "$PASSWORD" }
      ],

      "tls": {
        "enabled": true,
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key",
        "alpn": ["h3"]
      },

      "congestion_control": "bbr",
      "zero_rtt_handshake": true
    }
  ],

  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

    green "TUIC5 配置文件已写入：$config_dir"


    # ==================================================================
    # 6. 写入 systemd 服务（与 HY2 分离）
    # ==================================================================
cat > /etc/systemd/system/sing-box-tuic5.service <<EOF
[Unit]
Description=Sing-box TUIC5 Service
After=network.target

[Service]
ExecStart=$work_dir/sing-box run -c $config_dir
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box-tuic5
    systemctl restart sing-box-tuic5

    green "TUIC5 服务已启动（服务名：sing-box-tuic5）"


    # ==================================================================
    # 7. 创建订阅端口（sub.port）
    # ==================================================================
    if [[ -f "$sub_port_file" ]]; then
        SUB_PORT=$(cat "$sub_port_file")
    else
        SUB_PORT=$((TUIC_PORT + 1))
        echo "$SUB_PORT" > "$sub_port_file"
    fi


    # ==================================================================
    # 8. 生成 URL / 订阅文件
    # ==================================================================
    ipv4=$(curl -4 -s https://api.ipify.org)
    ipv6=$(curl -6 -s https://api64.ipify.org)
    [[ -n "$ipv4" ]] && server="$ipv4" || server="[$ipv6]"

    # 节点名称采用 hy2 自动规则
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME=$(get_node_name)
    fi

    encoded_name=$(urlencode "$NODE_NAME")
    TUIC_URL="tuic://${UUID}:${UUID}@${server}:${TUIC_PORT}/#${encoded_name}"

    echo "$TUIC_URL" > "$client_dir"


    SUB_URL="http://${server}:${SUB_PORT}/${UUID}"

cat > "$sub_file" <<EOF
# TUIC5 订阅
$SUB_URL
EOF

    base64 -w0 "$sub_file" > "${work_dir}/sub_base64.txt"

cat > "${work_dir}/sub.json" <<EOF
{
  "tuic5": "$SUB_URL"
}
EOF

    green "URL / 订阅文件已生成"


    # ==================================================================
    # 9. 若自动模式传入 RANGE_PORTS，则自动启用跳跃端口
    # ==================================================================
    if [[ -n "$RANGE_PORTS" ]]; then
        if is_valid_range "$RANGE_PORTS"; then
            min="${RANGE_PORTS%-*}"
            max="${RANGE_PORTS#*-}"
            configure_port_jump "$min" "$max"
        fi
    fi

}
# ======================================================================
# 节点名称生成逻辑（继承 hy2 的智能命名）
# ======================================================================
get_node_name() {

    local DEFAULT_NODE_NAME="${AUTHOR}-${DEFAULT_NODE_SUFFIX}"

    # 若用户手动传入 NODE_NAME → 直接使用
    if [[ -n "$NODE_NAME" ]]; then
        echo "$NODE_NAME"
        return
    fi

    local country=""
    local org=""

    # 使用 ipapi 获取国家代码与运营商
    country=$(curl -fs --max-time 2 https://ipapi.co/country 2>/dev/null | tr -d '\r\n')
    org=$(curl -fs --max-time 2 https://ipapi.co/org     2>/dev/null | sed 's/[ ]\+/_/g')

    # fallback 1：ip.sb
    if [[ -z "$country" ]]; then
        country=$(curl -fs --max-time 2 ip.sb/country 2>/dev/null | tr -d '\r\n')
    fi

    # fallback 2：ipinfo
    if [[ -z "$org" ]]; then
        org=$(curl -fs --max-time 2 ipinfo.io/org 2>/dev/null \
            | awk '{$1=""; print $0}' \
            | sed -e 's/^[ ]*//' -e 's/[ ]\+/_/g')
    fi

    # 命名逻辑（完全匹配 hy2）：
    if [[ -n "$country" && -n "$org" ]]; then
        echo "${country}-${org}"
        return
    fi

    if [[ -n "$country" && -z "$org" ]]; then
        echo "${country}"
        return
    fi

    if [[ -z "$country" && -n "$org" ]]; then
        echo "${DEFAULT_NODE_NAME}"
        return
    fi

    echo "${DEFAULT_NODE_NAME}"
}



# ======================================================================
# 节点信息展示（URL / 跳跃端口 / 二维码 / 订阅）
# ======================================================================
print_node_info() {

    clear
    blue "==================== TUIC5 节点信息 ===================="

    local tuic_port uuid sub_port server ipv4 ipv6 url raw_tag decoded_tag

    tuic_port=$(jq -r '.inbounds[0].listen_port' "$config_dir")
    uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")

    # 识别 IP（优先 IPv4）
    ipv4=$(curl -4 -s https://api.ipify.org)
    ipv6=$(curl -6 -s https://api64.ipify.org)
    [[ -n "$ipv4" ]] && server="$ipv4" || server="[$ipv6]"

    # 读取订阅端口
    if [[ -f "$sub_port_file" ]]; then
        sub_port=$(cat "$sub_port_file")
    else
        sub_port=$((tuic_port + 1))
    fi

    # 读取 URL
    if [[ -f "$client_dir" ]]; then
        url=$(cat "$client_dir")
    else
        red "未找到 URL 文件，请先安装"
        return
    fi

    purple "\nTUIC5 URL："
    green "$url"
    echo ""

    yellow "二维码："
    echo "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${url}"
    echo ""

    # 节点名称 + 跳跃端口解析
    raw_tag="${url#*#}"
    decoded_tag=$(urldecode "$raw_tag")

    purple "节点名称："
    green "$decoded_tag"
    echo ""

    # 跳跃端口检测（tag 中存在 "(min-max)"）
    if echo "$decoded_tag" | grep -q "("; then
        local range=$(echo "$decoded_tag" | sed -n 's/.*(\(.*\)).*/\1/p')
        yellow "该节点启用了跳跃端口区间：$range"
        yellow "说明：客户端可从该区间任意 UDP 端口连接（NAT 转发）"
        echo ""
    else
        red "该节点当前未启用跳跃端口"
    fi


    purple "订阅链接："
    SUB_URL="http://${server}:${sub_port}/${uuid}"
    green "$SUB_URL"
    echo ""

    yellow "订阅二维码："
    echo "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${SUB_URL}"
    echo ""

    purple "Clash / Sing-box / Surge 转换："

    CLASH_URL="https://sublink.eooce.com/clash?config=${SUB_URL}"
    SBX_URL="https://sublink.eooce.com/singbox?config=${SUB_URL}"
    SURGE_URL="https://sublink.eooce.com/surge?config=${SUB_URL}"

    green "Clash:   $CLASH_URL"
    green "Singbox: $SBX_URL"
    green "Surge:   $SURGE_URL"

    echo ""
    yellow "========================================================="
}
# ======================================================================
# 修改 TUIC5 主端口
# ======================================================================
change_tuic_port() {

    local old_port new_port uuid range min max

    old_port=$(jq -r '.inbounds[0].listen_port' "$config_dir")
    uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")

    read -rp "$(red_input '请输入新的 TUIC5 主端口：')" new_port

    if ! is_valid_port "$new_port"; then
        red "端口无效"
        return
    fi
    if is_port_occupied "$new_port"; then
        red "端口已被占用"
        return
    fi

    # 替换 config.json 中 listen_port
    sed -i "s/\"listen_port\": ${old_port}/\"listen_port\": ${new_port}/" "$config_dir"

    allow_port "$new_port"

    green "主端口已更新：${old_port} → ${new_port}"

    # 若存在跳跃端口，则需要重建 NAT 映射
    local url=$(cat "$client_dir")
    local tag="${url#*#}"
    local decoded=$(urldecode "$tag")

    if echo "$decoded" | grep -q "("; then
        range=$(echo "$decoded" | sed -n 's/.*(\(.*\)).*/\1/p')
        min="${range%-*}"
        max="${range#*-}"

        yellow "检测到跳跃端口模式 → 重新绑定 NAT 映射"

        remove_nat_jump_rules
        configure_port_jump "$min" "$max"
    fi

    # ==================================================================
    # 更新 URL（host 与 tag 不变，只改端口）
    # ==================================================================
    local url_body="${url%%#*}"
    local tag_part="${url#*#}"

    # 替换端口
    url_body=$(echo "$url_body" | sed "s/:${old_port}/:${new_port}/")

    echo "${url_body}#${tag_part}" > "$client_dir"

    # ==================================================================
    # 订阅端口不变（始终使用 sub.port）
    # ==================================================================
    if [[ -f "$sub_port_file" ]]; then
        sub_port=$(cat "$sub_port_file")
    else
        sub_port=$((new_port + 1))
    fi

    ipv4=$(curl -4 -s https://api.ipify.org)
    ipv6=$(curl -6 -s https://api64.ipify.org)
    [[ -n "$ipv4" ]] && server="$ipv4" || server="[$ipv6]"

    SUB_URL="http://${server}:${sub_port}/${uuid}"

cat > "$sub_file" <<EOF
# TUIC5 主订阅（主端口已更新）
$SUB_URL
EOF

    base64 -w0 "$sub_file" > "${work_dir}/sub_base64.txt"

cat > "${work_dir}/sub.json" <<EOF
{
  "tuic5": "$SUB_URL"
}
EOF

    systemctl restart sing-box-tuic5
    green "主端口修改成功，配置已同步更新"
}


# ======================================================================
# 修改 UUID（uuid = password）
# ======================================================================
change_uuid() {

    local old_uuid new_uuid

    old_uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")

    read -rp "$(red_input '请输入新的 UUID（留空自动生成）：')" new_uuid

    if [[ -z "$new_uuid" ]]; then
        new_uuid=$(cat /proc/sys/kernel/random/uuid)
        green "自动生成 UUID：$new_uuid"
    else
        if ! is_valid_uuid "$new_uuid"; then
            red "UUID 格式错误"
            return
        fi
    fi

    # 写入 config.json（uuid = password）
    tmpfile=$(mktemp)
    jq '.inbounds[0].users[0].uuid = "'"$new_uuid"'" |
        .inbounds[0].users[0].password = "'"$new_uuid"'"' \
        "$config_dir" > "$tmpfile"

    mv "$tmpfile" "$config_dir"

    # ==================================================================
    # 更新 URL（替换 uuid）
    # ==================================================================
    local url=$(cat "$client_dir")
    local url_body="${url%%#*}"
    local tag_part="${url#*#}"

    local new_url_body=$(echo "$url_body" | sed "s/${old_uuid}/${new_uuid}/g")
    echo "${new_url_body}#${tag_part}" > "$client_dir"

    # ==================================================================
    # 更新订阅文件
    # ==================================================================
    tuic_port=$(jq -r '.inbounds[0].listen_port' "$config_dir")

    if [[ -f "$sub_port_file" ]]; then
        sub_port=$(cat "$sub_port_file")
    else
        sub_port=$((tuic_port + 1))
    fi

    ipv4=$(curl -4 -s https://api.ipify.org)
    ipv6=$(curl -6 -s https://api64.ipify.org)
    [[ -n "$ipv4" ]] && server="$ipv4" || server="[$ipv6]"

    SUB_URL="http://${server}:${sub_port}/${new_uuid}"

cat > "$sub_file" <<EOF
# TUIC5 主订阅（UUID 已更新）
$SUB_URL
EOF

    base64 -w0 "$sub_file" > "${work_dir}/sub_base64.txt"
cat > "${work_dir}/sub.json" <<EOF
{
  "tuic5": "$SUB_URL"
}
EOF

    systemctl restart sing-box-tuic5
    green "UUID 修改成功"
}


# ======================================================================
# 修改节点名称（保持跳跃端口标签）
# ======================================================================
change_node_name() {

    read -rp "$(red_input '请输入新的节点名称：')" NEW_NAME

    # 获取当前 URL
    local old_url=$(cat "$client_dir")
    local url_body="${old_url%%#*}"
    local old_tag="${old_url#*#}"

    local decoded=$(urldecode "$old_tag")

    # 检查是否带跳跃端口区间
    if echo "$decoded" | grep -q "("; then
        local range=$(echo "$decoded" | sed -n 's/.*(\(.*\)).*/\1/p')
        NEW_NAME="${NEW_NAME}(${range})"
    fi

    encoded_name=$(urlencode "$NEW_NAME")

    echo "${url_body}#${encoded_name}" > "$client_dir"

    green "节点名称已更新为：$NEW_NAME"
}


# ======================================================================
# 添加跳跃端口（NAT）
# ======================================================================
add_jump_ports() {

    read -rp "$(red_input '请输入跳跃端口起始值：')" min
    read -rp "$(red_input '请输入跳跃端口结束值：')" max

    local range="${min}-${max}"

    if ! is_valid_range "$range"; then
        red "无效区间格式（示例：10000-20000）"
        return
    fi

    configure_port_jump "$min" "$max"

    green "跳跃端口区间已启用：$range"
}


# ======================================================================
# 删除跳跃端口（还原）
# ======================================================================
delete_jump_ports() {
    remove_jump_ports
}

# ======================================================================
# Nginx 订阅管理（共存版：独立配置）
# ======================================================================
add_nginx_conf() {

    if ! command_exists nginx; then
        err "未安装 nginx，跳过订阅服务"
        return
    fi

    mkdir -p /etc/nginx/conf.d

    tuic_port=$(jq -r '.inbounds[0].listen_port' "$config_dir")
    uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")

    # 订阅端口 = 主端口 + 1（只在首次生成）
    if [[ -f "$sub_port_file" ]]; then
        nginx_port=$(cat "$sub_port_file")
    else
        nginx_port=$((tuic_port + 1))

        # 若端口被占用 → 递增查找可用端口
        if is_port_occupied "$nginx_port"; then
            for p in $(seq $((nginx_port + 1)) 65000); do
                if ! is_port_occupied "$p"; then
                    nginx_port="$p"
                    break
                fi
            done
        fi

        echo "$nginx_port" > "$sub_port_file"
    fi

cat > /etc/nginx/conf.d/singbox_tuic5_sub.conf <<EOF
server {
    listen $nginx_port;
    listen [::]:$nginx_port;

    server_name tuic5_sub.local;

    add_header Cache-Control "no-cache, must-revalidate";
    add_header Pragma "no-cache";
    add_header Expires "0";

    location /$uuid {
        alias $sub_file;
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF

    # 确保 nginx.conf 包含 conf.d/*.conf
    if [[ -f /etc/nginx/nginx.conf ]]; then
        if ! grep -q "conf.d/\*\.conf" /etc/nginx/nginx.conf; then
            sed -i '/http {/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        fi
    fi

    if nginx -t >/dev/null 2>&1; then
        systemctl restart nginx
        green "订阅服务已启动（端口：$nginx_port）"
    else
        red "Nginx 配置错误，请检查 /etc/nginx/conf.d/singbox_tuic5_sub.conf"
    fi
}


# ======================================================================
# 手动修改订阅端口（与 HY2 完全相同逻辑）
# ======================================================================
change_subscribe_port() {

    read -rp "$(red_input '请输入新的订阅端口：')" new_port

    if ! is_valid_port "$new_port"; then
        red "端口无效"
        return
    fi

    if is_port_occupied "$new_port"; then
        red "该端口已被占用"
        return
    fi

    echo "$new_port" > "$sub_port_file"

    uuid=$(jq -r '.inbounds[0].users[0].uuid' "$config_dir")

cat > /etc/nginx/conf.d/singbox_tuic5_sub.conf <<EOF
server {
    listen $new_port;
    listen [::]:$new_port;

    server_name tuic5_sub.local;

    location /$uuid {
        alias $sub_file;
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF

    systemctl restart nginx
    green "订阅服务端口已修改：$new_port"
}


# ======================================================================
# Nginx 管理菜单
# ======================================================================
manage_nginx_menu() {

    while true; do
        clear
        blue "============= 管理订阅服务（Nginx） ============="
        echo ""
        green " 1. 启动 Nginx"
        green " 2. 停止 Nginx"
        green " 3. 重启 Nginx"
        green " 4. 修改订阅端口"
        yellow "-------------------------------------"
        green " 0. 返回主菜单"
        red   " 88. 退出脚本"
        echo ""

        read -rp "请选择：" sel

        case "$sel" in
            1) systemctl start nginx; green "Nginx 已启动";;
            2) systemctl stop nginx; yellow "Nginx 已停止";;
            3) systemctl restart nginx; green "Nginx 已重启";;
            4) change_subscribe_port ;;
            0) return ;;
            88) exit_script ;;
            *) red "无效输入" ;;
        esac
        sleep 1
    done
}


# ======================================================================
# Sing-box TUIC5 服务控制菜单（独立实例）
# ======================================================================
manage_singbox_menu() {

    while true; do
        clear
        blue "================= Sing-box TUIC5 服务管理 ================="
        echo ""
        green " 1. 启动 Sing-box"
        green " 2. 停止 Sing-box"
        green " 3. 重启 Sing-box"
        yellow "---------------------------------------------"
        green " 0. 返回主菜单"
        red   " 88. 退出脚本"
        echo ""

        read -rp "请选择：" sel
        case "$sel" in
            1) systemctl start sing-box-tuic5; green "TUIC5 已启动";;
            2) systemctl stop sing-box-tuic5; yellow "TUIC5 已停止";;
            3) systemctl restart sing-box-tuic5; green "TUIC5 已重启";;
            0) return ;;
            88) exit_script ;;
            *) red "无效输入" ;;
        esac
    done
}


# ======================================================================
# 查看节点信息（封装）
# ======================================================================
check_nodes() {
    print_node_info
}


# ======================================================================
# 修改节点配置菜单
# ======================================================================
change_config_menu() {

    while true; do
        clear
        blue "============== 修改节点配置（TUIC5） ==============="
        echo ""
        green " 1. 修改 TUIC5 主端口"
        green " 2. 修改 UUID（即 password）"
        green " 3. 修改节点名称"
        green " 4. 添加跳跃端口（NAT）"
        green " 5. 删除跳跃端口"
        yellow "-----------------------------------------------------"
        green " 0. 返回主菜单"
        red   " 88. 退出脚本"
        echo ""

        read -rp "请选择：" sel

        case "$sel" in
            1) change_tuic_port ;;
            2) change_uuid ;;
            3) change_node_name ;;
            4) add_jump_ports ;;
            5) delete_jump_ports ;;
            0) return ;;
            88) exit_script ;;
            *) red "无效输入" ;;
        esac
    done
}


# ======================================================================
# 主菜单
# ======================================================================
menu() {
    clear
    blue "===================================================="
    gradient "      Sing-box 一键脚本（TUIC5 共存增强版）"
    gradient "      此tuic5脚本可与hy2共存(工作路径和nginx都分开了）"
    green    "            作者：$AUTHOR"
    yellow   "            版本：$VERSION"
    blue "===================================================="
    echo ""

    # Sing-box TUIC5 服务状态
    if systemctl is-active sing-box-tuic5 >/dev/null 2>&1; then
        sb_status="$(green '运行中')"
    else
        sb_status="$(red '未运行')"
    fi

    # Nginx 服务状态
    if systemctl is-active nginx >/dev/null 2>&1; then
        ng_status="$(green '运行中')"
    else
        ng_status="$(red '未运行')"
    fi

    yellow " TUIC5 状态：$sb_status"
    yellow " Nginx 状态：$ng_status"
    echo ""

    green  " 1. 安装 TUIC5"
    red    " 2. 卸载 TUIC5"
    yellow "----------------------------------------"
    green  " 3. 管理 TUIC5 服务"
    green  " 4. 查看节点信息"
    yellow "----------------------------------------"
    green  " 5. 修改节点配置"
    green  " 6. 管理订阅服务（Nginx）"
    yellow "----------------------------------------"
    purple " 7. 老王工具箱"
    yellow "----------------------------------------"
    red    " 88. 退出脚本"
    echo ""

    read -rp "请输入选项：" choice
}


# ======================================================================
# 主循环
# ======================================================================
main_loop() {

    while true; do

        menu

        case "$choice" in
            1)
                install_common_packages
                install_tuic5
                add_nginx_conf
                print_node_info
                ;;
            2)
                uninstall_tuic5
                ;;
            3)
                manage_singbox_menu
                ;;
            4)
                print_node_info
                ;;
            5)
                change_config_menu
                ;;
            6)
                manage_nginx_menu
                ;;
            7)
                bash <(curl -Ls ssh_tool.eooce.com)
                ;;
            88)
                exit_script
                ;;

            *)
                red "无效输入，请重新输入"
                ;;
        esac
    done
}


# ======================================================================
# 卸载 TUIC5（完全移除独立实例）
# ======================================================================
uninstall_tuic5() {

    clear
    blue "============== 卸载 TUIC5（Sing-box 独立实例） =============="
    echo ""
    read -rp "确认卸载？ [Y/n]：" u
    u=${u:-y}

    if [[ ! "$u" =~ ^[yY]$ ]]; then
        yellow "已取消卸载"
        return
    fi

    systemctl stop sing-box-tuic5
    systemctl disable sing-box-tuic5
    rm -f /etc/systemd/system/sing-box-tuic5.service
    systemctl daemon-reload

    rm -rf "$work_dir"

    rm -f /etc/nginx/conf.d/singbox_tuic5_sub.conf
    systemctl restart nginx >/dev/null 2>&1

    green "TUIC5 已完全卸载（独立实例已移除）"
}


# ======================================================================
# 退出脚本
# ======================================================================
exit_script() {
    green "感谢使用 TUIC5 一键脚本！"
    exit 0
}


# ======================================================================
# 程序入口 main()
# ======================================================================
main() {

    is_interactive_mode
    if [[ $? -eq 1 ]]; then
        install_common_packages
        install_tuic5
        add_nginx_conf
        print_node_info
        read -n 1 -s -r -p "按任意键进入主菜单..."
        main_loop
    else
        main_loop
    fi
}

main
