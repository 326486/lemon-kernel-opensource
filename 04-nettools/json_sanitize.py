#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# json_sanitize.py —— JSON 递归敏感字段脱敏（取长补短·源自 MT论坛Pro McpServerManager.sanitize）
# 用法：
#   echo '{"password":"x","data":{"qq":"123"}}' | python3 json_sanitize.py
#   python3 json_sanitize.py --file a.json
#   python3 json_sanitize.py --text '{"token":"t1"}'
# 行为：递归遍历对象/数组，命中敏感键的成员【整键丢弃】（与原实现一致，非打码）
import sys, json

SENSITIVE_KEYS = {
    "cookie", "cookies", "cookiestring", "password", "passwd", "token",
    "accesstoken", "refresh token", "refreshtoken", "secret", "authorization",
    "formhash", "registerip", "realname", "qq", "sessionkey",
    # 内核扩展：
    "apikey", "api_key", "privatekey", "private_key", "mnemonic", "seed",
    "sessionid", "session_id", "bearer",
}

def sanitize(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if str(k).lower() in SENSITIVE_KEYS:
                continue
            out[k] = sanitize(v)
        return out
    if isinstance(obj, list):
        return [sanitize(x) for x in obj]   # 有界：len 固定
    return obj

def main() -> int:
    text, args = None, sys.argv[1:]
    i = 0
    while i < len(args):                     # 有界推进
        if args[i] == '--text' and i + 1 < len(args):
            text = args[i+1]; i += 2; continue
        if args[i] == '--file' and i + 1 < len(args):
            try:
                with open(args[i+1], 'r', encoding='utf-8', errors='replace') as f:
                    text = f.read()
            except OSError as e:
                print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)); return 2
            i += 2; continue
        i += 1
    if text is None and not sys.stdin.isatty():
        text = sys.stdin.read()
    if not text:
        print(json.dumps({"ok": False, "error": "无输入：用 --text / --file / 管道传入 JSON"}, ensure_ascii=False)); return 2
    try:
        obj = json.loads(text)
    except ValueError as e:
        print(json.dumps({"ok": False, "error": "JSON 解析失败: %s" % e}, ensure_ascii=False)); return 2
    safe = sanitize(obj)
    print(json.dumps({"ok": True, "result": safe, "sanitized_json": json.dumps(safe, ensure_ascii=False)}, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    sys.exit(main())