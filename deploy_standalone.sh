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
# ────────────────────────────────────────────────────────────────
# Step 1: 安装 sing-box
# MIRROR support (应用于 sing-box / cloudflared 等下载)
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
    # tcp-dashboard: ECN + BBRv3
    sysctl -w net.ipv4.tcp_ecn=1 > /dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control_version=3 > /dev/null 2>&1 || true
    ok "ECN + BBRv3 已激活"

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
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_ecn = 1

# ── 连接队列 ──
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
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

# ────────────────────────────────────────────────────────────────
# Step 2.6: IPv4 优先解析 (from tcp-dashboard)
step 2.6 "IPv4 优先解析"
if [ ! -f /etc/gai.conf ]; then
    cat > /etc/gai.conf << GAIEOF
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence  ::/96         20
precedence  ::ffff:0:0/96 10
GAIEOF
fi
grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
ok "IPv4 优先解析已启用"

# ────────────────────────────────────────────────────────────────
# Step 2.7: MSS Clamp (from tcp-dashboard)
step 2.7 "MSS Clamp 智能钳制"
if command -v iptables &>/dev/null; then
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ok "MSS Clamp 已部署"
else
    warn "未找到 iptables，跳过 MSS Clamp"
fi

# ────────────────────────────────────────────────────────────────
# Step 2.8: RSS/RPS 网卡多队列 (from tcp-dashboard)
step 2.8 "RSS/RPS 网卡多队列均衡"
set +e  # 暂时关闭严格模式，避免 ethtool/apt 偶发失败导致脚本退出
if ! command -v ethtool &>/dev/null; then
    info "安装 ethtool..."
    timeout 60 apt-get update -qq 2>/dev/null
    apt-get install -y -qq ethtool 2>/dev/null || yum install -y -qq ethtool 2>/dev/null || true
fi
if command -v ethtool &>/dev/null; then
    interfaces=$(ls /sys/class/net 2>/dev/null | grep -vE "lo|docker|veth|br-|any|tung3|sit0|tun|wg")
    cpu_count=$(nproc)
    rps_cpus=$(printf "%x" $(((1 << cpu_count) - 1)))
    for eth in $interfaces; do
        max_rx=$(ethtool -g "$eth" 2>/dev/null | grep -A5 "Pre-set maximums" | grep "RX:" | awk '{print $2}')
        ethtool -G "$eth" rx "${max_rx:-1024}" tx "${max_rx:-1024}" 2>/dev/null || true
        for rps_file in /sys/class/net/$eth/queues/rx-*/rps_cpus; do
            [ -f "$rps_file" ] && echo "$rps_cpus" > "$rps_file"
        done
        for rfc_file in /sys/class/net/$eth/queues/rx-*/rps_flow_cnt; do
            [ -f "$rfc_file" ] && echo "4096" > "$rfc_file"
        done
    done
    sysctl -w net.core.rps_sock_flow_entries=32768 > /dev/null 2>&1
    ok "RSS/RPS 已均衡至 ${cpu_count} 核心"
else
    warn "ethtool 不可用，跳过网卡多队列优化"
fi
set -e  # 恢复严格模式
# Step 3: 订阅链接
# ────────────────────────────────────────────────────────────────
step 3 "配置订阅链接"

nohup bash -c 'printf "3\n8\n1\n\n\n" | sb' > /dev/null 2>&1 &
sleep 8

