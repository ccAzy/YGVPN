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
MIRROR=""
for a in "$@"; do [[ "$a" == "--mirror" ]] && MIRROR="https://ghproxy.com/" && break; done
[ -n "$MIRROR" ] && info "使用 ghproxy 镜像加速"
# ────────────────────────────────────────────────────────────────
MIRROR=""
[[ "${1:-}" == "--mirror" ]] || [[ "${2:-}" == "--mirror" ]] && MIRROR="https://ghproxy.com/" && info "使用 ghproxy 镜像加速"
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
    step 2 "BBR 加速 + 内核检查"
    KVER=$(uname -r | sed "s/-.*//" | cut -d. -f1,2)
    KMAJOR=$(echo $KVER | cut -d. -f1)
    KMINOR=$(echo $KVER | cut -d. -f2)

    # 检查是否需要升级内核 (BBRv3 需要 >= 6.12)
    if [ "$KMAJOR" -ge 7 ] || { [ "$KMAJOR" -eq 6 ] && [ "$KMINOR" -ge 12 ]; }; then
        info "内核 $KVER 已支持 BBRv3，直接开启..."
    else
        # 检查 /boot 是否已有新内核（装了没重启）
        NEWEST=$(ls /boot/vmlinuz-* 2>/dev/null | sed "s/.*vmlinuz-//" | sort -V | tail -1 | sed "s/-.*//")
        NEWEST_VER=$(echo $NEWEST | cut -d. -f1,2 2>/dev/null)
        if [ -n "$NEWEST_VER" ] && [ "$NEWEST_VER" != "$KVER" ]; then
            warn "已安装新内核但未重启！当前: $KVER, 已装: $NEWEST"
            warn "请 reboot 后生效，跳过重复安装"
        else
            warn "内核 $KVER 较旧 (仅 BBRv1)，尝试升级..."
        source /etc/os-release 2>/dev/null
        if [ "$ID" = "debian" ]; then
            DEB_VER=$(cat /etc/debian_version 2>/dev/null | cut -d. -f1)
            if [ "$DEB_VER" -ge 12 ]; then
                info "Debian $DEB_VER，从 backports 安装内核..."
                apt install -y -t ${VERSION_CODENAME}-backports linux-image-amd64 2>/dev/null && ok "内核已安装，重启后生效" || warn "内核升级失败"
            else
                info "Debian $DEB_VER (较旧)，尝试 Liquorix 内核..."
                curl -s https://liquorix.net/add-liquorix-repo.sh 2>/dev/null | bash 2>/dev/null
                apt install -y linux-image-liquorix-amd64 2>/dev/null && ok "Liquorix 安装成功，重启后生效" || warn "内核升级失败 — 考虑升级到 Debian 12+"
            fi
        elif [ "$ID" = "ubuntu" ]; then
            UB_VER=$(echo "$VERSION_ID" | cut -d. -f1)
            if [ "$UB_VER" -ge 20 ]; then
                info "Ubuntu $UB_VER，安装 Liquorix 内核..."
                curl -s https://liquorix.net/add-liquorix-repo.sh 2>/dev/null | bash 2>/dev/null
                apt install -y linux-image-liquorix-amd64 2>/dev/null && ok "内核已安装，重启后生效" || warn "内核升级失败"
            else
                warn "Ubuntu $UB_VER 太旧 (需 20.04+)，无法自动升级内核"
                warn "请手动升级系统或换用 Debian 12 / Ubuntu 22.04+"
            fi
        elif [ "$ID" = "centos" ] || [ "$ID" = "rhel" ] || [ "$ID" = "rocky" ] || [ "$ID" = "almalinux" ]; then
            info "RHEL 系，从 ELRepo 安装最新内核..."
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null
            rpm -Uvh https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm 2>/dev/null || rpm -Uvh https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm 2>/dev/null
            dnf --enablerepo=elrepo-kernel install -y kernel-ml 2>/dev/null || yum --enablerepo=elrepo-kernel install -y kernel-ml 2>/dev/null && ok "内核已安装，重启后生效" || warn "内核升级失败"
        elif [ "$ID" = "fedora" ]; then
            info "Fedora 系统内核通常已足够新，跳过升级"
        fi
        fi  # close 'already new kernel' check
    fi

    # 开启 BBR — 三层保证
    # 1. 确保模块加载 (某些定制内核可能未自动加载)
    modprobe tcp_bbr 2>/dev/null || true
    # 2. 立即生效 (不依赖配置文件)
    sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 || true
    # 3. 持久化 (写入配置文件)
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    # 4. 验证
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        ok "BBR 已启用"
    else
        warn "BBR 未生效 — 试试 modprobe tcp_bbr && sysctl -w net.ipv4.tcp_congestion_control=bbr"
    fi
fi

# ────────────────────────────────────────────────────────────────
# Step 2.5: 网络暴力优化
step 2.5 "网络暴力优化"
# 备份现有配置
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s) 2>/dev/null
cat >> /etc/sysctl.conf << 'SYSCTL'
# YGVPN 网络暴力优化

# ── TCP 拥塞 ──
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# ── 缓冲区（暴力，不缩） ──
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ── TCP 连接暴力优化 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = 16384

# ── 连接队列 ──
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 20000
net.core.netdev_budget = 2400

# ── 端口范围 ──
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = 65536

# ── 连接跟踪（拉满） ──
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 5

# ── VM 优化 ──
vm.swappiness = 5
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 65536

# ── 文件描述符 ──
fs.file-max = 2097152
fs.nr_open = 2097152

# ── 安全（不影响性能） ──
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
SYSCTL

# 应用
sysctl -p > /dev/null 2>&1

# 透明大页关闭（减延迟）
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# 文件描述符限制
grep -q "# YGVPN" /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf << 'LIMITS'
# YGVPN 网络优化
* soft nofile 2097152
* hard nofile 2097152
root soft nofile 2097152
root hard nofile 2097152
LIMITS

# 验证
echo "TCP: $(sysctl -n net.ipv4.tcp_congestion_control)  FastOpen: $(sysctl -n net.ipv4.tcp_fastopen)  BBR idle: $(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
ok "网络暴力优化完成"
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

nohup bash -c 'printf "4
3
2
40000:41000
0
" | sb' > /dev/null 2>&1 &

sleep 15

# 同时检查 iptables 和 nftables（新系统可能用 nft）

if iptables -t nat -L PREROUTING 2>/dev/null | grep -q '40000'; then

    ok "Hysteria2 已配置 (iptables)"

elif nft list ruleset 2>/dev/null | grep -q '40000'; then

    ok "Hysteria2 已配置 (nftables)"

else

    warn "Hysteria2 可能未生效，稍后可手动检查: iptables -t nat -L PREROUTING | grep 40000"

fi

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
# 检测 IPv6（WARP 不需要原生 IPv6，但提示用户）

IPV6_ADDR=$(curl -s6 ifconfig.me 2>/dev/null || echo "")

if [ -n "$IPV6_ADDR" ]; then

    info "检测到 IPv6: $IPV6_ADDR"

else

    info "无原生 IPv6（WARP 会通过 IPv4 建立隧道，不影响使用）"

fi

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
