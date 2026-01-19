#!/usr/bin/env bash

# ========================================
# Caddy 一键管理脚本 (修复增强版)
# ========================================

# 定义颜色
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[0;34m"
PURPLE="\033[1;35m"
RESET="\033[0m"

# 日志函数
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }

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
        error "无法识别操作系统"
        exit 1
    fi
}

# ========================================
# 检查并创建运行用户
# ========================================
check_user() {
    if ! id -u www-data >/dev/null 2>&1; then
        warn "未检测到 www-data 用户，正在创建..."
        if command -v useradd >/dev/null 2>&1; then
            sudo useradd -r -d /var/lib/caddy -s /usr/sbin/nologin www-data
        else
            error "无法自动创建用户，请手动创建 www-data 用户"
            exit 1
        fi
    fi
}

# ========================================
# 安装依赖
# ========================================
install_dependencies() {
    local deps=(curl sudo lsof host gnupg)
    local to_install=()
    
    # 检查命令是否存在
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            to_install+=("$dep")
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
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
                error "不支持的系统或无法自动安装依赖: $OS"
                exit 1
                ;;
        esac
    else
        info "所有基础依赖已安装"
    fi
}

# ========================================
# 获取服务器公网 IP
# ========================================
get_public_ip() {
    info "正在获取当前服务器公网 IP..."

    # ---------- IPv4 ----------
    local local_ipv4
    local_ipv4=$(ip -4 a | grep -oP 'inet \K[\d.]+' | grep -Ev '^(127\.|169\.254\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1)
    
    if [[ -n "$local_ipv4" ]]; then
        ipv4="$local_ipv4"
    else
        ipv4=$(curl -4 -s --max-time 5 "https://api.ipify.org" || curl -4 -s --max-time 5 "https://ip.sb")
    fi

    # ---------- IPv6 ----------
    local local_ipv6
    local_ipv6=$(ip -6 a | grep -oP 'inet6 \K[^/]*' | grep -v '^fe80' | grep -v '^::1$' | head -n1)
    
    if [[ -n "$local_ipv6" ]]; then
        ipv6="$local_ipv6"
    else
        ipv6=$(curl -6 -s --max-time 5 "https://api64.ipify.org" || curl -6 -s --max-time 5 "https://ip.sb")
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
    if [[ -z "$domain" ]]; then
        error "域名不能为空"
        exit 1
    fi

    info "正在解析域名 $domain..."
    
    # 获取解析记录
    local resolved_ips
    resolved_ips=$(host "$domain" 2>/dev/null | grep "has address" | awk '{print $NF}')
    local resolved_ipv6
    resolved_ipv6=$(host "$domain" 2>/dev/null | grep "has IPv6 address" | awk '{print $NF}')

    if [[ -z "$resolved_ips" && -z "$resolved_ipv6" ]]; then
        warn "无法解析域名 $domain，请检查 DNS 设置"
        read -rp "是否强制继续安装？(y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
        return
    fi

    info "域名解析结果: ${GREEN}${resolved_ips} ${resolved_ipv6}${RESET}"

    local match=0
    # 检查 IPv4
    if [[ "$ipv4" != "无 IPv4" ]] && echo "$resolved_ips" | grep -q "$ipv4"; then
        match=1
    fi
    # 检查 IPv6
    if [[ "$ipv6" != "无 IPv6" ]] && echo "$resolved_ipv6" | grep -q "$ipv6"; then
        match=1
    fi

    if [[ $match -eq 1 ]]; then
        info "域名 ${GREEN}$domain${RESET} 已正确解析到当前服务器"
    else
        warn "域名解析 IP 与本机 IP 不一致！"
        warn "本机: $ipv4 / $ipv6"
        warn "域名: $resolved_ips / $resolved_ipv6"
        read -rp "是否强制继续？(可能导致证书申请失败) (y/n): " choice
        [[ "$choice" =~ ^[Yy]$ ]] || { info "安装已取消"; exit 1; }
    fi
}

# ========================================
# 端口检测
# ========================================
check_ports() {
    info "正在检测 80/443 端口状态..."
    HTTP_FREE=1
    HTTPS_FREE=1

    if sudo lsof -i :80 -Pn -sTCP:LISTEN >/dev/null 2>&1; then
        warn "端口 80 已被占用"
        HTTP_FREE=0
    fi

    if sudo lsof -i :443 -Pn -sTCP:LISTEN >/dev/null 2>&1; then
        warn "端口 443 已被占用"
        HTTPS_FREE=0
    fi
    
    # 如果是 Caddy 占用的，则认为是安全的（因为我们会重启它）
    if [ $HTTP_FREE -eq 0 ]; then
        if sudo lsof -i :80 -Pn -sTCP:LISTEN | grep -q "caddy"; then
            info "端口 80 被 Caddy 占用，属于正常情况"
            HTTP_FREE=1
        fi
    fi
     if [ $HTTPS_FREE -eq 0 ]; then
        if sudo lsof -i :443 -Pn -sTCP:LISTEN | grep -q "caddy"; then
            info "端口 443 被 Caddy 占用，属于正常情况"
            HTTPS_FREE=1
        fi
    fi
}

# ========================================
# 安装并配置 Caddy
# ========================================
install_caddy() {
    # 1. 收集信息
    read -rp "请输入绑定的域名: " DOMAIN
    read -rp "请输入用于申请证书的邮箱 (用于 Lets Encrypt): " EMAIL
    read -rp "请输入反向代理目标地址 (例如 127.0.0.1:8888): " UPSTREAM
    read -rp "请输入 Cloudflare API Token (可留空，若不使用 DNS 验证): " CF_TOKEN
    
    [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$UPSTREAM" ]] && { error "关键信息不能为空"; return; }

    # 2. 环境检查
    get_public_ip
    check_domain "$DOMAIN"
    check_ports
    check_user # 确保 www-data 存在

    # 3. 安装 Caddy
    info "开始安装 Caddy..."
    
    # 停止旧服务以防冲突
    sudo systemctl stop caddy 2>/dev/null

    if [[ -n "$CF_TOKEN" ]]; then
        info "检测到 Cloudflare Token，正在下载集成 Cloudflare 插件的 Caddy..."
        # 官方构建下载链接
        DOWNLOAD_URL="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare"
        
        if wget -O /tmp/caddy "$DOWNLOAD_URL"; then
            sudo mv /tmp/caddy /usr/bin/caddy
            sudo chmod +x /usr/bin/caddy
            info "✅ Caddy (Cloudflare版) 下载完成"
        else
            error "下载失败，请检查网络连接"
            exit 1
        fi
    else
        info "使用标准方式安装 Caddy..."
        case "$OS" in
            debian|ubuntu|kali)
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg --yes
                curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
                sudo apt update
                sudo apt install -y caddy
                ;;
            centos|rhel|almalinux|rocky)
                sudo yum install -y yum-plugin-copr
                sudo yum copr enable @caddy/caddy -y
                sudo yum install -y caddy
                ;;
            fedora)
                sudo dnf install -y 'dnf-command(copr)'
                sudo dnf copr enable @caddy/caddy -y
                sudo dnf install -y caddy
                ;;
            *)
                # 通用安装
                CADDY_VER=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep tag_name | cut -d '"' -f4)
                wget -O /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/${CADDY_VER}/caddy_${CADDY_VER#v}_linux_amd64.tar.gz"
                tar -xzf /tmp/caddy.tar.gz -C /tmp
                sudo mv /tmp/caddy /usr/bin/caddy
                sudo chmod +x /usr/bin/caddy
                ;;
        esac
    fi

    # 4. 目录权限配置
    sudo mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    sudo chown -R www-data:www-data /var/lib/caddy /etc/caddy /var/log/caddy
    sudo chmod 750 /var/lib/caddy /etc/caddy /var/log/caddy

    # 5. 生成 Caddyfile
    info "生成配置文件..."
    
    cat > /tmp/Caddyfile <<EOF
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

    # 处理 TLS 配置
    if [[ -n "$CF_TOKEN" ]]; then
        cat >> /tmp/Caddyfile <<EOF
    tls {
        dns cloudflare ${CF_TOKEN}
    }
}
EOF
    else
        # 自动 HTTPS 逻辑
        if [[ $HTTP_FREE -eq 1 && $HTTPS_FREE -eq 1 ]]; then
            cat >> /tmp/Caddyfile <<EOF
    tls ${EMAIL}
}
EOF
        elif [[ $HTTPS_FREE -eq 1 ]]; then
             cat >> /tmp/Caddyfile <<EOF
    tls ${EMAIL} {
        alpn tls-alpn-01
    }
}
EOF
        else
            warn "80/443 端口似乎被非 Caddy 进程占用，证书申请可能会失败"
            cat >> /tmp/Caddyfile <<EOF
    tls ${EMAIL}
}
EOF
        fi
    fi

    sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile

    # 6. 配置 Systemd 服务
    # 为了保证配置一致性，我们覆盖默认的 service 文件或新建它
    cat <<EOF | sudo tee /etc/systemd/system/caddy.service > /dev/null
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
$( [[ -n "$CF_TOKEN" ]] && echo "Environment=CF_API_TOKEN=${CF_TOKEN}" )