if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
    SUBPORT=$(cat /etc/s-box/subport.log)
    SUBTOKEN=$(cat /etc/s-box/subtoken.log)
    # 安全校验: SUBTOKEN 只允许字母数字下划线横线，防路径穿越
    if [[ ! "$SUBTOKEN" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "SUBTOKEN 包含非法字符: $SUBTOKEN"
    fi
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
echo ""
echo "${HOSTNAME}"
echo "Clash / Mihomo:"
echo "http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
echo "Sing-box:"
echo "http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/sbox.json"
echo "通用聚合:"
echo "http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/jhsub.txt"
echo ""
[ -n "$ARGO_URL" ] && echo "Argo: $ARGO_URL" && echo ""
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
[ -z "$TG_TOKEN" ] && echo "  已跳过" && TG_SKIP=true  
read -p "  输入 Chat ID: " TG_CHAT_ID
[ -z "$TG_CHAT_ID" ] && echo "  已跳过" && TG_SKIP=true

if [ "$TG_SKIP" != "true" ]; then
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
fi  # end TG_SKIP check

echo ""

# ────────────────────────────────────────────────────────────────
# Step 9: 流媒体与 AI 解锁检测 (可选)
# ────────────────────────────────────────────────────────────────
echo -e "${Y}──────────────────────────────────────────${N}"
echo -e "${Y}  可选: 流媒体 / AI 服务解锁检测${N}"
echo -e "${Y}──────────────────────────────────────────${N}"
read -p "  检测流媒体与AI解锁 (Netflix/Disney+/ChatGPT等)? [y/N]: " DO_IPCHECK
if [[ "$DO_IPCHECK" =~ ^[Yy]$ ]]; then
    step 9 "流媒体与AI解锁检测"
    
    # ── 基础 IP 信息 (ip-api.com + ipinfo.io 双源) ──
    IPINFO=$(curl -s --max-time 10 "http://ip-api.com/json/${SERVER_IP}?fields=country,regionName,city,isp,org,as,proxy,hosting" 2>/dev/null)
    if [ -n "$IPINFO" ] && echo "$IPINFO" | grep -q '"status":"success"'; then
        IP_COUNTRY=$(echo "$IPINFO" | grep -oP '"country":"[^"]*"' | cut -d'"' -f4)
        IP_CITY=$(echo "$IPINFO" | grep -oP '"city":"[^"]*"' | cut -d'"' -f4)
        IP_ISP=$(echo "$IPINFO" | grep -oP '"isp":"[^"]*"' | cut -d'"' -f4)
        IP_HOSTING=$(echo "$IPINFO" | grep -oP '"hosting":(true|false)' | cut -d':' -f2)
        echo -e "  ${B}📍 位置:${N} ${G}${IP_CITY}, ${IP_COUNTRY}${N}  |  ISP: ${G}${IP_ISP}${N}"
        [ "$IP_HOSTING" = "true" ] && echo -e "  ${Y}⚠ 检测为机房/托管 IP — 流媒体可能受限${N}"
    else
        IP_COUNTRY="未知"
    fi
    echo ""
    
    # ── 流媒体解锁检测 ──
    echo -e "  ${B}🎬 流媒体解锁:${N}"
    
    # Netflix: 探测一个原创剧集页面 (Safe HTTP probe, 不执行远程脚本)
    NF_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         -H "User-Agent: Mozilla/5.0"         "https://www.netflix.com/title/81280792" 2>/dev/null)
    case "$NF_CODE" in
      200|301|302)
        echo -e "    Netflix       : ${G}✓ 可解锁 (原创)${N}" ;;
      403)
        echo -e "    Netflix       : ${Y}⚠ 仅自制剧 (IP受限)${N}" ;;
      *)
        echo -e "    Netflix       : ${R}✗ 不可用 (HTTP $NF_CODE)${N}" ;;
    esac
    
    # Disney+
    DS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         -H "User-Agent: Mozilla/5.0"         "https://www.disneyplus.com" 2>/dev/null)
    case "$DS_CODE" in
      200|301|302)
        echo -e "    Disney+       : ${G}✓ 可解锁${N}" ;;
      403|451)
        echo -e "    Disney+       : ${R}✗ 地区限制${N}" ;;
      *)
        echo -e "    Disney+       : ${Y}⚠ 待确认 (HTTP $DS_CODE)${N}" ;;
    esac
    
    # YouTube Premium
    YT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         -H "User-Agent: Mozilla/5.0"         "https://www.youtube.com/premium" 2>/dev/null)
    if [ "$YT_CODE" = "200" ]; then
        echo -e "    YouTube Premium: ${G}✓ 可用${N}"
    else
        echo -e "    YouTube Premium: ${Y}⚠ 待确认 (HTTP $YT_CODE)${N}"
    fi
    
    echo ""
    echo -e "  ${B}🤖 AI 服务可达性:${N}"
    
    # ChatGPT / OpenAI
    OAI_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         "https://api.openai.com" 2>/dev/null)
    if [ "$OAI_CODE" = "200" ] || [ "$OAI_CODE" = "401" ]; then
        echo -e "    ChatGPT/OpenAI : ${G}✓ 可访问${N}"
    elif [ "$OAI_CODE" = "403" ]; then
        echo -e "    ChatGPT/OpenAI : ${R}✗ 被屏蔽 (地区限制)${N}"
    else
        echo -e "    ChatGPT/OpenAI : ${Y}⚠ 待确认 (HTTP $OAI_CODE)${N}"
    fi
    
    # Claude / Anthropic
    AN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         "https://api.anthropic.com" 2>/dev/null)
    if [ -n "$AN_CODE" ] && [ "$AN_CODE" != "000" ]; then
        echo -e "    Claude/Anthropic: ${G}✓ 可访问${N}"
    else
        echo -e "    Claude/Anthropic: ${Y}⚠ 待确认${N}"
    fi
    
    # Gemini / Google AI
    GM_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         "https://generativelanguage.googleapis.com" 2>/dev/null)
    if [ -n "$GM_CODE" ] && [ "$GM_CODE" != "000" ]; then
        echo -e "    Gemini/Google AI: ${G}✓ 可访问${N}"
    else
        echo -e "    Gemini/Google AI: ${Y}⚠ 待确认${N}"
    fi
    
    echo ""
    echo -e "  ${PURPLE}ℹ 检测基于 HTTP 探测，结果仅供参考。${N}"
    echo -e "  ${PURPLE}ℹ 精确解锁状态建议运行: bash <(curl -L -s check.unlock.media)${N}"
    
    ok "流媒体检测完成"
