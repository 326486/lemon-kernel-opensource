#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# chain_health 五层链路健康探针 v1.0 (261114 千问)
# 自主神经系统 Phase A · 反射传感器（L0 观察）
# 五层：gate8796 / facade8792 / kernel8788 / satellite8790 / tunnel(zeronews)
import socket, time, json, subprocess, http.client

LAYERS = [("gate", "127.0.0.1", 8796), ("facade", "127.0.0.1", 8792),
          ("kernel", "127.0.0.1", 8788), ("satellite", "127.0.0.1", 8790)]

def tcp_probe(host, port, timeout=2.5):
    t0 = time.time()
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True, round((time.time() - t0) * 1000, 1), "tcp_open"
    except Exception as e:
        return False, round((time.time() - t0) * 1000, 1), type(e).__name__

def http_probe(host, port, timeout=3):
    t0 = time.time()
    try:
        c = http.client.HTTPConnection(host, port, timeout=timeout)
        c.request("GET", "/")
        r = c.getresponse()
        r.read()
        c.close()
        return True, round((time.time() - t0) * 1000, 1), "http_%d" % r.status
    except Exception as e:
        return False, round((time.time() - t0) * 1000, 1), type(e).__name__

def proc_alive(name):
    try:
        r = subprocess.run(["sh", "-c", "ps -ef | grep -v grep | grep -c '%s'" % name],
                           capture_output=True, text=True, timeout=5)
        return int(r.stdout.strip() or 0) > 0
    except Exception:
        return False

def compute_verdict(layers):
    ups = sum(1 for v in layers.values() if v.get("up"))
    total = len(layers)
    if total and ups == total:
        return "healthy"
    if layers.get("kernel", {}).get("up") and ups >= total - 1:
        return "degraded"
    return "down"

def probe_all():
    layers = {}
    for name, host, port in LAYERS:
        up, ms, detail = tcp_probe(host, port)
        if up and name in ("gate", "facade", "kernel"):
            up, ms, detail = http_probe(host, port)
        layers[name] = {"up": up, "latency_ms": ms, "detail": detail}
    tun = proc_alive("zeronews")
    layers["tunnel"] = {"up": tun, "latency_ms": 0, "detail": "zeronews_proc" if tun else "no_proc"}
    return {"verdict": compute_verdict(layers),
            "up": sum(1 for v in layers.values() if v["up"]),
            "total": len(layers), "layers": layers, "ts": int(time.time())}

def main():
    print(json.dumps(probe_all(), ensure_ascii=False))

if __name__ == "__main__":
    main()