#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# homeostasis 稳态监测 v1.0 (261114 千问) — 自主神经 Phase A · 内环境感知（L0）
import os, json, subprocess

def read_load():
    try:
        return float(open("/proc/loadavg").read().split()[0])
    except Exception:
        return 0.0

def read_mem():
    info = {}
    try:
        for line in open("/proc/meminfo"):
            p = line.split()
            if len(p) >= 2:
                info[p[0].rstrip(":")] = int(p[1])
    except Exception:
        pass
    return {"total_mb": info.get("MemTotal", 0) // 1024, "avail_mb": info.get("MemAvailable", 0) // 1024}

def read_disk():
    try:
        r = subprocess.run(["sh", "-c", "df /data | tail -1"], capture_output=True, text=True, timeout=5)
        for p in r.stdout.split():
            if p.endswith("%"):
                return int(p.rstrip("%"))
    except Exception:
        pass
    return 0

def read_temp():
    mx = 0
    try:
        for z in os.listdir("/sys/class/thermal"):
            if z.startswith("thermal_zone"):
                try:
                    t = int(open("/sys/class/thermal/%s/temp" % z).read().strip())
                    if t > 1000:
                        t //= 1000
                    mx = max(mx, t)
                except Exception:
                    continue
    except Exception:
        pass
    return mx

def assess(load, mem_avail_mb, disk_pct, temp):
    alerts = []
    if load > 20:
        alerts.append("load_high")
    if 0 < mem_avail_mb < 500:
        alerts.append("mem_low")
    if disk_pct > 90:
        alerts.append("disk_full")
    if temp > 80:
        alerts.append("temp_high")
    if "mem_low" in alerts or "disk_full" in alerts or "temp_high" in alerts:
        status = "critical"
    elif alerts:
        status = "warn"
    else:
        status = "ok"
    return {"alerts": alerts, "status": status}

def snapshot():
    load = read_load()
    mem = read_mem()
    disk = read_disk()
    temp = read_temp()
    a = assess(load, mem["avail_mb"], disk, temp)
    return {"load": load, "mem": mem, "disk_pct": disk, "temp_max": temp,
            "alerts": a["alerts"], "status": a["status"]}

def main():
    print(json.dumps(snapshot(), ensure_ascii=False))

if __name__ == "__main__":
    main()