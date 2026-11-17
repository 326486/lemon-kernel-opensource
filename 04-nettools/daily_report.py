#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# daily_report 自主神经日报 v1.0 (261114 千问) — 自主神经 Phase D 管理
# 聚合 chain_health + homeostasis + audit_learn + review_sched → 日报
import sys, json, time
sys.path.insert(0, "/data/lemonbrain/autonomic")
import chain_health, homeostasis, audit_learn, review_sched

def report():
    h = chain_health.probe_all()
    ho = homeostasis.snapshot()
    al = audit_learn.learn()
    due = review_sched.due()
    md = ["# 自主神经日报 %s" % time.strftime("%Y-%m-%d %H:%M"),
          "- 链路: %s (%d/%d 层 up)" % (h["verdict"], h["up"], h["total"]),
          "- 稳态: %s | load %.1f | 内存可用 %dMB | 磁盘 %d%% | 温度 %d°C" % (
              ho["status"], ho["load"], ho["mem"]["avail_mb"], ho["disk_pct"], ho["temp_max"]),
          "- 工具异常: %d 项" % len(al["anomalies"]),
          "- 待复习: %d 条" % len(due)]
    if al["anomalies"]:
        md.append("- 异常明细: " + ", ".join("%s(%s)" % (a["tool"], a["issue"]) for a in al["anomalies"][:5]))
    return {"ts": int(time.time()), "health": h["verdict"], "homeo": ho["status"],
            "anomaly_count": len(al["anomalies"]), "reviews_due": len(due),
            "markdown": "\n".join(md)}

def main():
    r = report()
    if "--md" in sys.argv:
        print(r["markdown"])
    else:
        print(json.dumps(r, ensure_ascii=False))

if __name__ == "__main__":
    main()