#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# waf_acw_solver.py —— 阿里云盾 WAF acw_sc__v2 挑战求解器（取长补短·源自 MT论坛Pro 4.7.9 AcwChallengeInterceptor 逆向）
# 用法：
#   python3 waf_acw_solver.py --arg1 <40位hex>
#   python3 waf_acw_solver.py --file <挑战页HTML路径>
#   echo '<挑战页HTML>' | python3 waf_acw_solver.py
# 输出：JSON {ok, arg1, cookie, full_header}
# 算法：arg1 → BOX(40) 位置换(unsbox) → 与 HEX_KEY 逐字节异或(hexXor) → acw_sc__v2
import sys, re, json

BOX = [15,35,29,24,33,16,1,38,10,9,19,31,40,27,22,23,25,13,6,11,39,18,20,8,14,21,32,26,2,30,7,4,17,5,3,28,34,37,12,36]
HEX_KEY = "3000176000856006061501533003690027800375"
ARG1_RE = re.compile(r"var\s+arg1\s*=\s*'([0-9a-fA-F]+)'")

def unsbox(s: str) -> str:
    n = len(BOX)
    out = [''] * n
    for i, ch in enumerate(s):           # 有界循环：len(s) 固定
        j = BOX.index(i + 1) if (i + 1) in BOX else -1
        if 0 <= j < n:
            out[j] = ch
    return ''.join(out)

def hexxor(s: str) -> str:
    res = []
    lim = min(len(s), len(HEX_KEY))
    for k in range(0, lim - 1, 2):       # 有界循环
        a = int(s[k:k+2], 16)
        b = int(HEX_KEY[k:k+2], 16)
        res.append('%02x' % (a ^ b))
    return ''.join(res)

def solve(arg1: str) -> str:
    return hexxor(unsbox(arg1))

def main() -> int:
    arg1 = None
    src = None
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):                  # 有界：i 每轮必 +1 或 +2，哨兵保推进
        a = argv[i]
        if a == '--arg1' and i + 1 < len(argv):
            arg1 = argv[i+1]; i += 2; continue
        if a == '--file' and i + 1 < len(argv):
            try:
                with open(argv[i+1], 'r', encoding='utf-8', errors='replace') as f:
                    src = f.read()
            except OSError as e:
                print(json.dumps({"ok": False, "error": "read file failed: %s" % e}, ensure_ascii=False)); return 2
            i += 2; continue
        i += 1
    if arg1 is None and src is None and not sys.stdin.isatty():
        src = sys.stdin.read()
    if arg1 is None and src:
        stripped = src.strip()
        if re.fullmatch(r'[0-9a-fA-F]{40}', stripped):
            arg1 = stripped
        else:
            m = ARG1_RE.search(src)
            if m:
                arg1 = m.group(1)
    if not arg1:
        print(json.dumps({"ok": False, "error": "未提供 arg1，也未能从输入中提取 var arg1='...'（挑战页需含该 JS 片段）"}, ensure_ascii=False))
        return 2
    arg1 = arg1.strip()
    if not re.fullmatch(r'[0-9a-fA-F]+', arg1):
        print(json.dumps({"ok": False, "error": "arg1 不是合法 hex 字符串"}, ensure_ascii=False)); return 2
    warn = None
    if len(arg1) != len(BOX):
        warn = "arg1 长度 %d != %d（标准阿里云盾 v2 挑战为 40 位），已按截断/补空处理，结果可能无效" % (len(arg1), len(BOX))
    cookie = solve(arg1)
    print(json.dumps({
        "ok": True, "arg1": arg1, "cookie": cookie,
        "full_header": "Cookie: acw_sc__v2=%s" % cookie,
        "warn": warn,
        "source": "MT论坛Pro AcwChallengeInterceptor 逆向移植（BOX置换+hexXor）",
    }, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    sys.exit(main())