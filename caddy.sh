#!/usr/bin/env bash

# ========================================
# Caddy 一键管理脚本
# 作者: 千狐 (https://github.com/qianhu111)
# ========================================

# 颜色定义
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[0;34m"
PURPLE="\033[1;35m"
RESET="\033[0m"

# 日志函数
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ========================================
# 输入校验
# ========================================
validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_upstream() {
    # host:port 或 IP:port
    [[ "$1" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]
}

# 通用读取并校验输入
# 用法: read_required "提示文本: " 变量名 [校验函数]
read_required() {
    local prompt="$1" varname="$2" validator="${3:-}"
    local value
    while true; do
        read -rp "$prompt" value
        if [[ -z "$value" ]]; then
            warn "输入不能为空"
            continue
        fi
        if [[ -n "$validator" ]] && ! "$validator" "$value"; then
            warn "格式无效，请重新输入"
            continue
        fi
        printf -v "$varname" '%s' "$value"
        break
    done
}

# ========================================
# 系统识别
# ========================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="$ID"
        VERSION="$VERSION_ID"
        info "检测到操作系统: $OS $VERSION"
    else
        die "无法识别操作系统"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)         ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l)         ARCH="armv7" ;;
        *)              die "不支持的架构: $(uname -m)" ;;
    esac
    info "检测到架构: ${ARCH}"
}

# ========================================
# 检查并创建运行用户
# ========================================
check_user() {
    if id -u www-data >/dev/null 2>&1; then
        return
    fi
    warn "未检测到 www-data 用户，正在创建..."
    if command -v useradd >/dev/null 2>&1; then
        sudo useradd -r -d /var/lib/caddy -s /usr/sbin/nologin www-data
    elif command -v adduser >/dev/null 2>&1; then
        # busybox / alpine 兼容
        sudo adduser -S -H -h /var/lib/caddy -s /sbin/nologin www-data
    else
        die "无法自动创建用户，请手动创建 www-data 用户"
    fi
}

# ========================================
# 安装依赖
# ========================================
install_dependencies() {
    local deps=(curl sudo lsof host gnupg tar)
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        info "所有基础依赖已安装"
        return
    fi

    info "安装缺失依赖: ${to_install[*]}"
    case "$OS" in
        debian|ubuntu|kali)
            sudo apt update
            sudo apt install -y "${to_install[@]}" debian-keyring debian-archive-keyring apt-transport-https
            ;;
        centos|rhel|almalinux|rocky)
            sudo yum install -y "${to_install[@]}" bind-utils
            ;;
        fedora)
            sudo dnf install -y "${to_install[@]}" bind-utils
            ;;
        alpine)
            sudo apk add --no-cache "${to_install[@]}" bind-tools
            ;;
        *)
            die "不支持的系统或无法自动安装依赖: $OS"
            ;;
    esac
}

