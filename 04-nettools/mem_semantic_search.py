#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# mem_semantic_search 混合语义检索 v1.1 (261114 千问) — 自主神经 Phase B 记忆固化
# TF-IDF 召回（RAG2，4段输出）+ LLM 语义重排（qwen3.8-27b）；LLM 失败自动降级 TF-IDF 序
import sys, json, subprocess, re
PY = "/data/data/com.termux/files/usr/bin/python3"
RAG = "/data/lemonbrain/mind/rag2_query.py"
AI = "/data/lemonbrain/mind/ai_call.py"

def parse_rag2(text):
    out = []
    for line in (text or "").strip().split("\n"):
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 4 and parts[2]:
            label = parts[1]
            mnum = re.search(r"#(\d+)", label)
            out.append({"score": parts[0], "ref": label,
                        "num": ("#" + mnum.group(1)) if mnum else "",
                        "title": parts[2], "path": parts[3]})
    return out

def recall(query, k=15):
    try:
        r = subprocess.run([PY, RAG, query, str(k)], capture_output=True, text=True, timeout=60)
        return parse_rag2(r.stdout)
    except Exception:
        return []

def llm_rerank(query, candidates, topk=5):
    if not candidates:
        return []
    listing = "\n".join("%d. [%s] %s" % (i + 1, c["ref"], c["title"])
                        for i, c in enumerate(candidates))
    prompt = ("查询：%s\n候选记忆条目：\n%s\n请按与查询的语义相关度从高到低选出最相关的前%d条，"
              "仅返回编号JSON数组如[3,1,5]，不要其他文字。" % (query, listing, topk))
    try:
        r = subprocess.run([PY, AI, "--model", "qwen3.8-27b", "--prompt", prompt,
                            "--json", "--max-tokens", "500"], capture_output=True, text=True, timeout=90)
        j = json.loads(r.stdout)
        content = j["choices"][0]["message"]["content"] or ""
        m = re.search(r"\[[\d,\s]+\]", content)
        if m:
            order = json.loads(m.group(0))
            ranked, seen = [], set()
            for i in order:
                if isinstance(i, int) and 1 <= i <= len(candidates) and i not in seen:
                    ranked.append(candidates[i - 1]); seen.add(i)
            for idx, c in enumerate(candidates, 1):
                if idx not in seen:
                    ranked.append(c)
            return ranked[:topk]
    except Exception:
        pass
    return candidates[:topk]

def search(query, k=5):
    cands = recall(query, max(k * 3, 15))
    ranked = llm_rerank(query, cands, k)
    return {"query": query, "method": "hybrid_tfidf_llm", "recall_count": len(cands),
            "results": ranked[:k]}

def main():
    if len(sys.argv) < 2:
        print("usage: mem_semantic_search.py <query> [topk]"); sys.exit(2)
    q = sys.argv[1]
    k = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    print(json.dumps(search(q, k), ensure_ascii=False))

if __name__ == "__main__":
    main()