else
    info "跳过检测"
fi

# ────────────────────────────────────────────────────────────────
# Step 10: VPS 出口测速 (可选)
# ────────────────────────────────────────────────────────────────
echo -e "${Y}──────────────────────────────────────────${N}"
echo -e "${Y}  可选: VPS 出口带宽测速${N}"
echo -e "${Y}──────────────────────────────────────────${N}"
read -p "  测试 VPS 出口带宽? [y/N]: " DO_SPEED
if [[ "$DO_SPEED" =~ ^[Yy]$ ]]; then
    step 10 "VPS 出口带宽测速"
    
    # 策略1: speedtest-cli (python)
    SPEED_OK=false
    if command -v speedtest-cli &>/dev/null || timeout 60 pip install speedtest-cli -q 2>/dev/null || timeout 60 pip3 install speedtest-cli -q 2>/dev/null; then
        info "使用 speedtest-cli 测速..."
        SPEED_RESULT=$(timeout 30 speedtest-cli --simple 2>/dev/null)
        if [ -n "$SPEED_RESULT" ]; then
            echo -e "${B}  Speedtest 结果:${N}"
            echo "$SPEED_RESULT" | while read line; do echo "    $line"; done
            SPEED_OK=true
        fi
    fi
    
    # 策略2: 兜底 curl 下载测试
    if [ "$SPEED_OK" != "true" ]; then
        warn "speedtest-cli 不可用，使用 curl 下载测试 (10MB)..."
        info "从 cachefly 下载 10MB 测试文件..."
        SPEED_DL=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 15 "http://cachefly.cachefly.net/10mb.test" 2>/dev/null)
        if [ -n "$SPEED_DL" ] && [ "$SPEED_DL" != "0" ]; then
            SPEED_MBPS=$(awk -v speed="$SPEED_DL" 'BEGIN {printf "%.1f", speed * 8 / 1000000}' 2>/dev/null || echo "N/A")
            echo -e "  ${B}下载速度:${N} ${G}${SPEED_MBPS} Mbps${N} (10MB 文件, cachefly CDN)"
            SPEED_OK=true
        else
            warn "下载测速失败"
        fi
    fi
    
    if [ "$SPEED_OK" = "true" ]; then
        ok "测速完成"
    fi
else
    info "跳过测速"
fi

echo ""
echo -e "${G}全部完成！${N}"
