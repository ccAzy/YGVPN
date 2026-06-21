#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys, os
# Windows GBK fix: must be before any non-ASCII print
if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
os.environ['PYTHONIOENCODING'] = 'utf-8'

"""
deploy.py -- sing-box VPN one-click deployer
Handles TERM, encoding, timeout, binary file transfer issues.

Usage:
  python deploy.py <host> <port> <user> <password> [--skip-cleanup] [--skip-bbr]

Example:
  python deploy.py 1.2.3.4 6688 root "mypassword"
"""

import paramiko
import time
import re
import argparse

# Domain split list
DOMAINS = (
    "google.com youtube.com gmail.com googleapis.com blogspot.com "
    "chatgpt.com claude.ai gemini.google.com openai.com perplexity.ai "
    "netflix.com disneyplus.com spotify.com hulu.com hbomax.com "
    "github.com gitlab.com stackoverflow.com docker.com npmjs.com "
    "twitter.com x.com facebook.com instagram.com reddit.com discord.com "
    "t.me wikipedia.org medium.com quora.com patreon.com twitch.tv"
)

TG_TOKEN = os.environ.get("TG_TOKEN", "")
TG_CHAT_ID = os.environ.get("TG_CHAT_ID", "")


class Deployer:
    def __init__(self, host, port, user, password, tg_token=None, tg_chat_id=None):
        self.tg_token = tg_token or os.environ.get("TG_TOKEN", "")
        self.tg_chat_id = tg_chat_id or os.environ.get("TG_CHAT_ID", "")
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.client = None

    def connect(self):
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(
            self.host, port=self.port, username=self.user,
            password=self.password, timeout=15
        )
        _, stdout, _ = self.client.exec_command("hostname")
        hostname = stdout.read().decode().strip()
        _, stdout, _ = self.client.exec_command('curl -s4 ifconfig.me || curl -s ipv4.icanhazip.com')
        ip = stdout.read().decode().strip()
        print(f"[OK] Connected {hostname} @ {ip}")
        return ip

    def run(self, cmd, timeout=30, label=""):
        if label:
            print(f"\n-- {label} --")
        print(f"   $ {cmd[:120]}{'...' if len(cmd) > 120 else ''}")
        _, stdout, stderr = self.client.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode('utf-8', errors='replace')
        err = stderr.read().decode('utf-8', errors='replace')
        exit_code = stdout.channel.recv_exit_status()
        if out.strip():
            for line in out.strip().split('\n'):
                print(f"   {line}")
        if err.strip():
            for line in err.strip().split('\n'):
                print(f"   [E] {line}")
        if exit_code != 0 and label:
            print(f"   [exit={exit_code}]")
        return out, exit_code

    def run_nohup(self, printf_seq, label="", wait=5):
        cmd = (
            f"nohup env TERM=xterm-256color bash -c "
            f"'{printf_seq}' > /dev/null 2>&1 &"
        )
        print(f"\n-- {label} (nohup) --")
        print(f"   $ {cmd[:150]}{'...' if len(cmd) > 150 else ''}")
        _, _, _ = self.client.exec_command(cmd, timeout=10)
        print(f"   waiting {wait}s...")
        time.sleep(wait)

    def sftp_write(self, remote_path, content):
        sftp = self.client.open_sftp()
        with sftp.file(remote_path, 'w') as f:
            f.write(content)
        sftp.close()
        print(f"   >> {remote_path} ({len(content)} bytes)")

    # -- Deployment steps --

    def _get_uuid(self):
        """Extract UUID from sb.json config (fallback to default)"""
        _, stdout, _ = self.client.exec_command(
            "python3 -c \"import json; d=json.load(open('/etc/s-box/sb.json')); "
            "ids=[i.get('users',[{}])[0].get('id','') for i in d['inbounds'] if 'users' in i]; "
            "print(ids[0] if ids else '4b7c92ab-5f71-4acc-acfc-60e6d5d35f67')\" 2>/dev/null",
            timeout=10)
        uuid = stdout.read().decode().strip()
        return uuid or "4b7c92ab-5f71-4acc-acfc-60e6d5d35f67"

    def step_cleanup(self):
        """第零步：清理旧安装（逐条执行，避免大脚本 exit=-1）"""
        self.run("echo \"Target: $(hostname) @ $(curl -s4 ifconfig.me || curl -s ipv4.icanhazip.com)\"", label="Step 0: Cleanup")
        self.run("systemctl stop sing-box cloudflared cloudflared-update.timer 2>/dev/null; systemctl disable sing-box cloudflared cloudflared-update.service cloudflared-update.timer 2>/dev/null; echo done")
        self.run("pkill -9 sing-box 2>/dev/null; pkill -9 -f '[c]loudflared.*tunnel.*url.*localhost' 2>/dev/null; echo done")
        self.run("pgrep -a busybox 2>/dev/null | grep -E 's-box|websbox' | cut -d' ' -f1 | xargs -r kill -9 2>/dev/null; echo done")
        time.sleep(2)
        self.run("(crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb|/etc/s-box') | crontab - 2>/dev/null; echo done")
        self.run("rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared-update.service /etc/systemd/system/cloudflared-update.timer; systemctl daemon-reload; echo done")
        self.run("rm -rf /usr/bin/sb /root/websbox /etc/s-box/* 2>/dev/null; mkdir -p /etc/s-box; echo done")
        self.run("iptables -t nat -D PREROUTING -p udp --dport 40000:41000 -j DNAT --to-destination :34682 2>/dev/null; iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null; nft delete table inet sing-box 2>/dev/null; echo '=== CLEANUP DONE ==='")
        _, ec1 = self.run("test ! -f /usr/bin/sb && echo 'OK' || echo 'sb still exists'")
        return ec1 == 0

    def step_install(self):
        cmd = (
            "export TERM=xterm-256color; "
            'printf "1\\n" | bash <(wget -qO- '
            "https://raw.githubusercontent.com/ccAzy/sing-box-yg/main/sb.sh)"
        )
        print(f"\n-- Step 1: Install sing-box --")
        print("   downloading + installing (~60-120s)...")
        _, stdout, stderr = self.client.exec_command(cmd, timeout=300)
    def step_bbr(self):
        step_m('2', 'BBR + kernel check')
        # Check kernel version
        _, stdout, _ = self.client.exec_command(
            "uname -r | cut -d. -f1,2", timeout=5)
        kver = stdout.read().decode().strip()
        parts = kver.split('.')
        kmajor, kminor = int(parts[0]), int(parts[1]) if len(parts) > 1 else 0

        if kmajor >= 7 or (kmajor == 6 and kminor >= 12):
            info_m(f'Kernel {kver} supports BBRv3')
        else:
            warn_m(f'Kernel {kver} is old (BBRv1 only), upgrading...')
            # Detect OS and install newer kernel
            _, stdout, _ = self.client.exec_command(
                '. /etc/os-release 2>/dev/null && echo $ID', timeout=5)
            os_id = stdout.read().decode().strip()
            if os_id == 'debian':
                self.run('apt install -y -t $(. /etc/os-release && echo $VERSION_CODENAME)-backports linux-image-amd64 2>/dev/null && echo OK || echo FAIL',
                         timeout=180, show=False)
            elif os_id == 'ubuntu':
                self.run('curl -s https://liquorix.net/add-liquorix-repo.sh 2>/dev/null | bash 2>/dev/null; apt install -y linux-image-liquorix-amd64 2>/dev/null && echo OK || echo FAIL',
                         timeout=180, show=False)
            elif os_id in ('centos', 'rhel', 'rocky', 'almalinux'):
                self.run('rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null; '
                         'rpm -Uvh https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm 2>/dev/null || '
                         'rpm -Uvh https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm 2>/dev/null; '
                         'dnf --enablerepo=elrepo-kernel install -y kernel-ml 2>/dev/null || '
                         'yum --enablerepo=elrepo-kernel install -y kernel-ml 2>/dev/null && echo OK || echo FAIL',
                         timeout=180, show=False)
            elif os_id == 'fedora':
                info_m('Fedora kernel usually recent enough, skipping upgrade')
                ok_m('Kernel installed, reboot to activate')

        # Enable BBR — three layers
        self.run('modprobe tcp_bbr 2>/dev/null || true', show=False)
        self.run('sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1 || true', show=False)
        self.run('sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 || true', show=False)
        self.run('grep -q net.core.default_qdisc=fq /etc/sysctl.conf || echo net.core.default_qdisc=fq >> /etc/sysctl.conf; '
                 'grep -q net.ipv4.tcp_congestion_control=bbr /etc/sysctl.conf || echo net.ipv4.tcp_congestion_control=bbr >> /etc/sysctl.conf',
                 show=False)
        _, stdout, _ = self.client.exec_command('sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null', timeout=5)
        bbr = stdout.read().decode().strip()
        if bbr == 'bbr':
            ok_m('BBR enabled')
        else:
            warn_m(f'BBR not active ({bbr}) — try manual: modprobe tcp_bbr && sysctl -w net.ipv4.tcp_congestion_control=bbr')
        return True
    def step_network_tune(self):
        step_m('2.5', 'Network aggressive tune')
        self.run(
            "cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s) 2>/dev/null; "
            "sysctl -w net.core.rmem_max=16777216 >/dev/null; "
            "sysctl -w net.core.wmem_max=16777216 >/dev/null; "
            "sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null; "
            "sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null; "
            "sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null; "
            "sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null; "
            "sysctl -w net.ipv4.tcp_fin_timeout=10 >/dev/null; "
            "sysctl -w net.ipv4.tcp_keepalive_time=120 >/dev/null; "
            "sysctl -w net.core.somaxconn=16384 >/dev/null; "
            "sysctl -w net.core.netdev_max_backlog=20000 >/dev/null; "
            "sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null; "
            "sysctl -w net.ipv4.tcp_synack_retries=1 >/dev/null; "
            "sysctl -w net.ipv4.tcp_syn_retries=2 >/dev/null; "
            "sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null; "
            "sysctl -w vm.swappiness=5 >/dev/null; "
            "sysctl -w vm.dirty_ratio=10 >/dev/null; "
            "sysctl -w vm.dirty_background_ratio=3 >/dev/null; "
            "sysctl -w vm.vfs_cache_pressure=50 >/dev/null; "
            "sysctl -w fs.file-max=2097152 >/dev/null; "
            "echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; "
            "echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null; "
            "echo OK",
            timeout=30, show=False)
        self.sftp_write('/etc/security/limits.conf',
            "# YGVPN network tune\n* soft nofile 2097152\n* hard nofile 2097152\nroot soft nofile 2097152\nroot hard nofile 2097152\n")
        ok_m('Network aggressive tune applied')
        return True

    def step_subscription(self):
        self.run_nohup(
            'printf "3\\n8\\n1\\n\\n\\n" | sb',
            label="3.1 Subscription (3>8>1)", wait=5
        )
        time.sleep(3)
        _, stdout, _ = self.client.exec_command(
            "cat /etc/s-box/subport.log 2>/dev/null; echo '::'; "
            "cat /etc/s-box/subtoken.log 2>/dev/null"
        )
        parts = stdout.read().decode().strip().split('::')
        ok = len(parts) == 2 and parts[0].strip().isdigit()
        if ok:
            subport = parts[0].strip()
            subtoken = parts[1].strip()
            print(f"   [OK] port={subport} token={subtoken}")
            # Create token dir for busybox httpd (sb sometimes skips this)
            self.run(
                f"mkdir -p /root/websbox/{subtoken} && "
                f"cp /etc/s-box/clmi.yaml /etc/s-box/sbox.json /etc/s-box/jhsub.txt "
                f"/root/websbox/{subtoken}/ 2>/dev/null; echo done"
            )
        else:
            print("   [FAIL] subscription not generated")
        return ok

    def step_hysteria2(self):
        self.run_nohup(
            'printf "4\\n3\\n2\\n40000:41000\\n0\\n" | sb',
            label="3.2 Hysteria2 (4>3>2)", wait=8
        )
        _, _, _ = self.client.exec_command(
            "sleep 3 && iptables -t nat -L PREROUTING 2>/dev/null | grep -q '40000'",
            timeout=15
        )
        return _.channel.recv_exit_status() == 0

    def step_argo(self):
        """第三步3：Argo 临时隧道"""
        # Try download, fallback to existing or /opt copy
        dl_ok, _ = self.run(
            "curl -sL --connect-timeout 30 --max-time 120 "
            "https://github.com/cloudflare/cloudflared/releases/latest/download/"
            "cloudflared-linux-amd64 -o /etc/s-box/cloudflared.tmp && "
            "mv /etc/s-box/cloudflared.tmp /etc/s-box/cloudflared && "
            "chmod +x /etc/s-box/cloudflared && echo OK",
            label="3.3a Update cloudflared", timeout=150
        )
        if dl_ok != 0:
            self.run(
                "test -x /etc/s-box/cloudflared && echo 'using existing' || "
                "(cp /opt/cloudflared/cloudflared /etc/s-box/cloudflared && "
                "echo 'copied from /opt') || echo 'FATAL no cloudflared'"
            )
        self.run_nohup(
            'printf "3\\n3\\n1\\n1\\n" | sb',
            label="3.3b Argo tunnel (3>3>1>1)", wait=5
        )
        # Poll for Argo URL (max 60s)
        print("   Polling for Argo tunnel...")
        url = ""; ok = False
        for i in range(1, 21):
            time.sleep(3)
            _, stdout, _ = self.client.exec_command(
                "grep 'trycloudflare.com' /etc/s-box/argo.log 2>/dev/null | tail -1")
            url = stdout.read().decode().strip()
            if 'trycloudflare.com' in url:
                ok = True
                print(f"   Argo ready ({i*3}s)")
                break
            print(f"   ...{i*3}s")
        if ok:
            m = re.search(r'https://[a-z0-9.-]+\.trycloudflare\.com', url)
            if m:
                print(f"   -> {m.group()}")
        else:
            print("   [WARN] Argo not ready, trying manual start...")
            # Fallback: get VMess port from config (not ss which returns vless first)
            _, stdout, _ = self.client.exec_command(
                "grep -A3 '\"type\": \"vmess\"' /etc/s-box/sb.json | grep listen_port | grep -oP '\\d+' 2>/dev/null || "
                "sed 's://.*::g' /etc/s-box/sb.json | python3 -c \"import sys,json; "
                "print([i['listen_port'] for i in json.load(sys.stdin)['inbounds'] if i['type']=='vmess'][0])\" 2>/dev/null"
            )
            vmess = stdout.read().decode().strip()
            if vmess:
                self.run(
                    f"nohup /etc/s-box/cloudflared tunnel --url http://localhost:{vmess} "
                    "--edge-ip-version auto --no-autoupdate --protocol http2 "
                    "> /etc/s-box/argo.log 2>&1 &",
                    label="3.3c Manual Argo start"
                )
                time.sleep(25)
                _, stdout, _ = self.client.exec_command(
                    "grep 'trycloudflare.com' /etc/s-box/argo.log 2>/dev/null | tail -1"
                )
                url = stdout.read().decode().strip()
                ok = 'trycloudflare.com' in url
                if ok:
                    m = re.search(r'https://[a-z0-9.-]+\.trycloudflare\.com', url)
                    if m:
                        print(f"   -> {m.group()}")
        # Fix subscription: update Argo proxy addresses to real trycloudflare host
        if ok:
            self._fix_argo_in_subscription(url)
        return ok

    def _fix_argo_in_subscription(self, argo_url):
        """Replace sb's default Argo proxies with correct trycloudflare tunnel config"""
        m = re.search(r'https://([a-z0-9.-]+\.trycloudflare\.com)', argo_url)
        if not m:
            return
        argo_host = m.group(1)
        uuid = self._get_uuid()
        
        # Fix clmi.yaml (YAML format)
        self.run(
            f"python3 -c \"\n"
            f"import yaml, json, base64, glob\n"
            f"for f in glob.glob('/etc/s-box/clmi.yaml') + glob.glob('/root/websbox/*/clmi.yaml'):\n"
            f"  try:\n"
            f"    with open(f) as fp: d=yaml.safe_load(fp.read())\n"
            f"    d['proxies']=[p for p in d['proxies'] if 'argo' not in p.get('name','').lower()]\n"
            f"    for g in d.get('proxy-groups',[]): g['proxies']=[p for p in g['proxies'] if 'argo' not in p.lower()]\n"
            f"    argo={{'name':'hk-argo','type':'vmess','server':'{argo_host}','port':443,'uuid':'{uuid}','alterId':0,'cipher':'auto','tls':True,'skip-cert-verify':True,'servername':'{argo_host}','network':'ws','ws-opts':{{'path':'/','headers':{{'Host':'{argo_host}'}}}},'client-fingerprint':'chrome'}}\n"
            f"    d['proxies'].append(argo)\n"
            f"    if d.get('proxy-groups'): d['proxy-groups'][0]['proxies'].insert(0,'hk-argo')\n"
            f"    with open(f,'w') as fp: fp.write(yaml.dump(d,allow_unicode=True,default_flow_style=False))\n"
            f"  except: pass\n"
            f"print('clmi fixed')\n"
            f"\" 2>/dev/null",
            timeout=15
        )
        
        # Fix jhsub.txt (base64 encoded vmess links)
        self.run(
            f"python3 -c \"\n"
            f"import json, base64, glob\n"
            f"argo_cfg={{'v':'2','ps':'hk-argo','add':'{argo_host}','port':'443','id':'{uuid}','aid':'0','scy':'auto','net':'ws','type':'none','host':'{argo_host}','path':'/','tls':'tls','sni':'{argo_host}','alpn':'http/1.1','fp':'chrome'}}\n"
            f"new_line='vmess://'+base64.b64encode(json.dumps(argo_cfg).encode()).decode()\n"
            f"for f in glob.glob('/etc/s-box/jhsub.txt') + glob.glob('/root/websbox/*/jhsub.txt'):\n"
            f"  try:\n"
            f"    with open(f) as fp: lines=fp.read().strip().split(chr(10))\n"
            f"    lines=[l for l in lines if not ('vmess://' in l and 'argo' in l.lower())]\n"
            f"    lines.append(new_line)\n"
            f"    with open(f,'w') as fp: fp.write(chr(10).join(lines)+chr(10))\n"
            f"  except: pass\n"
            f"print('jhsub fixed')\n"
            f"\" 2>/dev/null",
            timeout=15
        )

    def step_domain_split(self):
        self.run_nohup(
            f'printf "5\\n2\\n1\\n{DOMAINS}\\n" | sb',
            label="3.4 Domain split (5>2>1)", wait=8
        )
        _, ec = self.run("pgrep sing-box > /dev/null && echo 'OK'")
        return ec == 0

    def step_verify_all(self):
        print(f"\n{'='*50}")
        print("   3.5 Deployment verification")
        print(f"{'='*50}")
        checks = {
            "sing-box process": "ps aux | grep sing-box | grep -qv grep",
            "Argo tunnel": "grep -q 'trycloudflare.com' /etc/s-box/argo.log 2>/dev/null",
            "subscription port": "test -f /etc/s-box/subport.log",
            "Hysteria2 iptables": "iptables -t nat -L PREROUTING 2>/dev/null | grep -q '40000'",
        }
        all_ok = True
        for name, cmd in checks.items():
            _, _, _ = self.client.exec_command(cmd, timeout=10)
            ok = _.channel.recv_exit_status() == 0
            print(f"   {'[OK]' if ok else '[FAIL]'} {name}")
            if not ok:
                all_ok = False
        return all_ok

    def step_tg_push(self, server_label="node"):
        print(f"\n-- Step 4: TG push --")
        if not self.tg_token or not self.tg_chat_id:
            print("   [!]  TG_TOKEN/TG_CHAT_ID not set — skipping push")
            return False

        ip = self.server_ip
        _, stdout, _ = self.client.exec_command('cat /etc/s-box/subport.log')
        subport = stdout.read().decode().strip()
        _, stdout, _ = self.client.exec_command('cat /etc/s-box/subtoken.log')
        subtoken = stdout.read().decode().strip()

        if not (ip and subport and subtoken):
            print("   [FAIL] missing subscription info, skip push")
            return False

        # IPv6 addresses need brackets in URLs
        if ':' in ip and not ip.startswith('['):
            ip = f'[{ip}]'

        script = f'''#!/bin/bash
TOKEN="{self.tg_token}"
CHAT_ID="{self.tg_chat_id}"
URL="https://api.telegram.org/bot${{TOKEN}}/sendMessage"

CLASH_URL="http://{ip}:{subport}/{subtoken}/clmi.yaml"
JH_URL="http://{ip}:{subport}/{subtoken}/jhsub.txt"

msg="{server_label}
Clash / Mihomo:
${{CLASH_URL}}
通用:
${{JH_URL}}"

curl -s -X POST "$URL" -d chat_id="$CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$msg"
echo ""
echo "Sent!"
'''
        self.sftp_write('/etc/s-box/sbtg.sh', script)

        _, stdout, _ = self.client.exec_command('bash /etc/s-box/sbtg.sh')
        resp = stdout.read().decode().strip()
        ok = '"ok":true' in resp
        print(f"   {'[OK]' if ok else '[FAIL]'} TG push {'success' if ok else 'failed'}")
        return ok

    def deploy(self, skip_cleanup=False, skip_bbr=False, skip_tg=False, label="node"):
        print("=" * 60)
        print(f"  sing-box VPN deploy -- {label}")
        print(f"  target: {self.host}:{self.port}")
        print("=" * 60)

        self.connect()

        results = {}

        if not skip_cleanup:
            results['cleanup'] = self.step_cleanup()

        results['install'] = self.step_install()
        if not results['install']:
            print("\n[FAIL] Install failed, aborting")
            return results

        if not skip_bbr:
            results['bbr'] = self.step_bbr()
        else:
            print("\n-- Step 2: BBR --")
            print("   skip")

        results['network_tune'] = self.step_network_tune()

        results['subscription'] = self.step_subscription()
        results['hysteria2'] = self.step_hysteria2()
        results['argo'] = self.step_argo()
        results['domain_split'] = self.step_domain_split()
        results['verify'] = self.step_verify_all()
        if not skip_tg:
            results['tg_push'] = self.step_tg_push(server_label=label)

        print(f"\n{'='*60}")
        print("  Summary")
        print(f"{'='*60}")
        for step, ok in results.items():
            icon = '[OK]' if ok else '[FAIL]'
            print(f"  {icon} {step}")
        return results


