#!/bin/bash
# ===================================================================
# YGVPN — sing-box VPN 一键部署 (纯 shell，粘贴即用)
#
# 用法:
#   1. SSH 登录服务器
#   2. 复制粘贴下面整段：
#      curl -fsSL https://raw.githubusercontent.com/ccAzy/YGVPN/main/deploy_standalone.sh | bash
#   或:
#      bash deploy_standalone.sh
#   或跳过 BBR:
#      bash deploy_standalone.sh --skip-bbr
# ===================================================================
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1;37m'; N='\033[0m'
ok()   { echo -e "${G}[OK]${N}  $*"; }
warn() { echo -e "${Y}[!]${N}   $*"; }
die()  { echo -e "${R}[FAIL]${N} $*"; exit 1; }
step() { echo -e "\n${C}╔══════════════════════════════════════════════════╗${N}"; echo -e "${C}║  [$1] $2${N}"; echo -e "${C}╚══════════════════════════════════════════════════╝${N}"; }
info() { echo -e "      $*"; }

SKIP_BBR=false
[[ "${1:-}" == "--skip-bbr" ]] && SKIP_BBR=true

# ────────────────────────────────────────────────────────────────
echo -e "${B}"
echo "  ██╗   ██╗ ██████╗ ██╗   ██╗██████╗ ███╗   ██╗"
echo "  ╚██╗ ██╔╝██╔════╝ ██║   ██║██╔══██╗████╗  ██║"
echo "   ╚████╔╝ ██║  ███╗██║   ██║██████╔╝██╔██╗ ██║"
echo "    ╚██╔╝  ██║   ██║██║   ██║██╔═══╝ ██║╚██╗██║"
echo "     ██║   ╚██████╔╝╚██████╔╝██║     ██║ ╚████║"
echo "     ╚═╝    ╚═════╝  ╚═════╝ ╚═╝     ╚═╝  ╚═══╝"
echo -e "         sing-box VPN One-Click Deploy${N}"
echo ""

# ────────────────────────────────────────────────────────────────
# 环境检测
# ────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s ipv4.icanhazip.com 2>/dev/null || echo "未知")
HOSTNAME=$(hostname)
echo "  服务器: ${HOSTNAME}"
echo "  公网IP: ${SERVER_IP}"
echo ""

# ────────────────────────────────────────────────────────────────
# Step 0: 清理
# ────────────────────────────────────────────────────────────────
step 0 "清理旧安装"

for svc in sing-box cloudflared cloudflared-update; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
systemctl stop cloudflared-update.timer 2>/dev/null || true
systemctl disable cloudflared-update.timer 2>/dev/null || true
pkill -9 -f sing-box 2>/dev/null || true
pkill -9 -f 'cloudflared.*tunnel.*url.*localhost' 2>/dev/null || true
pkill -9 busybox 2>/dev/null || true
(crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb') | crontab - 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service /etc/systemd/system/cloudflared-update.service /etc/systemd/system/cloudflared-update.timer 2>/dev/null
systemctl daemon-reload
rm -rf /etc/s-box /usr/bin/sb /root/websbox
mkdir -p /etc/s-box
iptables -t nat -D PREROUTING -p udp --dport 40000:41000 -j DNAT --to-destination :34682 2>/dev/null || true
iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null || true
nft delete table inet sing-box 2>/dev/null || true
ok "清理完成"

# ────────────────────────────────────────────────────────────────
# Step 1: 安装 sing-box
# ────────────────────────────────────────────────────────────────
step 1 "安装 sing-box (约 1-2 分钟)"

printf "1\n" | bash <(wget -qO- https://raw.githubusercontent.com/ccAzy/sing-box-yg/main/sb.sh) 2>&1 | tail -3
sleep 2

if which sb &>/dev/null && [ -d /etc/s-box ]; then
    ok "sing-box 安装成功"
else
    die "安装失败"
fi

# ────────────────────────────────────────────────────────────────
# Step 2: BBR 加速
# ────────────────────────────────────────────────────────────────
if $SKIP_BBR; then
    warn "跳过 BBR"
else
    step 2 "BBR 加速"
    # 先检查内核是否已支持 BBR（Ubuntu 22.04+ 默认支持）
    if modprobe tcp_bbr 2>/dev/null; then
        # 内核支持，直接 sysctl 开启（秒级）
        grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        BBR=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk -F"= " "{print $2}")
        [[ "$BBR" == *bbr* ]] && ok "BBR 已启用: $BBR (sysctl)" || warn "BBR: $BBR"
    else
        # 旧内核不支持，走 sb 脚本安装新内核（较慢，需重启）
        warn "内核不支持 BBR，使用 sb 安装新内核..."
        printf "11
1
" | sb 2>&1 | tail -3
        warn "内核安装完成，请 reboot 后生效"
    fi
fi

# ────────────────────────────────────────────────────────────────
# Step 3: 订阅链接
# ────────────────────────────────────────────────────────────────
step 3 "配置订阅链接"

nohup bash -c 'printf "3\n8\n1\n\n\n" | sb' > /dev/null 2>&1 &
sleep 8

if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
    SUBPORT=$(cat /etc/s-box/subport.log)
    SUBTOKEN=$(cat /etc/s-box/subtoken.log)
    ok "订阅端口: $SUBPORT   Token: $SUBTOKEN"
    mkdir -p "/root/websbox/${SUBTOKEN}"
    cp /etc/s-box/clmi.yaml /etc/s-box/sbox.json /etc/s-box/jhsub.txt "/root/websbox/${SUBTOKEN}/" 2>/dev/null || true
else
    die "订阅配置失败"
fi

# ────────────────────────────────────────────────────────────────
# Step 4: Hysteria2
# ────────────────────────────────────────────────────────────────
step 4 "Hysteria2 端口跳跃"

nohup bash -c 'printf "4\n3\n2\n40000:41000\n0\n" | sb' > /dev/null 2>&1 &
sleep 10
iptables -t nat -L PREROUTING 2>/dev/null | grep -q '40000' && ok "Hysteria2 已配置" || warn "Hysteria2 可能未生效"

# ────────────────────────────────────────────────────────────────
# Step 5: Argo 隧道
# ────────────────────────────────────────────────────────────────
step 5 "Argo 临时隧道"

# 下载 cloudflared (如果不存在)
if [ ! -x /etc/s-box/cloudflared ]; then
    curl -sL --connect-timeout 30 --max-time 120 \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /etc/s-box/cloudflared && chmod +x /etc/s-box/cloudflared && ok "cloudflared 已下载" \
        || warn "cloudflared 下载失败，尝试使用已有"
fi

# 启动隧道
nohup bash -c 'printf "3\n3\n1\n1\n" | sb' > /dev/null 2>&1 &

# 轮询等待
echo -n "      等待 Argo 注册"
for i in $(seq 1 20); do
    sleep 3
    echo -n "."
    if grep -q 'trycloudflare.com' /etc/s-box/argo.log 2>/dev/null; then
        echo ""
        ok "Argo 已就绪 ($((i*3))s)"
        break
    fi
    [ $i -eq 20 ] && { echo ""; warn "Argo 超时，稍后检查 /etc/s-box/argo.log"; }
done

ARGO_URL=$(grep -oP 'https?://[a-z0-9.-]+\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | tail -1 || echo "")
[ -n "$ARGO_URL" ] && info "Argo URL: $ARGO_URL"

# ────────────────────────────────────────────────────────────────
# Step 6: 域名分流
# ────────────────────────────────────────────────────────────────
step 6 "域名分流 (WARP-IPv6)"

DOMAINS="google.com youtube.com gmail.com googleapis.com blogspot.com chatgpt.com claude.ai gemini.google.com openai.com perplexity.ai netflix.com disneyplus.com spotify.com hulu.com hbomax.com github.com gitlab.com stackoverflow.com docker.com npmjs.com twitter.com x.com facebook.com instagram.com reddit.com discord.com t.me wikipedia.org medium.com quora.com patreon.com twitch.tv"

nohup bash -c "printf '5\n2\n1\n${DOMAINS}\n' | sb" > /dev/null 2>&1 &
sleep 10
ok "域名分流已配置"

# ────────────────────────────────────────────────────────────────
# Step 7: 输出结果
# ────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}║                    🎉 部署完成！                            ║${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  ${B}服务器 IP:${N} ${SERVER_IP}"
echo -e "  ${B}订阅端口:${N} ${SUBPORT}"
echo -e "  ${B}订阅路径:${N} /${SUBTOKEN}/"
echo ""
echo -e "  ${B}📡 订阅链接 (复制到客户端):${N}"
echo "  ──────────────────────────────────────────"
echo -e "  ${G}Clash / Mihomo:${N}"
echo "    http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
echo ""
echo -e "  ${G}Sing-box:${N}"
echo "    http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/sbox.json"
echo ""
echo -e "  ${G}通用聚合:${N}"
echo "    http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/jhsub.txt"
echo "  ──────────────────────────────────────────"
[ -n "$ARGO_URL" ] && echo "" && echo -e "  ${B}🌐 Argo 隧道:${N} ${ARGO_URL}"
echo ""

# ────────────────────────────────────────────────────────────────
# Step 8: Telegram 推送 (可选)
# ────────────────────────────────────────────────────────────────
echo -e "${Y}──────────────────────────────────────────${N}"
echo -e "${Y}  可选: Telegram 推送订阅链接${N}"
echo -e "${Y}──────────────────────────────────────────${N}"
echo "  需要: 1) Bot Token (@BotFather)  2) Chat ID (@userinfobot)"
echo ""
read -p "  输入 Bot Token (回车跳过): " TG_TOKEN
[ -z "$TG_TOKEN" ] && echo "  已跳过" && exit 0  
read -p "  输入 Chat ID: " TG_CHAT_ID
[ -z "$TG_CHAT_ID" ] && echo "  已跳过" && exit 0

CLASH_URL="http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
JH_URL="http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/jhsub.txt"

RESP=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=🔰 节点订阅链接

Clash / Mihomo:
${CLASH_URL}

通用聚合:
${JH_URL}")

if echo "$RESP" | grep -q '"ok":true'; then
    ok "Telegram 推送成功"
else
    warn "推送失败: $RESP"
fi

echo ""
echo -e "${G}全部完成！${N}"
