#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Linux 轻量提权枚举器: 检查 SUID/sudo/定时任务/可写文件/capabilities
用法:
  python linpeas_light.py
  python linpeas_light.py --quick
"""
# 20261107 小柠檬集成修复:
# 1) Termux/Android 上 platform.system() 误判非Linux导致直接退出 -> 改用 /proc/version 兜底
# 2) Android 无 /etc/passwd, pwd.getpwuid/grp.getgrall 会 KeyError -> 包容错
# 3) find 加 -xdev 防跨分区扫描过慢(Android 用户分区巨大)
import argparse, os, re, stat, subprocess, sys, platform

IS_LINUX = platform.system() == "Linux" or os.path.exists("/proc/version")
if IS_LINUX:
    try:
        import grp, pwd
    except ImportError:
        grp = pwd = None

def run(cmd):
    try:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return out.stdout.strip()
    except Exception:
        return ""

def check_suid():
    print("\n[*] SUID 文件检查...")
    out = run("find / -xdev -perm -4000 -type f 2>/dev/null | head -50")
    for line in out.split("\n")[:30]:
        if line:
            print(f"    {line}")

def check_sudo():
    print("\n[*] sudo 配置检查...")
    out = run("sudo -l 2>/dev/null")
    if out:
        for line in out.split("\n"):
            print(f"    {line}")
    else:
        print("    (无 sudo 权限或未配置)")

def check_cron():
    print("\n[*] 定时任务检查...")
    paths = ["/etc/crontab", "/etc/cron.d", "/etc/cron.hourly", "/etc/cron.daily",
             "/etc/cron.weekly", "/etc/cron.monthly", "/var/spool/cron/crontabs"]
    for p in paths:
        try:
            if os.path.isdir(p):
                for f in os.listdir(p):
                    fp = os.path.join(p, f)
                    if os.path.isfile(fp) and os.access(fp, os.R_OK):
                        print(f"    [可读] {fp}")
                        with open(fp, errors="ignore") as fh:
                            lines = fh.read()[:300]
                            for ln in lines.split("\n"):
                                if ln.strip() and not ln.startswith("#"):
                                    print(f"      {ln.strip()[:100]}")
            elif os.path.isfile(p) and os.access(p, os.R_OK):
                print(f"    [可读] {p}")
        except Exception:
            pass

def check_writable():
    print("\n[*] 可写系统目录...")
    check_dirs = ["/etc", "/tmp", "/var/tmp", "/opt", "/usr/local/bin"]
    for d in check_dirs:
        if os.path.isdir(d) and os.access(d, os.W_OK):
            print(f"    [!] 可写: {d}")

def check_kernel():
    print("\n[*] 内核版本: " + (run("uname -r") or "?"))
    print("    检查: linux-exploit-suggester")

def main():
    ap = argparse.ArgumentParser(description="Linux 轻量提权枚举器")
    ap.add_argument("--quick", action="store_true", help="仅快速检查")
    args = ap.parse_args()

    if not IS_LINUX:
        print("[!] 本工具仅支持 Linux 平台")
        sys.exit(1)

    print("=== Linux 提权枚举 ===")
    try:
        user = pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        user = "uid:%d" % os.getuid()
    try:
        groups = [g.gr_name for g in grp.getgrall() if os.getuid() in g.gr_mem]
    except Exception:
        groups = []
    print(f"用户: {user} | UID: {os.getuid()}")
    print(f"组: {groups}")
    check_suid()
    check_sudo()
    if not args.quick:
        check_cron()
        check_writable()
    check_kernel()
    print("\n[*] 完成 — 进一步排查: GTFOBins / pspy / linpeas")

if __name__ == "__main__":
    main()