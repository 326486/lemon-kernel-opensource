#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
maint_server.py —— 小柠檬内核·备用维护通道 v1.0.0（261111 · lemon-user验收）
定位：主门面（slim_proxy 8791/8792）升级/维护时的保命线。
  - 独立进程、独立端口 127.0.0.1:8795，与主门面零共享内存，互不影响生死
  - 直连上游 lemoncore(8788)，主门面挂了照样全权可用
  - 只暴露 4 个保命工具：sh / file_read / file_write_text / upstream_ping
  - 独立令牌 .token_maint（缺失时回落 .token）；恒强制鉴权（无令牌则不监听公网用法）
  - 内置最小危险护栏（rm 毁根/dd 写设备/fork 炸弹/凭证读取）
配套：takin 控制台加第二条隧道 → 127.0.0.1:8795（一次性手动，见 README_v150.md）
"""

import hmac
import random
import json
import os
import re
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0.2"
LEMON_HOME = os.environ.get("LEMON_HOME", "/data/lemonbrain")
UPSTREAM = os.environ.get("LEMON_UPSTREAM", "http://127.0.0.1:8788")
PORT = int(os.environ.get("LEMON_MAINT_PORT", "8795"))
HOST = os.environ.get("LEMON_MAINT_HOST", "127.0.0.1")
LOG_DIR = os.path.join(LEMON_HOME, "logs")
LOG_FILE = os.path.join(LOG_DIR, "maint.log")
MAX_BODY = 1024 * 1024
MAX_OUT = 4096
PROTO = "2025-06-18"


def _load_token():
    for fn in (".token_maint", ".token"):
        try:
            with open(os.path.join(LEMON_HOME, "slimproxy", fn), "r", encoding="utf-8") as f:
                t = f.read().strip()
            if t:
                return t
        except Exception:
            pass
    return os.environ.get("LEMON_MAINT_TOKEN", "").strip()


# v1.0.1 热加载：mtime 变化即重读，轮换免重启
_TOK_MT = [None]
FAIL_COUNT = {}
FAIL_LOCK = threading.Lock()
def _hot_token():
    tk1 = os.path.join(LEMON_HOME, "slimproxy", ".token_maint")
    tk2 = os.path.join(LEMON_HOME, "slimproxy", ".token")
    def _mt(p):
        try: return os.stat(p).st_mtime_ns
        except Exception: return None
    mt = (_mt(tk1), _mt(tk2))
    if mt != _TOK_MT[0] or not hasattr(_hot_token, "_v"):
        _TOK_MT[0] = mt
        _hot_token._v = _load_token()
    return _hot_token._v


# ---- 最小危险护栏（保命通道也不能自毁） ----
_RULES = [
    ("rm 毁根", r"\brm\s+(-{1,2}[a-zA-Z][a-zA-Z-]*\s+)*[\"']?(/\*|/|/(data|system|vendor|dev|proc|sys))([\"'\s;|&)]|$)"),
    ("dd 写设备", r"\bdd\b[^|;]*\bof\s*=\s*[\"']?/dev/(?!(null|zero|full)([\"'\s;|&)]|$))"),
    ("fork 炸弹", r":\s*\(\s*\)\s*\{"),
    ("读凭证", r"(cat|base64|head|tail|strings)\b[^|;]*(\.token|\.tokens\.json)"),
    ("mkfs", r"\bmkfs[.\w-]*\s+[\"']?/dev/(?!(null|zero|full)([\"'\s;|&)]|$))"),
]


def guard(cmd):
    for label, pat in _RULES:
        try:
            if re.search(pat, cmd or ""):
                return label
        except Exception:
            pass
    return None


def log(msg):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        with open(LOG_FILE, "a", errors="ignore") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def rpc(method, params, timeout=60):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or {}}).encode("utf-8")
    req = urllib.request.Request(UPSTREAM + "/", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def clip(s):
    if not isinstance(s, str):
        return s
    b = s.encode("utf-8", "replace")
    if len(b) <= MAX_OUT:
        return s
    cut = b[:MAX_OUT]
    while cut and (cut[-1] & 0xC0) == 0x80:
        cut = cut[:-1]
    if cut and 0xC2 <= cut[-1] <= 0xF4:
        cut = cut[:-1]
    return cut.decode("utf-8", "ignore") + "\n[maint] 输出 %dB 超 %dB 上限（大文件请用 file_read 分段）" % (len(b), MAX_OUT)


TOOLS = [
    {"name": "sh", "description": "[维护] root 执行 shell（直通 lemoncore，带最小护栏）",
     "inputSchema": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}},
    {"name": "file_read", "description": "[维护] 分段读文件 {path, offset=0, limit=3968}",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}}, "required": ["path"]}},
    {"name": "file_write_text", "description": "[维护] 写文本文件 {path, text, append?}（直通 lemoncore）",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "text": {"type": "string"}, "append": {"type": "string"}}, "required": ["path", "text"]}},
    {"name": "upstream_ping", "description": "[维护] 探测上游 lemoncore 是否存活",
     "inputSchema": {"type": "object", "properties": {}}},
]


def do_file_read(args):
    a = args if isinstance(args, dict) else {}
    path = str(a.get("path") or "")
    if not path:
        return "用法：file_read {path, offset?, limit?}"
    if re.search(r"/\.token[^/]*$", path):
        return "[guard] 已拦截：读凭证文件"
    try:
        offset = max(0, int(a.get("offset") or 0))
    except Exception:
        offset = 0
    try:
        limit = int(a.get("limit") or (MAX_OUT - 128))
    except Exception:
        limit = MAX_OUT - 128
    limit = max(1, min(MAX_OUT - 128, limit))
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(offset)
            b = f.read(limit)
    except Exception as e:
        return "读取失败 %s: %r" % (path, e)
    while b and (b[-1] & 0xC0) == 0x80:
        b = b[:-1]
    if b and 0xC2 <= b[-1] <= 0xF4:
        b = b[:-1]
    next_off = offset + len(b)
    done = next_off >= size
    hint = "\n[file_read] %d/%dB" % (next_off, size)
    hint += "（已读完）" if done else "，下段 offset=%d" % next_off
    return b.decode("utf-8", "replace") + hint


def call_tool(name, args):
    """返回 (text, isError)"""
    if name == "sh":
        cmd = str((args or {}).get("cmd") or "")
        hit = guard(cmd)
        if hit:
            log("拦截 %s" % hit)
            return "[guard] 已拦截危险操作（%s）" % hit, True
        try:
            resp = rpc("tools/call", {"name": "sh", "arguments": {"cmd": cmd}}, timeout=120)
        except Exception as e:
            return "上游不可用: %r" % (e,), True
        return _extract(resp), False
    if name == "file_write_text":
        p = str((args or {}).get("path") or "")
        if re.search(r"/\.token[^/]*$", p) or re.match(r"^/(dev|proc|sys)/", p):
            return "[guard] 已拦截：写敏感路径", True
        try:
            resp = rpc("tools/call", {"name": "file_write_text", "arguments": args}, timeout=120)
        except Exception as e:
            return "上游不可用: %r" % (e,), True
        return _extract(resp), False
    if name == "file_read":
        return do_file_read(args), False
    if name == "upstream_ping":
        try:
            t0 = time.time()
            rpc("tools/list", {"lean": True}, timeout=10)
            return "上游存活（%.0fms）" % ((time.time() - t0) * 1000,), False
        except Exception as e:
            return "上游不可用: %r" % (e,), True
    return "未知工具: %s（维护通道只有 sh/file_read/file_write_text/upstream_ping）" % name, True


def _extract(resp):
    res = resp.get("result") or {}
    if resp.get("error"):
        return "上游错误: " + json.dumps(resp["error"], ensure_ascii=False)
    texts = [c.get("text", "") for c in (res.get("content") or [])
             if isinstance(c, dict) and c.get("type") == "text"]
    return clip("\n".join(texts) if texts else json.dumps(res, ensure_ascii=False))


def handle_rpc(req):
    rid = req.get("id")
    method = req.get("method") or ""
    params = req.get("params") or {}
    if method == "initialize":
        cv = params.get("protocolVersion") or ""
        ver = cv if cv in ("2024-11-05", "2025-03-26", "2025-06-18") else PROTO
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": ver, "capabilities": {"tools": {}},
            "serverInfo": {"name": "小柠檬内核·备用维护通道", "version": VERSION}}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        t0 = time.time()
        out, err = call_tool(params.get("name") or "", params.get("arguments") or {})
        log("%s err=%s %.0fms" % (params.get("name"), err, (time.time() - t0) * 1000))
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": out}], "isError": err}}
    if method in ("ping", "notifications/initialized", "notifications/cancelled"):
        if rid is None:
            return None
        return {"jsonrpc": "2.0", "id": rid, "result": {}}
    return {"jsonrpc": "2.0", "id": rid,
            "error": {"code": -32601, "message": "method not found: %s" % method}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LemonMaint/1.0.1"

    def log_message(self, fmt, *args):
        try:
            p = self.path
            _tk = _hot_token()
            if _tk and _tk in p:
                p = p.replace(_tk, "***T***")
            log("REQ %s %s" % (self.command, p))
        except Exception:
            pass

    def _auth_ok(self):
        # v1.0.2 安全加固：恒时比对 + 失败熔断(5次/30分钟)
        tok = _hot_token()
        if not tok:
            return False
        h = (self.headers.get("Authorization") or "").strip()
        ok = hmac.compare_digest(h, "Bearer " + tok)
        with FAIL_LOCK:
            if ok:
                FAIL_COUNT["n"] = 0
                FAIL_COUNT["until"] = 0
            elif time.time() < FAIL_COUNT.get("until", 0):
                ok = False
            else:
                # 261114 lemon-user拍板 四档阶梯: 错1次封10分钟 → 连错5次封30分钟 → 连错3次封128分钟 → 之后每错一次随机封24~360小时
                _tier = min(FAIL_COUNT.get("bans", 0), 3)
                _th, _sec = ((1, 600), (5, 1800), (3, 7680), (1, 0))[_tier]
                if _tier == 3:
                    _sec = random.randint(86400, 12960000)
                FAIL_COUNT["n"] = FAIL_COUNT.get("n", 0) + 1
                if FAIL_COUNT["n"] >= _th:
                    FAIL_COUNT["n"] = 0
                    FAIL_COUNT["until"] = time.time() + _sec
                    FAIL_COUNT["bans"] = min(FAIL_COUNT.get("bans", 0) + 1, 3)
                    log("SAFETY封禁第%d档: 连错%d次, 封%d秒%s(有效Token可解除)" % (_tier + 1, _th, _sec, "(随机24~360小时)" if _tier == 3 else ""))
        return ok

    def _send(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except Exception:
            pass

    def _deny(self):
        self._send({"jsonrpc": "2.0", "id": None,
                    "error": {"code": -32001, "message": "not found"}}, 404)

    def do_GET(self):
        if not self._auth_ok():
            self._deny()
            return
        self._send({"ok": True, "server": "小柠檬内核·备用维护通道", "version": VERSION,
                    "port": PORT, "upstream": UPSTREAM})

    def do_POST(self):
        if not self._auth_ok():
            self._deny()
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                self._send({"jsonrpc": "2.0", "id": None,
                            "error": {"code": -32600, "message": "payload too large"}}, 413)
                return
            raw = self.rfile.read(n) if n > 0 else b"{}"
            req = json.loads(raw.decode("utf-8", "replace") or "{}")
        except Exception as e:
            self._send({"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error: %r" % (e,)}}, 400)
            return
        resp = handle_rpc(req)
        if resp is None:
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send(resp)


def main():
    os.makedirs(LOG_DIR, exist_ok=True)
    if not _hot_token():
        log("致命：无令牌（.token_maint/.token 均空），拒绝裸奔启动")
        raise SystemExit("no token, refuse to start")
    log("=== maint_server v%s 启动 port=%d upstream=%s pid=%d ===" %
        (VERSION, PORT, UPSTREAM, os.getpid()))
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    try:
        srv.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        log("收到中断，退出")


if __name__ == "__main__":
    main()