[Install]
WantedBy=multi-user.target
EOF

    # 7. 启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable caddy
    info "正在启动 Caddy..."
    sudo systemctl restart caddy

    # 8. 验证证书
    info "Caddy 已启动，正在等待证书签发 (约 30 秒)..."
    sleep 30
    
    # 修复了原有脚本中变量名为 dom 的错误
    CERT_FILES=$(find /var/lib/caddy -type f \( -name "${DOMAIN}*.crt" -o -name "${DOMAIN}*.key" \) 2>/dev/null)
    
    if [[ -n "$CERT_FILES" ]]; then
        info "✅ 证书申请成功！文件位置："
        echo "$CERT_FILES"
        echo -e "\n网站现已可通过 https://${DOMAIN} 访问"
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
    echo -e "\n${BLUE}========================================${RESET}"
    echo "              Caddy 服务管理             "
    echo -e "${BLUE}========================================${RESET}"
    echo -e "${YELLOW}1)${RESET} 启动 Caddy"
    echo -e "${YELLOW}2)${RESET} 停止 Caddy"
    echo -e "${YELLOW}3)${RESET} 重启 Caddy"
    echo -e "${YELLOW}4)${RESET} 查看实时日志 (按 Ctrl+C 退出)"
    echo -e "${YELLOW}5)${RESET} 查看配置文件"
    echo -e "${YELLOW}6)${RESET} 返回主菜单"
    read -rp "请选择操作: " choice
    case $choice in
        1) sudo systemctl start caddy && info "已启动";;
        2) sudo systemctl stop caddy && info "已停止";;
        3) sudo systemctl restart caddy && info "已重启";;
        4) sudo journalctl -u caddy -f;;
        5) cat /etc/caddy/Caddyfile;;
        6) return;;
        *) warn "无效选择";;
    esac
}

# ========================================
# 卸载 Caddy
# ========================================
uninstall_caddy() {
    echo -e "\n${RED}警告：此操作将删除 Caddy 及其所有配置和证书！${RESET}"
    read -rp "确认卸载吗？(y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    info "停止服务..."
    sudo systemctl stop caddy 2>/dev/null
    sudo systemctl disable caddy 2>/dev/null
    
    info "删除文件..."
    sudo rm -f /etc/systemd/system/caddy.service
    sudo rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
    sudo rm -f /usr/bin/caddy
    
    # 尝试包管理器卸载
    if command -v apt >/dev/null 2>&1; then
        sudo apt remove -y caddy 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        sudo yum remove -y caddy 2>/dev/null
    fi

    sudo systemctl daemon-reload
    info "✅ Caddy 已卸载清理完毕"
}

# ========================================
# 主菜单
# ========================================
main_menu() {
    # 第一次运行检测
    detect_os
    
    while true; do
        echo -e "\n${BLUE}========================================${RESET}"
        echo -e "      Caddy 一键管理脚本 (修复版)        "
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
