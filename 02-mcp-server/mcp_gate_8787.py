#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# MCP 令牌闸 v2.3 (8787 前置 + 门面透传) · 20261114 四档封禁阶梯
# 路径分流: /mt 或 /mt/*  -> 令牌校验后转发 127.0.0.1:8787 (前缀剥离, 剥离 Authorization)
#           其余路径/方法 -> 原样透传 127.0.0.1:8792 (门面自带鉴权, 闸不校验不修改)
# 纪律: 只新增本文件, 不改动原服务; 令牌与门面同源(.tokens.json root, mtime 热加载)
# 防空转(#249/#81): 上游读全部带超时, 响应循环遇 EOF 必终止, sock 超时兜底; 守护模式
# v2.3 四档封禁阶梯(lemon-user拍板): 第1档错1次封10分钟 → 第2档连错5次封30分钟 → 第3档连错3次封128分钟 → 第4档起每错一次随机封24~360小时
#            ①恒时令牌比对(防时序侧信道) ②每次鉴权失败延迟1秒(拖慢暴力破解) ③全部行为留日志
import http.client, hmac, json, os, random, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = 8796
BACKEND_HOST = "127.0.0.1"
MT_PORT = 8787          # MT 管理器 lemon-mcp-root (无鉴权, 由闸强制令牌)
FACADE_PORT = 8793      # slim 门面 (自带鉴权, 透传)
MT_PREFIX = "/mt"
TOKENS_FILE = "/data/lemonbrain/slimproxy/.tokens.json"
LOG_FILE = "/data/local/tmp/gate_8787.log"
LOG_MAX = 1024 * 1024
CONNECT_TIMEOUT = 10
IO_TIMEOUT = 330
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
       "trailers", "transfer-encoding", "upgrade", "host", "content-length"}
# 四档封禁阶梯: (连错阈值, 封禁秒数); 第4档起每错一次随机封24~360小时
BAN_TIERS = ((1, 600.0), (5, 1800.0), (3, 7680.0), (1, 0.0))
MAX_BODY = 1024 * 1024        # 请求体上限1MB，与门面对齐（261114加固 P1-A）
_conn_sem = threading.Semaphore(64)  # 并发连接帽（261114加固 P2-B）

_tok = {"mtime": None, "root": None}
_lock = threading.Lock()
_fail_lock = threading.Lock()
_fail_n = 0               # 当前档位连续失败计数
_tier = 0                 # 当前档位(0/1/2/3)
_ban_until = 0.0          # 封禁截止

def log(msg):
    msg = str(msg).replace("\r", " ").replace("\n", " ")
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX:
            open(LOG_FILE, "w").close()
        with open(LOG_FILE, "a", errors="ignore") as f:
            f.write("%s %s\n" % (time.strftime("%Y%m%d-%H%M%S"), msg))
    except Exception:
        pass

def root_token():
    with _lock:
        try:
            mt = os.stat(TOKENS_FILE).st_mtime_ns
        except Exception:
            _tok["root"] = None; _tok["mtime"] = None; return None
        if mt != _tok["mtime"]:
            try:
                d = json.load(open(TOKENS_FILE, encoding="utf-8"))
                _tok["root"] = (d.get("root") or "").strip() or None
            except Exception:
                _tok["root"] = None
            _tok["mtime"] = mt
        return _tok["root"]

def mt_auth_success():
    # 有效令牌成功: 清零当前档连错计数(档位保留)
    global _fail_n
    with _fail_lock:
        _fail_n = 0

def mt_auth_fail_record():
    global _fail_n, _tier, _ban_until
    now = time.time()
    with _fail_lock:
        if now < _ban_until:
            return
        th, sec = BAN_TIERS[_tier]
        _fail_n += 1
        if _fail_n >= th:
            if _tier == 3:
                sec = random.randint(86400, 12960000)   # 第4档: 每错一次随机封24~360小时
            _ban_until = now + sec
            _fail_n = 0
            _disp = _tier + 1
            if _tier < 3:
                _tier += 1
            log("RATELIMIT 第%d档封禁: 连错%d次, 封%d秒%s" % (_disp, th, int(sec), "(随机24~360小时)" if _disp == 4 else ""))

def mt_auth_banned():
    return time.time() < _ban_until

class Handler(BaseHTTPRequestHandler):
    def _deny(self, code, msg):
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self): self._proxy()
    def do_POST(self): self._proxy()
    def do_PUT(self): self._proxy()
    def do_DELETE(self): self._proxy()
    def do_PATCH(self): self._proxy()
    def do_HEAD(self): self._proxy()
    def _proxy(self):
        if not _conn_sem.acquire(blocking=False):
            return self._deny(503, "too many connections")
        try:
            self._proxy_inner()
        finally:
            _conn_sem.release()
    def _proxy_inner(self):
        path = self.path
        is_mt = path == MT_PREFIX or path.startswith(MT_PREFIX + "/")
        backend_port = MT_PORT if is_mt else FACADE_PORT
        fwd_path = path[len(MT_PREFIX):] or "/" if is_mt else path
        fwd = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        if is_mt:
            auth = (self.headers.get("Authorization") or "").strip()
            expect = root_token()
            ok = bool(expect) and hmac.compare_digest(auth, "Bearer " + expect)
            if not ok:
                if mt_auth_banned():
                    log("RATELIMIT %s %s from %s" % (self.command, path, self.client_address[0]))
                    return self._deny(429, "too many attempts")
                mt_auth_fail_record()
                time.sleep(1.0)
                log("DENY %s %s from %s" % (self.command, path, self.client_address[0]))
                return self._deny(401, "unauthorized")
            mt_auth_success()
            fwd["Authorization"] = "Bearer gate"   # 8787 不校验, 仅占位防令牌下传
        fwd["Host"] = "%s:%d" % (BACKEND_HOST, backend_port)
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            return self._deny(413, "body too large")
        body = self.rfile.read(length) if length > 0 else None
        try:
            conn = http.client.HTTPConnection(BACKEND_HOST, backend_port, timeout=CONNECT_TIMEOUT)
            conn.request(self.command, fwd_path, body=body, headers=fwd)
            resp = conn.getresponse()
            if conn.sock:
                conn.sock.settimeout(IO_TIMEOUT)
            self.close_connection = True
            self.send_response_only(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in ("transfer-encoding", "connection", "keep-alive"):
                    continue
                self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()
            sent = 0
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
            conn.close()
            log("OK %s %s -> %s:%d %d (%dB)" % (self.command, path, BACKEND_HOST, backend_port, resp.status, sent))
        except Exception as e:
            log("ERR %s %s: %r" % (self.command, path, e))
            try:
                self._deny(502, "backend unreachable")
            except Exception:
                pass
    def log_message(self, *a):
        pass

if __name__ == "__main__":
    log("gate v2.3 start pid=%d port=%d mt->%d prefix=%s facade->%d" % (os.getpid(), LISTEN_PORT, MT_PORT, MT_PREFIX, FACADE_PORT))
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()