# ========================================
# 获取服务器公网 IP
# ========================================
get_public_ip() {
    info "正在获取当前服务器公网 IP..."

    # ---------- IPv4 ----------
    local local_ipv4
    local_ipv4=$(ip -4 a 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -Ev '^(127\.|169\.254\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1)

    if [[ -n "$local_ipv4" ]]; then
        ipv4="$local_ipv4"
    else
        ipv4=$(curl -4 -fsS --max-time 5 "https://api.ipify.org" 2>/dev/null \
            || curl -4 -fsS --max-time 5 "https://ip.sb" 2>/dev/null \
            || true)
    fi

    # ---------- IPv6 ----------
    local local_ipv6
    local_ipv6=$(ip -6 a 2>/dev/null | grep -oP 'inet6 \K[^/]*' | grep -v '^fe80' | grep -v '^::1$' | head -n1)

    if [[ -n "$local_ipv6" ]]; then
        ipv6="$local_ipv6"
    else
        ipv6=$(curl -6 -fsS --max-time 5 "https://api64.ipify.org" 2>/dev/null \
            || curl -6 -fsS --max-time 5 "https://ip.sb" 2>/dev/null \
            || true)
    fi

    [[ -z "$ipv4" ]] && ipv4="无 IPv4"
    [[ -z "$ipv6" ]] && ipv6="无 IPv6"

    info "服务器 IPv4: ${GREEN}${ipv4}${RESET}"
    info "服务器 IPv6: ${GREEN}${ipv6}${RESET}"
}

# ========================================
# 域名解析检测
# ========================================
check_domain() {
    local domain="$1"
    [[ -z "$domain" ]] && die "域名不能为空"

    info "正在解析域名 $domain..."

    local resolved_ipv4 resolved_ipv6
    resolved_ipv4=$(host "$domain" 2>/dev/null | awk '/has address/{print $NF}' | tr '\n' ' ')
    resolved_ipv6=$(host "$domain" 2>/dev/null | awk '/has IPv6 address/{print $NF}' | tr '\n' ' ')

    if [[ -z "$resolved_ipv4" && -z "$resolved_ipv6" ]]; then
        warn "无法解析域名 $domain，请检查 DNS 设置"
        read -rp "是否强制继续安装？(y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
        return
    fi

    info "域名解析结果: ${GREEN}${resolved_ipv4}${resolved_ipv6}${RESET}"

    local match=0
    if [[ "$ipv4" != "无 IPv4" ]] && echo "$resolved_ipv4" | grep -qwF "$ipv4"; then
        match=1
    fi
    if [[ "$ipv6" != "无 IPv6" ]] && echo "$resolved_ipv6" | grep -qwF "$ipv6"; then
        match=1
    fi

    if [[ $match -eq 1 ]]; then
        info "域名 ${GREEN}$domain${RESET} 已正确解析到当前服务器"
    else
        warn "域名解析 IP 与本机 IP 不一致！"
        warn "本机: $ipv4 / $ipv6"
        warn "域名: $resolved_ipv4/ $resolved_ipv6"
        read -rp "是否强制继续？(可能导致证书申请失败) (y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi
}

# ========================================
# 端口检测
# ========================================
# 判断指定端口是否被 caddy 进程占用（精确匹配进程名，避免误判）
port_owner_is_caddy() {
    local port="$1"
    local pid cmd
    pid=$(sudo lsof -i :"$port" -Pn -sTCP:LISTEN -t 2>/dev/null | head -n1)
    [[ -z "$pid" ]] && return 1
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
    [[ "$cmd" == "caddy" ]]
}

check_ports() {
    info "正在检测 80/443 端口状态..."
    HTTP_FREE=1
    HTTPS_FREE=1

    for port in 80 443; do
        if sudo lsof -i :"$port" -Pn -sTCP:LISTEN >/dev/null 2>&1; then
            if port_owner_is_caddy "$port"; then
                info "端口 $port 被 Caddy 占用，属于正常情况"
            else
                warn "端口 $port 已被非 Caddy 进程占用"
                [[ "$port" == "80" ]]  && HTTP_FREE=0
                [[ "$port" == "443" ]] && HTTPS_FREE=0
            fi
        fi
    done
}

# ========================================
# 安装并配置 Caddy
# ========================================
install_caddy() {
    # 1. 收集信息（带校验）
    read_required "请输入绑定的域名: " DOMAIN validate_domain
    read_required "请输入用于申请证书的邮箱 (用于 Let's Encrypt): " EMAIL validate_email
    read_required "请输入反向代理目标地址 (例如 127.0.0.1:8888): " UPSTREAM validate_upstream

    # Token 输入不回显
    read -srp "请输入 Cloudflare API Token (可留空，若不使用 DNS 验证): " CF_TOKEN
    echo

    # 2. 环境检查
    detect_arch
    get_public_ip
    check_domain "$DOMAIN"
    check_ports
    check_user

    # 3. 安装 Caddy
    info "开始安装 Caddy..."

    # 停止旧服务以防冲突
    sudo systemctl stop caddy 2>/dev/null || true

    if [[ -n "$CF_TOKEN" ]]; then
        info "检测到 Cloudflare Token，正在下载集成 Cloudflare 插件的 Caddy..."
        local download_url="https://caddyserver.com/api/download?os=linux&arch=${ARCH}&p=github.com%2Fcaddy-dns%2Fcloudflare"

        if curl -fSL -o /tmp/caddy "$download_url"; then
            sudo install -m 0755 /tmp/caddy /usr/bin/caddy
            rm -f /tmp/caddy
            info "✅ Caddy (Cloudflare 版) 下载完成"
        else
            die "Caddy 下载失败，请检查网络连接"
        fi

        # 验证插件确实存在
        if ! /usr/bin/caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
            warn "未检测到 cloudflare 插件，DNS-01 验证可能失败"
        fi
    else
        info "使用标准方式安装 Caddy..."
        case "$OS" in
            debian|ubuntu|kali)
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                    | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-archive-keyring.gpg
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                    | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
                sudo apt update
                sudo apt install -y caddy
                ;;
            centos|rhel|almalinux|rocky)
                sudo yum install -y yum-plugin-copr
                sudo yum copr enable -y @caddy/caddy
                sudo yum install -y caddy
                ;;
            fedora)
                sudo dnf install -y 'dnf-command(copr)'
                sudo dnf copr enable -y @caddy/caddy
                sudo dnf install -y caddy
                ;;
            *)
                # 通用安装：从 GitHub release 下载
                local caddy_ver
                caddy_ver=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest \
                    | grep '"tag_name"' | cut -d '"' -f4)
                [[ -z "$caddy_ver" ]] && die "无法获取 Caddy 最新版本"
                curl -fSL -o /tmp/caddy.tar.gz \
                    "https://github.com/caddyserver/caddy/releases/download/${caddy_ver}/caddy_${caddy_ver#v}_linux_${ARCH}.tar.gz"
                tar -xzf /tmp/caddy.tar.gz -C /tmp caddy
                sudo install -m 0755 /tmp/caddy /usr/bin/caddy
                rm -f /tmp/caddy /tmp/caddy.tar.gz
                ;;
        esac
    fi

    # 4. 目录权限配置
    sudo mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    sudo chown -R www-data:www-data /var/lib/caddy /etc/caddy /var/log/caddy
    sudo chmod 750 /var/lib/caddy /etc/caddy /var/log/caddy

    # 5. 生成 Caddyfile
    info "生成配置文件..."
    local tmp_caddyfile
    tmp_caddyfile=$(mktemp)

    cat > "$tmp_caddyfile" <<EOF
{
    storage file_system /var/lib/caddy
    log {
        output file /var/log/caddy/access.log
    }
}

