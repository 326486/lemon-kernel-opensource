#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# audit_learn 运营经验蒸馏 v1.0 (261114 千问) — 自主神经 Phase C 学习
# 从 audit.jsonl 提炼每工具调用量/失败率/延迟，标记异常（高失败/慢）
import json, sys
from collections import defaultdict
AUDIT = "/data/lemonbrain/logs/audit.jsonl"

def parse_audit(lines):
    stats = defaultdict(lambda: {"count": 0, "fail": 0, "ms_sum": 0, "ms_max": 0})
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            j = json.loads(line)
        except Exception:
            continue
        s = stats[j.get("tool", "?")]
        s["count"] += 1
        if not j.get("ok", True):
            s["fail"] += 1
        ms = j.get("ms", 0) or 0
        s["ms_sum"] += ms
        s["ms_max"] = max(s["ms_max"], ms)
    out = []
    for t, s in stats.items():
        out.append({"tool": t, "count": s["count"], "fail": s["fail"],
                    "fail_rate": round(s["fail"] / s["count"], 3) if s["count"] else 0,
                    "avg_ms": round(s["ms_sum"] / s["count"], 1) if s["count"] else 0,
                    "max_ms": s["ms_max"]})
    return sorted(out, key=lambda x: -x["count"])

def flag_anomalies(stats, fail_thresh=0.2, slow_ms=5000):
    flags = []
    for s in stats:
        if s["count"] >= 5 and s["fail_rate"] >= fail_thresh:
            flags.append({"tool": s["tool"], "issue": "high_fail_rate", "value": s["fail_rate"]})
        if s["count"] >= 5 and s["avg_ms"] >= slow_ms:
            flags.append({"tool": s["tool"], "issue": "slow", "value": s["avg_ms"]})
    return flags

def learn(path=AUDIT, tail=5000):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()[-tail:]
    except Exception:
        lines = []
    stats = parse_audit(lines)
    return {"total_records": len(lines), "tool_count": len(stats),
            "top_tools": stats[:15], "anomalies": flag_anomalies(stats)}

def main():
    print(json.dumps(learn(), ensure_ascii=False))

if __name__ == "__main__":
    main()