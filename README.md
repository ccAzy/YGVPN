<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/platform-Linux%20(systemd)-orange" alt="platform">
  <img src="https://img.shields.io/badge/kernel-%3E%3D6.12%20BBRv3-blue" alt="kernel">
</p>

<h1 align="center">YGVPN</h1>
<p align="center"><strong>sing-box 一键部署 · 7 种节点 · Argo 隧道 · 域名分流 · 内核级网络优化</strong></p>
<p align="center">🎖️ 基于甬哥 <a href="https://github.com/yonggekkk/sing-box-yg">yonggekkk/sing-box-yg</a> 二次开发，特此感谢！</p>
<p align="center">一行命令，3 分钟，全自动。</p>

---

## ✨ 特性

- 🚀 **一行部署** — SSH 粘贴即用，无需 Python
- 🧩 **7 种节点** — VLESS / VMess×3 / Hysteria2 / Tuic5 + 聚合订阅
- 🌐 **Argo 隧道** — 自动轮询 + Cloudflare CDN 穿透
- 📡 **域名分流** — 30+ 境外站点走 WARP-IPv6
- ⚡ **内核级网络优化** — BBRv3 + ECN + RSS/RPS 全核均衡 + MSS Clamp + IPv4 优先
- 📊 **可选检测** — IP 纯净度 (流媒体/AI解锁) + VPS 出口带宽测速
- 🧹 **智能清理** — 部署前自动清除旧残留
- ✅ **自动验证** — 进程 / 端口 / Argo / 订阅全检查
- 📱 **TG 推送** — 可选，订阅链接一键发到手机
- 🤖 **AI 友好** — `--server all` 批量部署
- 🪞 **国内加速** — `--mirror` 走 ghproxy，解决 GitHub 下载慢

---

## 🧑‍💻 个人用户（手动部署）

### 你需要什么

| 条件 | 说明 |
|------|------|
| 一台 VPS | Linux + systemd（详见[支持的系统](#-支持的系统)），**root 权限** |
| SSH 客户端 | FinalShell / Termius / 终端均可 |
| 网络 | 服务器能访问 GitHub（国内机加 `--mirror`） |

### 操作步骤

**①** SSH 登录：

```bash
ssh root@你的服务器IP
```

**②** 粘贴运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh)
```

> 🪞 **国内服务器加 `--mirror` 加速**：
> ```bash
> bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh) --mirror
> ```

**③** 等待 3~5 分钟，终端打印出订阅链接，复制到客户端即可。

**④ 部署完成后会依次询问 3 个可选步骤（回车跳过）：**

| 可选步骤 | 说明 |
|---------|------|
| **Telegram 推送** | 输入 Bot Token + Chat ID，订阅链接推送到手机 |
| **流媒体与AI解锁检测** | 检测 Netflix/Disney+/YouTube Premium/ChatGPT/Claude/Gemini 可访问性 |
| **出口带宽测速** | speedtest-cli 测速，失败则用 cachefly 10MB 下载兜底 |

<details>
<summary>📺 点击展开部署输出示例</summary>

```
╔══════════════════════════════════════════════════╗
║                    🎉 部署完成！                  ║
╚══════════════════════════════════════════════════╝

  📡 订阅链接 (复制到客户端):
  ──────────────────────────────────────────
  Clash / Mihomo:
    http://你的IP:端口/Token/clmi.yaml
  Sing-box:
    http://你的IP:端口/Token/sbox.json
  通用聚合:
    http://你的IP:端口/Token/jhsub.txt
  ──────────────────────────────────────────
```
</details>

**⑤ 额外选项：**

```bash
# 跳过 BBR（已开过的机器）
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh) --skip-bbr

# 更新节点（不清除旧配置）
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh) --skip-cleanup
```

---

## 🤖 AI / 批量部署

配置一次，之后一条命令搞定所有服务器。

### 你需要准备

| 条件 | 说明 |
|------|------|
| Python | 3.8+ |
| paramiko | `pip install paramiko` |
# 可选（Argo 订阅修复需要）：pip install pyyaml
| `servers.json` | 服务器配置文件（格式见下方） |

### 第 1 步 — 创建 `servers.json`

在 `deploy.py` 同级目录新建，写入你的服务器信息：

```json
{
  "servers": {
    "jp":  { "ip": "1.2.3.4",   "port": 22, "user": "root", "password": "你的密码" },
    "hk":  { "ip": "5.6.7.8",   "port": 22, "user": "root", "password": "你的密码" },
    "us":  { "ip": "9.10.11.12", "port": 22, "user": "root", "password": "你的密码" }
  }
}
```

| 字段 | 含义 | 示例 |
|------|------|------|
| `"jp"` `"hk"` `"us"` | **服务器昵称**，随便取，数量不限 | 中英文均可 |
| `"ip"` | **公网 IP** | `"1.2.3.4"` |
| `"port"` | **SSH 端口**，默认 22 | `22` |
| `"user"` | **SSH 用户名**，一般 root | `"root"` |
| `"password"` | **SSH 密码** | `"你的密码"` |

> ⚠️ **文件含明文密码，绝对不要提交到 Git！** 放 `.gitignore` 或仓库外。

### 第 2 步 — 部署

```bash
pip install paramiko
# 可选（Argo 订阅修复需要）：pip install pyyaml