${DOMAIN} {
    encode gzip
    reverse_proxy ${UPSTREAM} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Port {server_port}
    }
EOF

    # TLS 配置
    if [[ -n "$CF_TOKEN" ]]; then
        cat >> "$tmp_caddyfile" <<EOF
    tls ${EMAIL} {
        dns cloudflare {env.CF_API_TOKEN}
    }
}
EOF
    elif [[ $HTTP_FREE -eq 1 && $HTTPS_FREE -eq 1 ]]; then
        cat >> "$tmp_caddyfile" <<EOF
    tls ${EMAIL}
}
EOF
    elif [[ $HTTPS_FREE -eq 1 ]]; then
        cat >> "$tmp_caddyfile" <<EOF
    tls ${EMAIL} {
        alpn tls-alpn-01
    }
}
EOF
    else
        warn "80/443 端口均被非 Caddy 进程占用，证书申请大概率会失败"
        cat >> "$tmp_caddyfile" <<EOF
    tls ${EMAIL}
}
EOF
    fi

    sudo install -m 0640 -o root -g www-data "$tmp_caddyfile" /etc/caddy/Caddyfile
    rm -f "$tmp_caddyfile"

    # 6. 将 CF Token 保存到独立 env 文件（权限 0640），由 systemd 加载
    if [[ -n "$CF_TOKEN" ]]; then
        local tmp_env
        tmp_env=$(mktemp)
        printf 'CF_API_TOKEN=%s\n' "$CF_TOKEN" > "$tmp_env"
        sudo install -m 0640 -o root -g www-data "$tmp_env" /etc/caddy/caddy.env
        rm -f "$tmp_env"
    else
        sudo rm -f /etc/caddy/caddy.env
    fi

    # 7. 配置 Systemd 服务（Token 通过 EnvironmentFile 加载，不写入 unit 文件）
    cat <<'EOF' | sudo tee /etc/systemd/system/caddy.service > /dev/null
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
User=www-data
Group=www-data
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment=CADDY_DATA_DIR=/var/lib/caddy
Environment=CADDY_CONFIG_DIR=/etc/caddy
EnvironmentFile=-/etc/caddy/caddy.env

