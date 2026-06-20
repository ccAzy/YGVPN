#!/bin/bash
# ===================================================================
# YGVPN — 部署后验证脚本
# 检查 sing-box 进程、端口、Argo 隧道、订阅链接
# 用法: bash verify.sh [SERVER_IP]
# ===================================================================
set -euo pipefail

SERVER_IP="${1:-}"
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
ok()   { echo -e "${G}[PASS]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
fail() { echo -e "${R}[FAIL]${N} $*"; }
info() { echo -e "       $*"; }

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        ok "$desc"
        PASS=$((PASS + 1))
        return 0
    else
        fail "$desc"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

echo ""
echo "========================================="
echo "  YGVPN 部署验证"
echo "========================================="
echo ""

# ————————————————————————————————————————————————————————————————
# 1. 基础检查
# ————————————————————————————————————————————————————————————————
echo "--- 基础状态 ---"

check "sb 命令存在"       which sb
check "sing-box 二进制"   [ -x /usr/bin/sing-box ] || [ -x /usr/local/bin/sing-box ] || [ -x /etc/s-box/sing-box ]
check "/etc/s-box 目录"   [ -d /etc/s-box ]

# ————————————————————————————————————————————————————————————————
# 2. sing-box 进程
# ————————————————————————————————————————————————————————————————
echo "--- 进程检查 ---"

if ps aux | grep -v grep | grep -q sing-box; then
    ok "sing-box 进程运行中"
    PASS=$((PASS + 1))
    ps aux | grep -v grep | grep sing-box | while read line; do info "$line"; done
else
    fail "sing-box 进程未运行"
    FAIL=$((FAIL + 1))
fi

# ————————————————————————————————————————————————————————————————
# 3. 端口监听
# ————————————————————————————————————————————————————————————————
echo "--- 端口监听 ---"

PORTS=$(ss -tlnp 2>/dev/null | grep sing-box | awk '{print $4}' | rev | cut -d: -f1 | rev | sort -n | tr '\n' ' ')
if [ -n "$PORTS" ]; then
    ok "监听端口: $PORTS"
    PASS=$((PASS + 1))
else
    fail "未检测到 sing-box 监听端口"
    FAIL=$((FAIL + 1))
fi

# Hysteria2 UDP 端口
if ss -ulnp 2>/dev/null | grep -q sing-box; then
    ok "UDP 端口监听正常（Hysteria2）"
    PASS=$((PASS + 1))
else
    warn "未检测到 UDP 端口（可能无 Hysteria2）"
fi

# ————————————————————————————————————————————————————————————————
# 4. Argo 隧道
# ————————————————————————————————————————————————————————————————
echo "--- Argo 隧道 ---"

if [ -f /etc/s-box/argo.log ]; then
    ARGO_URL=$(grep -oP 'https?://[a-z0-9.-]+\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | head -1)
    if [ -n "$ARGO_URL" ]; then
        ok "Argo 隧道: $ARGO_URL"
        PASS=$((PASS + 1))
        # 测试可达性
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$ARGO_URL" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" != "000" ]; then
            ok "Argo 端点可达 (HTTP $HTTP_CODE)"
            PASS=$((PASS + 1))
        else
            warn "Argo 端点不可达（可能需等待 DNS 生效）"
        fi
    else
        fail "argo.log 中未找到 trycloudflare.com URL"
        FAIL=$((FAIL + 1))
    fi
else
    fail "/etc/s-box/argo.log 不存在"
    FAIL=$((FAIL + 1))
fi

# ————————————————————————————————————————————————————————————————
# 5. 订阅链接
# ————————————————————————————————————————————————————————————————
echo "--- 订阅链接 ---"

if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
    SUBPORT=$(cat /etc/s-box/subport.log)
    SUBTOKEN=$(cat /etc/s-box/subtoken.log)
    ok "订阅端口: $SUBPORT"

    if [ -n "$SERVER_IP" ]; then
        for fmt in clmi.yaml sbox.json jhsub.txt; do
            URL="http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/${fmt}"
            HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$URL" 2>/dev/null || echo "000")
            if [ "$HTTP_CODE" = "200" ]; then
                ok "$fmt 可访问 (HTTP 200)"
                PASS=$((PASS + 1))
            else
                fail "$fmt 不可访问 (HTTP $HTTP_CODE)"
                FAIL=$((FAIL + 1))
            fi
        done
    else
        info "跳过 HTTP 测试（未提供 SERVER_IP）"
        info "手动验证: curl http://<IP>:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
    fi
else
    fail "订阅配置文件缺失 (subport.log / subtoken.log)"
    FAIL=$((FAIL + 1))
fi

# ————————————————————————————————————————————————————————————————
# 6. 域名分流
# ————————————————————————————————————————————————————————————————
echo "--- 域名分流 ---"

if [ -f /etc/s-box/sbwpph.json ]; then
    DOMAIN_COUNT=$(python3 -c "import json; print(len(json.load(open('/etc/s-box/sbwpph.json'))['route']['rules'][0].get('domain',[])))" 2>/dev/null || echo "?")
    ok "域名分流文件存在 (${DOMAIN_COUNT} 个域名)"
    PASS=$((PASS + 1))
else
    warn "sbwpph.json 不存在（可能未配置域名分流）"
fi

# ————————————————————————————————————————————————————————————————
# 汇总
# ————————————————————————————————————————————————————————————————
echo ""
echo "========================================="
echo -e "  通过: ${G}${PASS}${N} / 失败: ${R}${FAIL}${N}"
echo "========================================="

if [ $FAIL -eq 0 ]; then
    echo -e "${G}✓ 部署验证全部通过${N}"
    exit 0
else
    echo -e "${R}✗ 存在 ${FAIL} 项失败，请检查${N}"
    exit 1
fi
