# Caddy Manager 一键管理脚本

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Caddy Manager 是一款支持交互式安装、配置 Caddy 并自动申请 SSL 证书的一键管理脚本。  
支持多种 VPS 环境，自动检测系统和依赖，输出中文提示，适合国内用户使用。

仓库地址: [https://github.com/qianhu111/caddy-manager](https://github.com/qianhu111/caddy-manager)

---

## 功能特性

- **一键安装 Caddy**  
  自动添加官方 apt 源并安装最新版 Caddy，配置 systemd 服务并开机自启。

- **自动申请 SSL 证书**  
  支持 HTTP-01、TLS-ALPN-01、DNS-01（Cloudflare Token）验证方式，证书由 Let's Encrypt 签发。

- **交互式配置**  
  提示用户输入域名、邮箱、反向代理目标、Cloudflare Token，输入时自动校验格式，Token 不回显。

- **端口与系统检测**  
  自动检测 80/443 是否可用，检测操作系统类型及依赖安装。

- **中文化输出**  
  安装过程和错误提示均为中文，友好易用。

- **服务管理**  
  提供启动、停止、重启、查看日志和证书文件的操作。

- **卸载功能**  
  可彻底卸载 Caddy 并清理配置和证书文件。

---

## 使用方式

### 在线执行

```bash
bash <(curl -sSL https://raw.githubusercontent.com/qianhu111/caddy-manager/main/caddy.sh)
```

### 本地执行

```bash
git clone https://github.com/qianhu111/caddy-manager.git
cd caddy-manager
chmod +x caddy.sh
sudo ./caddy.sh
```

### Cloudflare Token 获取方式

1. 登录 Cloudflare
访问 [Cloudflare 仪表盘](https://dash.cloudflare.com)，使用你的账户登录。

2. 进入 API Tokens 页面
  * 在右上角点击 个人资料头像 → 我的个人资料。
  * 左侧菜单选择 API Tokens。

3. 创建 Token
  * 点击 Create Token（创建 Token）。
  * Cloudflare 提供了一个 预设模板，选择 Edit zone DNS（用于编辑 DNS 的模板）即可。
    * 或者选择 Use custom token 来自定义权限。

4. 设置权限（DNS-01 验证最小权限）
如果选择自定义 Token：

| 资源 | 权限 |
|---|---|
| Zone Resources | Include → 指定你的域名（例如 example.com） |
| DNS | Edit |

5. 生成并保存 Token
  * 点击 Continue to summary → Create Token。
  * 复制生成的 Token，并妥善保存（只显示一次）。
  > 脚本中使用这个 Token 时，可以直接填入 Cloudflare API Token 字段，或者导出环境变量 CF_API_TOKEN="你的Token"。

---

## 脚本功能菜单

执行脚本后，会显示以下菜单：

1. 安装并配置 Caddy (含证书申请)

2. Caddy 服务管理 / 日志（启动/停止/重启/日志/查看配置/证书查看）

3. 卸载 Caddy

4. 退出

根据提示输入数字选择对应操作。

---

## 安装流程说明

1. 系统与依赖检测
  自动识别 Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine 等主流系统，检查 curl、lsof、host、gnupg、tar 等工具是否安装，缺失则自动安装。

2. 域名解析检测
  检查域名是否解析到当前服务器 IP，若未解析，会提示用户确认是否继续。

3. 端口检查
  检测 80/443 端口是否可用，自动决定证书申请方式。

4. 生成 Caddyfile
  根据用户输入的域名、邮箱、反向代理目标和 Cloudflare Token 自动生成配置文件。
  * 使用 Cloudflare Token → DNS-01 验证
  * 80/443 可用 → HTTP-01
  * 仅 443 可用 → TLS-ALPN-01
  * 80/443 均被占用 → 提示失败并要求使用 DNS-01
5. 证书申请与启动 Caddy
  * 写入 /etc/caddy/Caddyfile，验证配置并启动 Caddy。
  * 脚本会循环等待证书生成，并提示成功。

---

## 配置示例

Caddyfile 示例：

```caddyfile
{
    storage file_system /var/lib/caddy
    log {
        output file /var/log/caddy/access.log
    }
}

nameserver.example.com {
    encode gzip
    reverse_proxy 127.0.0.1:8888 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Port {server_port}
    }
    tls admin@mail.com
}
```

---

## 系统兼容性

* Debian / Ubuntu / Kali（apt）
* CentOS / RHEL / AlmaLinux / Rocky Linux（yum + copr）
* Fedora（dnf + copr）
* Alpine Linux（apk）
* 其他系统：自动从 GitHub Release 下载预编译二进制
* 支持架构：amd64 / arm64 / armv7
* 需要 root 或 sudo 权限执行

---

## 注意事项

* 若 80/443 端口被占用，自动申请证书可能失败，可提供 Cloudflare Token 使用 DNS-01 方式。

* 证书文件默认存放在 /var/lib/caddy/.local/share/caddy/certificates。

* Cloudflare API Token 输入时不回显，通过独立 EnvironmentFile（/etc/caddy/caddy.env，权限 0640）加载，不会明文写入 systemd 服务文件。

---

## 卸载命令

执行脚本选择"卸载 Caddy"，或手动执行：

```bash
sudo systemctl stop caddy
sudo systemctl disable caddy
sudo rm -f /etc/systemd/system/caddy.service
sudo rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
sudo rm -f /usr/bin/caddy /usr/local/bin/caddy
sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
sudo rm -f /usr/share/keyrings/caddy-archive-keyring.gpg
sudo apt remove --purge -y caddy 2>/dev/null || true
sudo systemctl daemon-reload
```

---

## 开源协议

MIT License，详情请见 [LICENSE](LICENSE)。

---

## 联系作者

GitHub: https://github.com/qianhu111

欢迎提交 Issue 或 PR 贡献改进。