[Install]
WantedBy=multi-user.target
EOF

    # 8. 启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable caddy
    info "正在启动 Caddy..."
    sudo systemctl restart caddy

    # 9. 验证证书
    info "Caddy 已启动，正在等待证书签发 (约 30 秒)..."
    sleep 30

    local cert_files
    cert_files=$(sudo find /var/lib/caddy -type f \( -name "${DOMAIN}*.crt" -o -name "${DOMAIN}*.key" \) 2>/dev/null)

    if [[ -n "$cert_files" ]]; then
        info "✅ 证书申请成功！文件位置："
        echo "$cert_files"
        echo -e "\n网站现已可通过 ${GREEN}https://${DOMAIN}${RESET} 访问"
    else
        warn "未在默认路径找到证书文件，可能是申请延迟或失败。"
        warn "请使用菜单中的 '查看实时日志' 排查问题。"
        warn "常见原因：域名解析未生效、防火墙未放行 80/443 端口。"
    fi
}

# ========================================
# Caddy 服务管理
# ========================================
manage_caddy() {
    while true; do
        echo -e "\n${BLUE}========================================${RESET}"
        echo "              Caddy 服务管理             "
        echo -e "${BLUE}========================================${RESET}"
        echo -e "${YELLOW}1)${RESET} 启动 Caddy"
        echo -e "${YELLOW}2)${RESET} 停止 Caddy"
        echo -e "${YELLOW}3)${RESET} 重启 Caddy"
        echo -e "${YELLOW}4)${RESET} 查看实时日志 (按 Ctrl+C 退出)"
        echo -e "${YELLOW}5)${RESET} 查看配置文件"
        echo -e "${YELLOW}6)${RESET} 查看证书文件"
        echo -e "${YELLOW}7)${RESET} 返回主菜单"
        read -rp "请选择操作 [1-7]: " choice
        case $choice in
            1) sudo systemctl start caddy   && info "已启动" ;;
            2) sudo systemctl stop caddy    && info "已停止" ;;
            3) sudo systemctl restart caddy && info "已重启" ;;
            4) sudo journalctl -u caddy -f ;;
            5) sudo cat /etc/caddy/Caddyfile ;;
            6)
                local dom
                read -rp "请输入域名: " dom
                if [[ -z "$dom" ]]; then
                    warn "域名不能为空"
                elif [[ -d /var/lib/caddy ]]; then
                    local found
                    found=$(sudo find /var/lib/caddy -type f \( -name "${dom}*.crt" -o -name "${dom}*.key" \) 2>/dev/null)
                    if [[ -n "$found" ]]; then
                        echo "$found"
                    else
                        warn "未找到匹配的证书文件"
                    fi
                else
                    warn "证书目录不存在: /var/lib/caddy"
                fi
                ;;
            7) return ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ========================================
# 卸载 Caddy
# ========================================
uninstall_caddy() {
    echo -e "\n${RED}警告：此操作将删除 Caddy 及其所有配置和证书！${RESET}"
    read -rp "确认卸载吗？(y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    info "停止服务..."
    sudo systemctl stop caddy 2>/dev/null || true
    sudo systemctl disable caddy 2>/dev/null || true

    info "删除文件..."
    sudo rm -f /etc/systemd/system/caddy.service
    sudo rm -rf /etc/systemd/system/caddy.service.d
    sudo rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
    sudo rm -f /usr/bin/caddy /usr/local/bin/caddy

    # 包管理器卸载
    if command -v apt >/dev/null 2>&1; then
        sudo apt remove --purge -y caddy 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
        sudo rm -f /usr/share/keyrings/caddy-archive-keyring.gpg
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf remove -y caddy 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        sudo yum remove -y caddy 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
        sudo apk del caddy 2>/dev/null || true
    fi

    sudo systemctl daemon-reload
    info "✅ Caddy 已卸载清理完毕"
}

# ========================================
# 主菜单
# ========================================
main_menu() {
    detect_os

    while true; do
        echo -e "\n${BLUE}========================================${RESET}"
        echo -e "      Caddy 一键管理脚本 ${PURPLE}by 千狐${RESET}        "
        echo -e "${BLUE}========================================${RESET}"
        echo -e "${YELLOW}1)${RESET} 安装并配置 Caddy (含证书申请)"
        echo -e "${YELLOW}2)${RESET} Caddy 服务管理 / 日志"
        echo -e "${YELLOW}3)${RESET} 卸载 Caddy"
        echo -e "${YELLOW}4)${RESET} 退出"

        read -rp "请选择操作 [1-4]: " choice
        case $choice in
            1)
                install_dependencies
                install_caddy
                ;;
            2)
                manage_caddy
                ;;
            3)
                uninstall_caddy
                ;;
            4)
                exit 0
                ;;
            *)
                warn "无效输入，请重新选择"
                ;;
        esac
    done
}

# ========================================
# 入口
# ========================================
main_menu
