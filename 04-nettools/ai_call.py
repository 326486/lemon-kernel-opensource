#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Lemon Swarm · AI 后端通用调用器 v1.0 (261110)
# 网关: https://discovery-api.intern-ai.org.cn/v1 (上海AI实验室 InternAgent · 13模型)
# 用法:
#   ai_call.py --list                          列模型
#   ai_call.py --model X --prompt "..." [--system "..."] [--max-tokens N] [--json]
# key 存 /data/lemonbrain/vault/ai_intern_key.txt (chmod 600)
import os, sys, json, urllib.request

BASE = "https://discovery-api.intern-ai.org.cn/v1"
KEYF = "/data/lemonbrain/vault/ai_intern_key.txt"
DEF_MODEL = "deepseek-v4.1-flash-1017"

def key():
    try:
        k = open(KEYF).read().strip()
        if k.startswith("sk-") and len(k) > 20:
            return k
    except Exception:
        pass
    print("[ai_call] FAIL: key 缺失/无效（vault/ai_intern_key.txt）"); sys.exit(1)

def post(path, payload, timeout):
    req = urllib.request.Request(BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + key(),
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))

def main():
    a = sys.argv
    if "--list" in a:
        rq = urllib.request.Request(BASE + "/models", headers={"Authorization": "Bearer " + key()})
        with urllib.request.urlopen(rq, timeout=20) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
        for m in d.get("data", []):
            print(m["id"])
        return
    model, prompt, system, mt, raw = DEF_MODEL, "", "", 4096, "--json" in a
    i = 1
    while i < len(a):                      # 有界遍历
        def val(j):     # 值必须存在且不是下一个开关(防空串替换误吞)
            return j < len(a) and not a[j].startswith("--")
        if a[i] == "--model":
            if val(i+1): model = a[i+1]; i += 2
            else: i += 1                      # 空值开关直接跳过
        elif a[i] == "--prompt":
            if val(i+1): prompt = a[i+1]; i += 2
            else: i += 1
        elif a[i] == "--system":
            if val(i+1): system = a[i+1]; i += 2
            else: i += 1
        elif a[i] == "--max-tokens":
            if val(i+1):
                try: mt = int(a[i+1])
                except ValueError: pass
                i += 2
            else: i += 1
        elif a[i] == "--json": raw = True; i += 1
        else: print("参数不认识:", a[i]); sys.exit(2)
    if not prompt:
        print("用法: ai_call.py [--list] --model X --prompt ... [--system ...] [--max-tokens N] [--json]")
        sys.exit(2)
    msgs = []
    if system: msgs.append({"role": "system", "content": system})
    msgs.append({"role": "user", "content": prompt})
    d = post("/chat/completions", {"model": model, "messages": msgs,
                                   "max_tokens": mt}, 120)
    if raw:
        print(json.dumps(d, ensure_ascii=False))
        return
    try:
        c = d["choices"][0]["message"]
        out = c.get("content", "").strip()
        print(out if out else json.dumps(d, ensure_ascii=False)[:2000])
    except Exception:
        print(json.dumps(d, ensure_ascii=False)[:2000])

if __name__ == "__main__":
    main()