python deploy.py --server jp          # 单台
python deploy.py --server all         # 全部
python deploy.py --server hk --skip-cleanup --skip-bbr  # 升级
TG_TOKEN=xxx TG_CHAT_ID=yyy python deploy.py --server jp  # +TG推送
```

### 交给 AI Agent

把仓库给 AI，说一句：

> "用 YGVPN 给我的 servers.json 里所有服务器部署 sing-box"

AI 会读 `SKILL.md` 自动执行。你只需要提前准备好 `servers.json`。

---

## 📦 仓库文件

| 文件 | 用途 |
|------|------|
| `deploy_standalone.sh` | 🧑‍💻 人类 paste 一键部署（含全部优化） |
| `deploy.py` | 🤖 Python 批量部署 |
| `cleanup.sh` | 彻底清除残留 |
| `verify.sh` | 部署后验证 |
| `SKILL.md` | AI Agent 部署指南 |
| `config.example.yaml` | 配置模板 |

---

## ⚡ 内核级网络优化详情

部署脚本内置以下 TCP/UDP 深度调优（参考 [tcp-dashboard](https://github.com/666shen/tcp-dashboard)）：

| 优化项 | 作用 |
|--------|------|
| **BBRv3** | 次世代拥塞控制，跨境丢包链路的吞吐显著提升 |
| **ECN** (`tcp_ecn=1`) | 拥塞时打标记不丢包，平滑网络抖动 |
| **RSS/RPS 全核均衡** | 解绑单核软中断瓶颈，大并发平摊所有 CPU 核心 |
| **MSS Clamp** | 防止 PMTU 黑洞导致连接超时断流 |
| **IPv4 优先解析** | 避免 IPv6 绕路导致 TCP 握手卡顿 |
| **somaxconn=65535** | 连接队列拉满，支撑 6w+ 高并发 |
| **tcp_fastopen=3** | TCP 快速打开，减少握手 RTT |
| **nf_conntrack 拉满** | 连接跟踪表扩容，防止 conntrack table full |
| **透明大页关闭** | 降低内存分配延迟 |

---

## 📡 部署后你会得到

| 协议 | 说明 |
|------|------|
| `VLESS + Reality + Vision` | 直连最优 |
| `VMess + WebSocket` | 基础 WS |
| `VMess + WebSocket + TLS` | WS + 加密 |
| `VMess + WebSocket + Argo` | CDN 隧道穿透 |
| `Hysteria2` | UDP 暴力加速 + 端口跳跃 |
| `Tuic5` | 高性能 UDP |
| `Sing-box / Clash 聚合` | 客户端一键导入 |

---

## 🔄 部署流程

```
清理 ──► 安装 ──► BBRv3+内核升级 ──► 网络暴力优化(ECN/RSS/MSS/IPv4) ──► 订阅 ──► Hysteria2 ──► Argo ──► 域名分流 ──► 验证 ──► TG推送(可选) ──► IP检测(可选) ──► 测速(可选)
```

---

## 💻 支持的系统

| 系统 | 最低版本 | 备注 |
|------|----------|------|
| Ubuntu | 18.04 | ✅ 推荐 |
| Debian | 10 | ✅ |
| CentOS / Rocky / Alma | 7 | ✅ |
| Fedora | 36 | ✅ |

> ⚠️ **必须 systemd + bash + iptables/nftables**。OpenVZ / LXC / Alpine(openrc) 不支持。

---

## 🙋 常见问题

**Q: 部署失败怎么办？**

先彻底清理再重试：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/cleanup.sh) --force
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh)
```

**Q: 如何更新节点配置？**

```bash
python deploy.py --server jp --skip-cleanup --skip-bbr
```

**Q: BBR 那步要多久？**

脚本自动检测内核版本：
- 内核 ≥ 6.12 → **秒开** BBRv3 + ECN
- 内核 < 6.12 → 自动升级内核（Debian backports / Ubuntu Liquorix / RHEL ELRepo）
- 已装新内核但未重启 → 跳过重复安装，提示 reboot

升级后需重启生效。

**Q: WARP 需要服务器有 IPv6 吗？**

**不需要。** WARP 通过 IPv4 建 WireGuard 隧道到 Cloudflare，隧道那头自带 IPv6。

**Q: 流媒体检测准吗？**

基于 HTTP 状态码探测 Netflix/Disney+/YouTube/ChatGPT/Claude/Gemini 端点，安全无第三方脚本执行。检测结果仅供参考，精确解锁状态建议运行 `bash <(curl -L -s check.unlock.media)`。

**Q: 测速消耗流量吗？**

speedtest-cli 约消耗 50-100MB；cachefly 兜底测试仅下载 10MB。部署脚本默认不跑，需手动确认 y。

**Q: YGVPN 和 sing-box 是什么关系？**

| 项目 | 角色 |
|------|------|
| [sing-box](https://github.com/SagerNet/sing-box) | 核心代理引擎 |
| [sing-box-yg](https://github.com/yonggekkk/sing-box-yg)（甬哥） | 🎖️ **原作者**，安装脚本 + 交互菜单 |
| [ccAzy/sing-box-yg](https://github.com/ccAzy/sing-box-yg) | 本项目 fork，锁定版本 |
| **YGVPN** | 全自动包装：替你点菜单、轮询、验证、批量 |

**一句话：YGVPN = sing-box-yg 的无人值守版。**

> 💝 感谢甬哥 [yonggekkk](https://github.com/yonggekkk) 的 [sing-box-yg](https://github.com/yonggekkk/sing-box-yg)！
> 💝 网络优化参考 [tcp-dashboard](https://github.com/666shen/tcp-dashboard)
> 💝 IP检测/测速灵感来自 [proxy-installer](https://github.com/FengZi1221/proxy-installer) + NodeSeek [VPS脚本合集](https://www.nodeseek.com/post-183694-1)

---

---

<p align="center">
  <sub>MIT License · 原作者 <a href="https://github.com/yonggekkk/sing-box-yg">yonggekkk/sing-box-yg</a> · 密码请放 <code>servers.json</code>（不入库）</sub>
</p>