def main():
    parser = argparse.ArgumentParser(
        description='YGVPN - sing-box VPN one-click deploy',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Examples:\n  python deploy.py --server vn\n  python deploy.py --server all\n  python deploy.py 1.2.3.4 6688 root pass')
    parser.add_argument('host', nargs='?', help='Server IP (omit if using --server)')
    parser.add_argument('port', nargs='?', type=int, help='SSH port')
    parser.add_argument('user', nargs='?', help='SSH username')
    parser.add_argument('password', nargs='?', help='SSH password')
    parser.add_argument('--server', '-s', help='Server name from servers.json (vn/hk/jp/rn1/rn2/cc) or "all"')
    parser.add_argument('--servers-file', default='servers.json', help='Path to servers.json')
    parser.add_argument('--skip-cleanup', action='store_true', help='Skip cleanup step')
    parser.add_argument('--skip-bbr', action='store_true', help='Skip BBR step')
    parser.add_argument('--skip-tg', action='store_true', help='Skip TG push')
    parser.add_argument('--tg-token', help='TG bot token (or TG_TOKEN env)')
    parser.add_argument('--tg-chat-id', help='TG chat ID (or TG_CHAT_ID env)')
    parser.add_argument('--label', default=None, help='Node label for TG push (default: server name)')
    args = parser.parse_args()

    servers_to_deploy = []
    if args.server:
        import json
        sf = args.servers_file
        if not os.path.isabs(sf):
            script_dir = os.path.dirname(os.path.abspath(__file__))
            for base in [os.getcwd(), script_dir, os.path.join(script_dir, '..')]:
                ck = os.path.join(base, sf)
                if os.path.exists(ck):
                    sf = ck
                    break
        if not os.path.exists(sf):
            fail_m('servers.json not found: ' + sf)
            sys.exit(1)
        with open(sf, 'r') as f:
            config = json.load(f)
        if args.server == 'all':
            servers_to_deploy = list(config['servers'].items())
            print('Batch deploy: ' + str(len(servers_to_deploy)) + ' servers')
        else:
            if args.server not in config['servers']:
                fail_m('Server "' + args.server + '" not found')
                info_m('Available: ' + ', '.join(config['servers'].keys()))
                sys.exit(1)
            servers_to_deploy = [(args.server, config['servers'][args.server])]
    else:
        if not all([args.host, args.port, args.user, args.password]):
            parser.error('--server or host/port/user/password required')
        servers_to_deploy = [('manual', {'ip': args.host, 'port': args.port, 'user': args.user, 'password': args.password})]

    all_results = {}
    for name, srv in servers_to_deploy:
        label = args.label or name
        deployer = Deployer(srv['ip'], srv.get('port', 22), srv['user'], srv['password'],
                          tg_token=args.tg_token, tg_chat_id=args.tg_chat_id)
        results = deployer.deploy(skip_cleanup=args.skip_cleanup, skip_bbr=args.skip_bbr,
                                  skip_tg=args.skip_tg, label=label)
        all_results[name] = results

    if len(all_results) > 1:
        sep = '=' * 60
        print('\n' + sep + '\n  Batch Summary\n' + sep)
        for name, r in all_results.items():
            ok_cnt = sum(1 for v in r.values() if v)
            icon = '[OK]' if all(r.values()) else '[FAIL]'
            print('  ' + icon + ' ' + name + ': ' + str(ok_cnt) + '/' + str(len(r)))

    all_ok = all(all(r.values()) for r in all_results.values())
    if all_ok:
        print('\n=== ALL SUCCESS ===')
    else:
        print('\n=== SOME FAILED ===')
    sys.exit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
