#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# llm_route 智能模型路由 v1.0 (261114 千问) — 自主神经 Phase E 皮层
# 按任务复杂度/模式选模型：fast/strong/reason/cross/auto；复用 13 模型网关
import sys, json, subprocess
PY = "/data/data/com.termux/files/usr/bin/python3"
AI = "/data/lemonbrain/mind/ai_call.py"
FAST = "deepseek-v4.1-flash-1017"
STRONG = "qwen3.8-27b"
REASON = "kimi-k3.1-pro"
STRONG_KW = ["推理", "证明", "分析", "设计", "架构", "复杂", "为什么", "原理", "算法", "审计", "对比", "评估", "方案"]

def choose_model(prompt, mode="auto"):
    if mode == "fast":
        return FAST, "manual:fast"
    if mode == "strong":
        return STRONG, "manual:strong"
    if mode == "reason":
        return REASON, "manual:reason"
    if mode == "cross":
        return STRONG, "cross:primary"
    p = prompt or ""
    if len(p) > 200 or any(k in p for k in STRONG_KW):
        return STRONG, "auto:complex_or_long->strong"
    return FAST, "auto:simple->fast"

def call_model(model, prompt, max_tokens=800):
    import time as _t
    _t0 = _t.time()
    try:
        r = subprocess.run([PY, AI, "--model", model, "--prompt", prompt, "--json",
                            "--max-tokens", str(max_tokens)], capture_output=True, text=True, timeout=120)
        j = json.loads(r.stdout)
        _content = j["choices"][0]["message"]["content"] or ""
        try:
            import route_feedback; route_feedback.log_call(model, True, latency=_t.time() - _t0)
        except Exception:
            pass
        return _content
    except Exception as e:
        try:
            import route_feedback; route_feedback.log_call(model, False, error=type(e).__name__)
        except Exception:
            pass
        return "[error:%s]" % type(e).__name__

def route(prompt, mode="auto", max_tokens=800):
    model, why = choose_model(prompt, mode)
    if mode == "cross":
        m2 = REASON if model != REASON else STRONG
        return {"mode": "cross", "models": [model, m2], "rationale": why,
                "responses": [{"model": model, "content": call_model(model, prompt, max_tokens)},
                              {"model": m2, "content": call_model(m2, prompt, max_tokens)}]}
    return {"mode": mode, "model": model, "rationale": why,
            "content": call_model(model, prompt, max_tokens)}

def main():
    prompt = sys.argv[1] if len(sys.argv) > 1 else ""
    mode = sys.argv[2] if len(sys.argv) > 2 else "auto"
    mt = int(sys.argv[3]) if len(sys.argv) > 3 else 800
    print(json.dumps(route(prompt, mode, mt), ensure_ascii=False))

if __name__ == "__main__":
    main()