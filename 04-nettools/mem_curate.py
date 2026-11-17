#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# mem_curate 记忆策展 v1.0 (261114 千问) — 自主神经 Phase B 记忆固化
# 标题相似度查重复候选 + 分库统计；L2 只提议不自动修改记忆
import os, sys, json, re, glob
from collections import defaultdict
MEM = "/data/小柠檬资源/小柠檬记忆中心"

def load_entries():
    entries = []
    for p in glob.glob(MEM + "/**/#*.md", recursive=True):
        fn = os.path.basename(p)
        m = re.match(r"#(\d+)-(.+)\.md$", fn)
        if m:
            segs = p.split("/")
            lib = segs[5] if len(segs) > 5 else ""
            entries.append({"num": "#" + m.group(1), "title": m.group(2), "path": p, "lib": lib})
    return entries

def title_tokens(t):
    return set(re.findall(r"[\u4e00-\u9fff]{2}|[a-z0-9]+", t.lower()))

def find_dup_candidates(entries, thresh=0.6):
    used, clusters = set(), []
    toks = [title_tokens(e["title"]) for e in entries]
    for i in range(len(entries)):
        if i in used or not toks[i]:
            continue
        group = [i]
        for j in range(i + 1, len(entries)):
            if j in used or not toks[j]:
                continue
            inter = len(toks[i] & toks[j])
            union = len(toks[i] | toks[j])
            if union and inter / union >= thresh:
                group.append(j); used.add(j)
        if len(group) > 1:
            used.add(i)
            clusters.append([entries[x] for x in group])
    return clusters

def curate(thresh=0.6):
    entries = load_entries()
    dups = find_dup_candidates(entries, thresh)
    bylib = defaultdict(int)
    for e in entries:
        bylib[e["lib"]] += 1
    return {"total_entries": len(entries), "by_lib": dict(bylib),
            "dup_cluster_count": len(dups), "dup_clusters": dups[:20],
            "note": "L2提议：重复候选需人工确认合并，不自动修改记忆"}

def main():
    th = float(sys.argv[1]) if len(sys.argv) > 1 else 0.6
    print(json.dumps(curate(th), ensure_ascii=False))

if __name__ == "__main__":
    main()