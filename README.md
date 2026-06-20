<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-orange" alt="platform">
</p>

<h1 align="center">YGVPN</h1>
<p align="center"><strong>sing-box 一键部署 · 7 种节点 · Argo 隧道 · 域名分流</strong></p>
  🎖️ 基于甬哥 [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) 二次开发，特此感谢！
<p align="center">一行命令，3 分钟，全自动。</p>

---

## ✨ 特性

- 🚀 **一行部署** — SSH 粘贴即用，无需 Python 环境
- 🧩 **7 种节点** — VLESS / VMess×3 / Hysteria2 / Tuic5 + 聚合订阅
- 🌐 **Argo 隧道** — 自动轮询等待 + Cloudflare CDN 穿透
- 📡 **域名分流** — 30+ 境外站点走 WARP-IPv6
- 🧹 **智能清理** — 部署前自动清除旧安装残留
- ✅ **自动验证** — 进程 / 端口 / Argo / 订阅全检查
- 📱 **TG 推送** — 可选，订阅链接一键发送到手机
- 🤖 **AI 友好** — `--server all` 批量部署，支持 AI Agent 调用

---

## 🧑‍💻 给个人用户（手动部署）

### 你需要什么

| 条件 | 说明 |
|------|------|
| 一台 VPS | Ubuntu 22.04 / Debian 11+，root 权限 |
| SSH 客户端 | FinalShell / Termius / 终端 任意 |
| 网络 | 服务器能访问 GitHub（国内机可能需要代理） |

### 操作步骤

**第 1 步** — SSH 登录你的 VPS：

```bash
ssh root@你的服务器IP
```

**第 2 步** — 复制粘贴这一行，回车：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh)
```

**第 3 步** — 等待 3-5 分钟，终端打印出订阅链接：

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
  ──────────────────────────────────────────
```

**第 4 步** — 复制订阅链接，粘贴到 Clash Verge / Sing-box / V2Ray 等客户端，完成。

```bash
# 可选：跳过 BBR（已开过的机器）
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh) --skip-bbr

# 可选：重装（先清理再部署）
bash cleanup.sh --force
bash deploy_standalone.sh
```

---

## 🤖 给 AI 工具（自动化 / 批量）

配置一次，之后一条命令搞定任意数量服务器。

### 你需要准备
## 🤖 给 AI 工具（自动化 / 批量）

配置一次，之后一条命令搞定任意数量服务器。



### 第 1 步 — 创建服务器配置文件



在 `deploy.py` 同级目录下新建一个文件，取名 `servers.json`（纯文本 JSON），写入你的服务器信息：



```json

{

  "servers": {

    "jp":  { "ip": "1.2.3.4",  "port": 22,   "user": "root", "password": "你的密码" },

    "hk":  { "ip": "5.6.7.8",  "port": 6688, "user": "root", "password": "你的密码" },

    "us":  { "ip": "9.10.11.12","port": 22,   "user": "root", "password": "你的密码" }

  }

}

```



> `"jp"` `"hk"` `"us"` 是你自己起的服务器名字，数量不限。对应 `--server jp` 中的 `jp`。



### 第 2 步 — 安装依赖



```bash

pip install paramiko

```



### 第 3 步 — 部署



```bash

python deploy.py --server jp          # 部署单台

python deploy.py --server all         # 部署 servers.json 里全部服务器

python deploy.py --server hk --skip-cleanup --skip-bbr  # 升级/修复

TG_TOKEN=xxx TG_CHAT_ID=yyy python deploy.py --server jp  # 部署后推送到 Telegram

```



### 交给 AI Agent（Reasonix / Codex / Cursor 等）



直接把整个仓库目录给 AI，然后说：



> "用 YGVPN 给我的 servers.json 里所有服务器部署 sing-box"



AI 会读取 `SKILL.md` 里的完整部署指南自动执行。你需要提前准备好 `servers.json`（按上面格式）。



---

## 📦 仓库文件

| 文件 | 用途 | 适用 |
|------|------|------|
| `deploy_standalone.sh` | 一行 curl 部署 | 🧑‍💻 个人 |
| `deploy.py` | 批量 / 自动化部署 | 🤖 AI |
| `cleanup.sh` | 彻底清除 sing-box 残留 | 通用 |
| `verify.sh` | 部署后 6 项验证 | 通用 |
| `SKILL.md` | AI Agent 管道速查指南 | 🤖 AI |
| `config.example.yaml` | 配置模板参考 | 通用 |

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
| `Sing-box / Clash 聚合订阅` | 客户端一键导入全部节点 |

---

## 🙋 常见问题

**Q: 部署失败怎么办？**
```bash
bash cleanup.sh --force        # 先彻底清理
bash deploy_standalone.sh      # 重新部署
```

**Q: 如何更新节点配置？**
```bash
python deploy.py --server jp --skip-cleanup --skip-bbr
```

**Q: 支持哪些系统？**
Ubuntu 22.04 / Debian 11+。CentOS 未测试。

**Q: YGVPN 和 sing-box 是什么关系？**

**Q: YGVPN 和 sing-box 是什么关系？**


YGVPN 是基于甬哥 [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) 的二次开发项目：



| 项目 | 角色 |

|------|------|

| [sing-box](https://github.com/SagerNet/sing-box) | 核心代理引擎 |

| [sing-box-yg](https://github.com/yonggekkk/sing-box-yg)（甬哥） | 🎖️ **原作者**，一键安装脚本 + 交互式菜单 |

| [ccAzy/sing-box-yg](https://github.com/ccAzy/sing-box-yg) | 本项目的 fork，用于稳定性锁定 |

| **YGVPN**（本项目） | 全自动包装：替人点菜单、轮询等待、错误处理、批量部署 |



一句话：**YGVPN = sing-box-yg 的无人值守版。**



> 💝 特别感谢甬哥 [yonggekkk](https://github.com/yonggekkk) 开发的 sing-box-yg，本项目在其基础上进行自动化改造。

## 🔒 安全

- 凭据在外部 `servers.json`，不入库
- Token 通过环境变量传入
- 仓库**零密钥、零 IP、零隐私** ✅ 可公开

---

<p align="center">
  <sub>MIT License · 原作者 <a href="https://github.com/yonggekkk/sing-box-yg">yonggekkk/sing-box-yg</a> · Fork <a href="https://github.com/ccAzy/sing-box-yg">ccAzy/sing-box-yg</a></sub>
</p>
