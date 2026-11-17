#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# self_audit 安全自审计 v1.0 (261114 千问) — 自主神经 Phase D 管理
# 证书到期 + 令牌文件权限 + 非回环暴露端口
import os, sys, json, subprocess, time, ssl, socket, datetime
CERT_HOST = "e9f4868ff04e49fd87fe37e36fbc826f.hn.takin.cc"

def parse_cert_date(na):
    return datetime.datetime.strptime(na, "%b %d %H:%M:%S %Y %Z")

def cert_expiry(host=CERT_HOST, port=443):
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as s:
                cert = s.getpeercert()
                na = cert.get("notAfter")
                days = (parse_cert_date(na) - datetime.datetime.utcnow()).days
                return {"notAfter": na, "days_left": days, "alert": days < 14}
    except Exception as e:
        return {"error": type(e).__name__}

def token_perms(path="/data/lemonbrain/slimproxy/.tokens.json"):
    try:
        mode = oct(os.stat(path).st_mode & 0o777)
        return {"mode": mode, "ok": mode in ("0o600", "0o400")}
    except Exception as e:
        return {"error": type(e).__name__}

def nonloopback_ports():
    try:
        r = subprocess.run(["sh", "-c", "netstat -tln 2>/dev/null | grep LISTEN | grep -vE '127.0.0.1|::1' | head -10"],
                           capture_output=True, text=True, timeout=10)
        lines = [l for l in r.stdout.strip().split("\n") if l]
        return {"count": len(lines), "lines": lines}
    except Exception:
        return {"count": 0, "lines": []}

def audit():
    return {"ts": int(time.time()), "cert": cert_expiry(),
            "token_perms": token_perms(), "nonloopback": nonloopback_ports()}

def main():
    print(json.dumps(audit(), ensure_ascii=False))

if __name__ == "__main__":
    main()