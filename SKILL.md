---
name: YGVPN
description: >
  基于甬哥 yonggekkk/sing-box-yg 二次开发的全自动部署指南。原项目: https://github.com/yonggekkk/sing-box-yg
  Use when the user asks to deploy sing-box, set up a VPN/VPS proxy node, configure Vless/Hysteria2/Tuic5/Vmess protocols, set up local IP subscriptions, Argo tunnels, domain split routing, or push node subscriptions to Telegram.
---

# YGVPN — Sing-box VPN 部署流程

## 文件总览

| 文件 | 用途 |
|------|------|
| `SKILL.md` | 本文件 — 完整部署指南 + 管道命令速查 |
| `cleanup.sh` | 独立清理脚本，7 步清理 + 4 项自动验证 |
| `deploy.py` | 一键全流程部署，含 SSH + Argo 轮询 + 错误检查 |
| `verify.sh` | 部署后验证（进程/端口/Argo/订阅/域名分流） |
| `config.example.yaml` | 配置模板（IP、域名、TG 凭据等可配置项） |

## 第零步：彻底清除旧安装

推荐方式 — 使用独立清理脚本：

```bash
# 交互式（需确认）
bash cleanup.sh

# 非交互式（跳过确认）
bash cleanup.sh --force
```

等价的手动清理命令（当无法传输脚本时使用）：

```bash
# 1. 停止并禁用服务
systemctl stop sing-box cloudflared cloudflared-update.timer 2>/dev/null
systemctl disable sing-box cloudflared cloudflared-update.service cloudflared-update.timer 2>/dev/null

# 2. 杀死 sb 相关进程（不影响永久隧道）
pkill -9 -f sing-box 2>/dev/null
pkill -9 -f 'cloudflared.*tunnel.*url.*localhost' 2>/dev/null
pkill -9 busybox 2>/dev/null

# 3. 清理 crontab
(crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb') | crontab - 2>/dev/null

# 4. 删除 systemd unit 文件
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service /etc/systemd/system/cloudflared-update.service /etc/systemd/system/cloudflared-update.timer
systemctl daemon-reload

# 5. 删除 sb 相关目录（保留 /opt/cloudflared 永久隧道）
rm -rf /etc/s-box /usr/bin/sb /root/websbox

# 6. 清理 iptables
iptables -t nat -D PREROUTING -p udp --dport 40000:41000 -j DNAT --to-destination :34682 2>/dev/null
iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null

# 7. 清理 nftables
nft delete table inet sing-box 2>/dev/null
```

**清理后验证：**
```bash
# 以下命令应全部为空/报不存在
systemctl status sing-box 2>&1 | grep -q 'could not be found' && echo 'sing-box: 已清除'
[ ! -d /etc/s-box ] && echo '/etc/s-box: 已清除'
crontab -l 2>/dev/null | grep -E 'sing-box|cloudflared|argo' || echo 'crontab: 已清除'
ps aux | grep -E 'sing-box|cloudflared.*tunnel.*url' | grep -v grep || echo '进程: 已清除'
```


## 第一步：安装 sing-box

```bash
bash <(wget -qO- https://raw.githubusercontent.com/ccAzy/sing-box-yg/main/sb.sh)
```

进入主菜单后，选 `1` 安装。管道自动化：

```bash
printf "1\n" | bash <(wget -qO- https://raw.githubusercontent.com/ccAzy/sing-box-yg/main/sb.sh)
```

**安装后验证：**
```bash
which sb && [ -d /etc/s-box ] && echo "安装成功" || echo "安装失败"
```

## 第二步：开启 BBR 加速

```
主菜单输入: 11
```

管道方式：`printf "11\n1\n" | sb`（选最新内核版本）

## 第三步：节点配置

以下全部在 `sb` 主菜单中操作。**每步完成后建议做校验。** 失败则终止后续步骤。

### 3.1 本地 IP 订阅链接（菜单路径：`3` → `8` → `1`）

```
主菜单输入: 3
子菜单输入: 8
再输入: 1
```

管道方式：`printf "3\n8\n1\n\n\n" | sb`

**验证：** 订阅端口和 Token 分别记录在 `/etc/s-box/subport.log` 和 `/etc/s-box/subtoken.log`
```bash
[ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ] && echo "订阅配置成功" || echo "订阅配置失败"
```

### 3.2 Hysteria2 范围端口（菜单路径：`4` → `3` → `2`）

```
主菜单输入: 4
子菜单输入: 3
再输入: 2
```

输入端口范围 `40000:41000`，然后 `0` 退出。管道方式：`printf "4\n3\n2\n40000:41000\n0\n" | sb`

### 3.3 Argo 临时隧道（菜单路径：`3` → `3` → `1` → `1`）

```
主菜单输入: 3
子菜单输入: 3
再输入: 1
再输入: 1
```

管道方式：`nohup bash -c 'printf "3\n3\n1\n1\n" | sb' > /dev/null 2>&1 &`

**关键**：cloudflared 注册隧道需要 15-30 秒（DNS 预检 + QUIC + 注册），必须用 `nohup` 防止 SSH 会话断开时子进程被杀。

**轮询等待（推荐，替代固定 sleep 30）：**
```bash
for i in $(seq 1 20); do
    sleep 3
    grep -q 'trycloudflare.com' /etc/s-box/argo.log 2>/dev/null && echo "Argo 就绪 ($((i*3))s)" && break
    [ $i -eq 20 ] && echo "Argo 超时"
done
grep 'trycloudflare.com' /etc/s-box/argo.log
```

