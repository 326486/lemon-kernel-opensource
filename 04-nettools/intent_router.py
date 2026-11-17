#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# intent_router 自然语言工具发现 v1.0 (261114 千问) — 自主神经 Phase E 皮层
# NL 任务 → LLM 提取关键字 → tool_find 返回候选工具
import sys, json, subprocess, http.client
PY = "/data/data/com.termux/files/usr/bin/python3"
AI = "/data/lemonbrain/mind/ai_call.py"

def extract_keywords(query):
    prompt = ("任务：从用户描述提取用于搜索工具的核心关键字（3-5个，空格分隔，仅输出关键字）。\n"
              "示例：\n输入：我想看设备电池健康状态\n输出：电池 健康 设备\n"
              "输入：帮我分析这段代码的性能问题\n输出：代码 性能 分析\n"
              "输入：清理一下日志文件\n输出：日志 清理 文件\n"
              "现在提取：\n输入：%s\n输出：" % query)
    try:
        r = subprocess.run([PY, AI, "--model", "qwen3.8-27b", "--prompt", prompt,
                            "--json", "--max-tokens", "150"], capture_output=True, text=True, timeout=60)
        j = json.loads(r.stdout)
        kw = (j["choices"][0]["message"]["content"] or "").strip().split("\n")[0].strip()
        if kw and kw != query and len(kw) <= len(query):
            return kw
    except Exception:
        pass
    return query

def find_tools(keywords, limit=5):
    try:
        tok = json.load(open("/data/lemonbrain/slimproxy/.tokens.json", encoding="utf-8"))["root"]
        c = http.client.HTTPConnection("127.0.0.1", 8792, timeout=15)
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": "tool_find", "arguments": {"q": keywords, "limit": limit}}})
        c.request("POST", "/", body, {"Content-Type": "application/json", "Authorization": "Bearer " + tok})
        r = c.getresponse()
        j = json.loads(r.read().decode("utf-8", "replace"))
        c.close()
        return j.get("result", {}).get("content", [{}])[0].get("text", "")
    except Exception as e:
        return "[err:%s]" % type(e).__name__

def suggest(query):
    kw = extract_keywords(query)
    return {"query": query, "keywords": kw, "tools": find_tools(kw)}

def main():
    q = sys.argv[1] if len(sys.argv) > 1 else ""
    print(json.dumps(suggest(q), ensure_ascii=False))

if __name__ == "__main__":
    main()