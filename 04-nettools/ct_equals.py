#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ct_equals.py —— 恒时字符串比较（取长补短·源自 MT论坛Pro McpServerManager.constantTimeEquals）
# 用法：python3 ct_equals.py <a> <b>；相等 exit 0 输出 true，不等 exit 1 输出 false
# 原理：逐字节异或累积（长度差也纳入累积），无论何处不同耗时恒定，防时序攻击侧信道
import sys, json

def constant_time_equals(a: str, b: str) -> bool:
    x = a.encode('utf-8')
    y = b.encode('utf-8')
    diff = len(x) ^ len(y)
    n = max(len(x), len(y))
    for i in range(n):                      # 有界循环
        bx = x[i] if i < len(x) else 0
        by = y[i] if i < len(y) else 0
        diff |= bx ^ by
    return diff == 0

def main() -> int:
    if len(sys.argv) != 3:
        print(json.dumps({"ok": False, "error": "用法: ct_equals <a> <b>"}, ensure_ascii=False)); return 2
    eq = constant_time_equals(sys.argv[1], sys.argv[2])
    print(json.dumps({"ok": True, "equal": eq}, ensure_ascii=False))
    return 0 if eq else 1

if __name__ == '__main__':
    sys.exit(main())