若管道方式不稳定，可手动操作：
1) 杀旧进程：`pkill -f 'cloudflared.*tunnel.*url.*localhost'`
2) 取 VMess 端口：`ss -tlnp | grep sing-box | head -1 | awk '{print $4}' | cut -d: -f2`
3) 启动：`nohup /etc/s-box/cloudflared tunnel --url http://localhost:<PORT> --edge-ip-version auto --no-autoupdate --protocol http2 > /etc/s-box/argo.log 2>&1 &`

若无 cloudflared 二进制：
```bash
curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /etc/s-box/cloudflared && chmod +x /etc/s-box/cloudflared
```

### 3.4 域名分流（菜单路径：`5` → `2` → `1`）

```
主菜单输入: 5
子菜单输入: 2
再输入: 1
```

输入分流域名（空格分隔），走 WARP-IPv6 通道：

```
google.com youtube.com gmail.com googleapis.com blogspot.com chatgpt.com claude.ai gemini.google.com openai.com perplexity.ai netflix.com disneyplus.com spotify.com hulu.com hbomax.com github.com gitlab.com stackoverflow.com docker.com npmjs.com twitter.com x.com facebook.com instagram.com reddit.com discord.com t.me wikipedia.org medium.com quora.com patreon.com twitch.tv
```

管道方式：`printf "5\n2\n1\n<域名列表空格分隔>\n" | sb`

## 第四步：TG 推送（仅订阅链接）

> **注意：不要走 `sb → 3 → 5 → 1` 菜单，它会自动推送全部单个节点链接。直接创建精简 sbtg.sh。**

从 `/etc/s-box/subport.log` 和 `/etc/s-box/subtoken.log` 读取端口和 Token，替换模板中的 `SERVER_IP`、`SUBPORT`、`SUBTOKEN`，写入 `/etc/s-box/sbtg.sh`：

```bash
#!/bin/bash
TOKEN="__TG_BOT_TOKEN__"
CHAT_ID="__TG_CHAT_ID__"
URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

CLASH_URL="http://SERVER_IP:SUBPORT/SUBTOKEN/clmi.yaml"
SINGBOX_URL="http://SERVER_IP:SUBPORT/SUBTOKEN/sbox.json"
JH_URL="http://SERVER_IP:SUBPORT/SUBTOKEN/jhsub.txt"

msg="节点订阅链接

Clash / Mihomo:
${CLASH_URL}

Sing-box:
${SINGBOX_URL}

通用聚合:
${JH_URL}"

timeout 20s curl -s -X POST "$URL" -d chat_id="$CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$msg"
```

> ⚠️ 将 `__TG_BOT_TOKEN__` 和 `__TG_CHAT_ID__` 替换为实际值。Token 等凭据不要提交到 Git。

执行推送：`bash /etc/s-box/sbtg.sh`

## 第五步：部署后验证

```bash
# 使用独立验证脚本
SERVER_IP="<服务器IP>" bash verify.sh

# 或手动逐项检查
# 进程
ps aux | grep sing-box | grep -v grep && echo "进程 OK"

# 端口
ss -tlnp | grep sing-box && echo "端口 OK"

# Argo
grep trycloudflare.com /etc/s-box/argo.log && echo "Argo OK"

# 订阅可访问性
SUBPORT=$(cat /etc/s-box/subport.log)
SUBTOKEN=$(cat /etc/s-box/subtoken.log)
curl -s -o /dev/null -w '%{http_code}' "http://<IP>:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
```

## 管道命令速查

| 步骤 | printf 管道 | 校验 |
|------|------------|------|
| 清理 | `bash cleanup.sh --force` 或手动执行上方清理脚本 | `[ ! -d /etc/s-box ]` |
| 安装 | `printf "1\n" \| bash <(wget -qO- sb.sh)` | `which sb` |
| BBR | `printf "11\n1\n" \| sb` | 重启后检查 `sysctl net.ipv4.tcp_congestion_control` |
| 订阅 | `printf "3\n8\n1\n\n\n" \| sb` | `[ -f /etc/s-box/subport.log ]` |
| Hysteria2 | `printf "4\n3\n2\n40000:41000\n0\n" \| sb` | `ss -ulnp \| grep 34682` |
| Argo | `nohup bash -c 'printf "3\n3\n1\n1\n" \| sb' &` → 轮询等待 | `grep trycloudflare /etc/s-box/argo.log` |
| 域名分流 | `printf "5\n2\n1\n域名列表\n" \| sb` | `[ -f /etc/s-box/sbwpph.json ]` |
| TG 推送 | 直接写入 sbtg.sh 并执行 | TG 收到消息 |

## 一键部署（推荐）

当需要快速部署新服务器时：

```bash
# 全流程
python deploy.py <服务器IP>

# 跳过清理（升级/修复场景）
python deploy.py <服务器IP> --skip-cleanup

# 跳过 BBR（已开启过的机器）
python deploy.py <服务器IP> --skip-bbr

# 启用 TG 自动推送
TG_TOKEN="xxx" TG_CHAT_ID="yyy" python deploy.py <服务器IP>
```

## 多服务器批量部署

参考 `deploy_all.py`（在上级 VPN 目录），通过 paramiko 批量 SSH 执行，支持并发多台服务器。

```python
# 精简示例
servers = {"hk": "1.2.3.4", "vn": "5.6.7.8", ...}
for name, ip in servers.items():
    deploy_one(name, ip)  # 执行完整部署流程
```
