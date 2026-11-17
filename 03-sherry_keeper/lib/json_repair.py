#!/usr/bin/env python3
# json_repair.py — ReAct 动作参数 JSON 修复（模型偶发输出 {path:/data} 类非法 JSON）
# 合法→原样；可修复→补引号（数字/布尔保持原类型）；不可修复→{}
import sys, json, re
s = sys.stdin.read().strip()
try:
    json.loads(s)
    print(s)
except Exception:
    s2 = re.sub(r'([{,])\s*([A-Za-z_][A-Za-z0-9_]*)\s*:', r'\1"\2":', s)
    def fix_val(m):
        v = m.group(1).strip()
        if re.fullmatch(r'-?\d+(\.\d+)?|true|false|null', v):
            return ':' + v
        return ':"' + v + '"'
    s2 = re.sub(r':\s*([^",{}\[\]][^,{}\[\]]*)(?=[,}\]])', fix_val, s2)
    try:
        json.loads(s2)
        print(s2)
    except Exception:
        print('{}')
