#!/bin/bash
# ===================================================================
# YGVPN — sing-box 彻底清理脚本
# 清除 sing-box / cloudflared(argo) / busybox / crontab / iptables / nftables
# 保留 /opt/cloudflared 等永久隧道文件不受影响
# 用法: bash cleanup.sh [--force]
# ===================================================================
set -euo pipefail

FORCE="${1:-}"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
ok()   { echo -e "${G}[OK]${N}  $*"; }
warn() { echo -e "${Y}[!]${N}   $*"; }
die()  { echo -e "${R}[FAIL]${N} $*"; exit 1; }
info() { echo -e "      $*"; }

echo ""
echo "========================================="
echo "  YGVPN sing-box 清理"
echo "========================================="
echo ""

if [ "$FORCE" != "--force" ]; then
    echo -e "${Y}警告：将清除所有 sing-box 相关配置、进程、定时任务。${N}"
    read -p "确认继续？[y/N] " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "已取消"; exit 0; }
fi

# ————————————————————————————————————————————————————————————————
# 1. 停止并禁用服务
# ————————————————————————————————————————————————————————————————
echo "--- 停止服务 ---"

for svc in sing-box cloudflared cloudflared-update; do
    if systemctl is-active "$svc" &>/dev/null 2>&1; then
        systemctl stop "$svc" 2>/dev/null || true
        ok "已停止服务: $svc"
    fi
    if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
        systemctl disable "$svc" 2>/dev/null || true
        ok "已禁用服务: $svc"
    fi
done

if systemctl is-active cloudflared-update.timer &>/dev/null 2>&1; then
    systemctl stop cloudflared-update.timer 2>/dev/null || true
    systemctl disable cloudflared-update.timer 2>/dev/null || true
    ok "已停止/禁用: cloudflared-update.timer"
fi

# ————————————————————————————————————————————————————————————————
# 2. 杀死相关进程（不影响永久隧道）
# ————————————————————————————————————————————————————————————————
echo "--- 终止进程 ---"

pkill -9 -f sing-box 2>/dev/null && ok "已终止: sing-box" || info "sing-box 未运行"
pkill -9 -f 'cloudflared.*tunnel.*url.*localhost' 2>/dev/null && ok "已终止: cloudflared(Argo临时)" || info "cloudflared 未运行"
pkill -9 busybox 2>/dev/null && ok "已终止: busybox" || info "busybox 未运行"

sleep 1

# ————————————————————————————————————————————————————————————————
# 3. 清理 crontab（仅 sb 相关条目）
# ————————————————————————————————————————————————————————————————
echo "--- 清理 crontab ---"

if crontab -l &>/dev/null; then
    BEFORE=$(crontab -l 2>/dev/null | wc -l)
    (crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb') | crontab - 2>/dev/null || true
    AFTER=$(crontab -l 2>/dev/null | wc -l)
    REMOVED=$((BEFORE - AFTER))
    ok "crontab: 移除 ${REMOVED} 条 sb 相关条目"
else
    info "crontab 为空"
fi

# ————————————————————————————————————————————————————————————————
# 4. 删除 systemd unit 文件
# ————————————————————————————————————————————————————————————————
echo "--- 清理 systemd units ---"

COUNT=0
for unit in /etc/systemd/system/sing-box.service \
            /etc/systemd/system/cloudflared.service \
            /etc/systemd/system/cloudflared-update.service \
            /etc/systemd/system/cloudflared-update.timer; do
    if [ -f "$unit" ]; then
        rm -f "$unit"
        COUNT=$((COUNT + 1))
    fi
done
[ $COUNT -gt 0 ] && ok "已删除 ${COUNT} 个 systemd unit 文件" || info "无 unit 文件需清理"

systemctl daemon-reload

# ————————————————————————————————————————————————————————————————
# 5. 删除 sb 相关目录和文件（不碰 /opt/cloudflared）
# ————————————————————————————————————————————————————————————————
echo "--- 清理文件和目录 ---"

COUNT=0
for path in /etc/s-box /usr/bin/sb /root/websbox; do
    if [ -e "$path" ]; then
        rm -rf "$path"
        COUNT=$((COUNT + 1))
        ok "已删除: $path"
    fi
done
[ $COUNT -eq 0 ] && info "无 sb 文件需清理"

# ————————————————————————————————————————————————————————————————
# 6. 清理 iptables 规则
# ————————————————————————————————————————————————————————————————
echo "--- 清理 iptables ---"

iptables -t nat -D PREROUTING -p udp --dport 40000:41000 -j DNAT --to-destination :34682 2>/dev/null && ok "已删除 Hysteria2 DNAT 规则" || info "无 Hysteria2 NAT 规则"
iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null && ok "已删除 sing-box MASQUERADE 规则" || info "无 MASQUERADE 规则"

# ————————————————————————————————————————————————————————————————
# 7. 清理 nftables 规则
# ————————————————————————————————————————————————————————————————
echo "--- 清理 nftables ---"

nft delete table inet sing-box 2>/dev/null && ok "已删除 nftables sing-box 表" || info "无 nftables 规则"

# ————————————————————————————————————————————————————————————————
# 验证
# ————————————————————————————————————————————————————————————————
echo ""
echo "========================================="
echo "  验证清理结果"
echo "========================================="

PASS=0
FAIL=0

systemctl status sing-box 2>&1 | grep -q 'could not be found' && { ok "sing-box 服务已清除"; PASS=$((PASS+1)); } || { warn "sing-box 服务仍存在"; FAIL=$((FAIL+1)); }
[ ! -d /etc/s-box ] && { ok "/etc/s-box 已删除"; PASS=$((PASS+1)); } || { warn "/etc/s-box 仍存在"; FAIL=$((FAIL+1)); }
crontab -l 2>/dev/null | grep -qE 'sing-box|cloudflared|argo' && { warn "crontab 残留 sb 条目"; FAIL=$((FAIL+1)); } || { ok "crontab 无 sb 条目"; PASS=$((PASS+1)); }
ps aux | grep -E 'sing-box|cloudflared.*tunnel.*url' | grep -v grep | wc -l | grep -q '^0$' && { ok "进程已清理"; PASS=$((PASS+1)); } || { warn "仍有相关进程"; FAIL=$((FAIL+1)); }

echo ""
echo "========================================="
echo -e "  通过: ${G}${PASS}${N} / 失败: ${R}${FAIL}${N}"
echo "========================================="

[ $FAIL -eq 0 ] || die "部分清理失败，请手动检查"
echo -e "${G}清理完成。可以开始部署。${N}"
