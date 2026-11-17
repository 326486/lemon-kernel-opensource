#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
slim_proxy.py —— 小柠檬内核·瘦身代理（方案B 复刻版）
记忆依据：#444（slim 代理第1+2期）、#418（防上下文撑爆门禁）
作用：客户端连 8791，只看到 14 个工具（热档11 + 门面3）
上游：127.0.0.1:8788
"""

import json
import os
import re
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("LEMON_UPSTREAM", "http://127.0.0.1:8788")
LISTEN_PORT = int(os.environ.get("LEMON_SLIM_PORT", "8791"))
LISTEN_HOST = os.environ.get("LEMON_SLIM_HOST", "127.0.0.1")
IDX_DIR = "/data/lemonbrain/tools/_索引"
LOG_DIR = "/data/lemonbrain/logs"
LOG_FILE = os.path.join(LOG_DIR, "slimproxy.log")
MAX_BYTES = 4096       # #418 标准：4KB 限长 + 全文落盘（261101 恢复分流，lemon-user钦定）
LOG_MAX = 2 * 1024 * 1024
PROTO = "2025-06-18"

# ---- 261103 公网鉴权 ----
# 开启条件：环境变量 LEMON_SLIM_TOKEN 或 /data/lemonbrain/slimproxy/.token 非空
# 通过方式：Authorization: Bearer <token> 或请求路径含 /<token>（URL 即密钥）
# 为空 = 不鉴权（纯本机回环模式，行为与旧版完全一致）
def _load_token():
    t = os.environ.get("LEMON_SLIM_TOKEN", "").strip()
    if t:
        return t
    try:
        with open("/data/lemonbrain/slimproxy/.token", "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""
SLIM_TOKEN = _load_token()
# 公网隧道专用口（cloudflared 连这里，强制Token；Token未配置则不监听，防裸奔）
LISTEN_PORT2 = int(os.environ.get("LEMON_SLIM_PORT2", "8792"))

HOT = ["sh", "shell_exec", "task_poll", "task_submit",
       "file_write_text", "file_head", "file_ls", "file_cat",
       "text_search_regex", "file_find", "shell_script"]

FACADE = ["tool_find", "tool_get", "tool_call"]

FACADE_DEFS = [
    {"name": "tool_find",
     "description": "[门面] 搜索工具库：关键词 → T-编号 + 说明。支持多关键词（空格/逗号/顿号分隔，AND 语义，零命中自动 OR 降级）。查到编号后用 tool_get 看定义、tool_call 执行。",
     "inputSchema": {"type": "object", "properties": {
         "q": {"type": "string", "description": "关键词，如 apk 逆向"},
         "limit": {"type": "integer", "description": "返回条数，默认20，最大100"}},
         "required": ["q"]}},
    {"name": "tool_get",
     "description": "[门面] 取工具完整定义：T-编号或工具名 → description + inputSchema。",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string", "description": "T-编号（如 T-0042）或工具名"}},
         "required": ["id"]}},
    {"name": "tool_call",
     "description": "[门面] 按编号执行工具：T-编号/工具名 + arguments 对象。输出超 4KB 自动截断并提示。",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string", "description": "T-编号或工具名"},
         "arguments": {"type": "object", "description": "参数对象，无参传 {}"}},
         "required": ["id"]}},
]

DOMAINS = [
    ("D1", "系统", ("sys_", "meta_", "setting", "props_", "prop_", "battery", "power_", "thermal", "uptime", "date_", "timezone", "locale", "hostname", "density", "wm_", "brightness", "rotation", "screen_")),
    ("D2", "文件", ("file_", "zip_", "tar_", "gz_", "xz_", "base64", "hash_", "hex_", "disk_", "mount_", "storage", "sdcard", "emulated", "fs_", "sm_", "fstrim", "lsblk", "block_")),
    ("D3", "进程", ("proc_", "ps_", "mem_", "mon_", "task_", "frida")),
    ("D4", "应用", ("pkg_", "pm_", "app_", "act_", "svc_", "input_", "broadcast", "uiautomator", "screencap", "screenrecord", "lock_", "clip_", "audio_", "cam_")),
    ("D5", "网络", ("net_", "wifi", "bt_", "nfc_", "airplane", "data_", "port_", "ipt_", "dns")),
    ("D6", "内核", ("kernel", "kvar", "khook", "ko_", "cpu_", "gpu_", "cpuinfo", "vmstat", "slab", "zone", "swap", "selinux", "magisk", "root_", "su_", "bpf", "dmesg", "logcat", "watchdog", "workqueue", "iomem", "ioports", "iommu", "regulator", "remoteproc", "pmic", "qce", "smc", "spcom", "subsys", "tms", "typec", "usb", "vdc", "wakeup", "devfreq", "coresight", "kgsl", "ion_", "ipa_", "hardware", "sensor", "charger", "fg_", "vooc", "batt", "oplus_", "game_", "jank_")),
    ("D7", "逆向", ("mt_", "apk_", "dex_", "elf_", "objdump", "string_", "bin_", "so_", "packer", "unpack", "reverse", "java_", "sign_", "jar", "keytool", "virus_", "dyn_", "hook")),
    ("D8", "编排", ("algo_", "proxy", "chat", "ai_", "llm", "res_", "learn_", "repo", "cron", "policy", "snap", "qemu", "autostart", "defender", "expose", "perm_", "sec_", "audit", "storage_", "log_")),
]

SSE_SESSIONS = {}          # sessionId -> queue(list)，SSE 长连接会话
SSE_LOCK = threading.Lock()
# ---- SAFETY_V13 安全加固（261103）----
FAIL_COUNT = {}            # {"n":连续失败次数, "until":熔断截止时间}
FAIL_LOCK = threading.Lock()
FAIL_LIMIT = 8             # 连续失败8次触发熔断
BAN_SECONDS = 900         # 熔断15分钟（有效Token可立即解除）
SSE_MAX_SESSIONS = 12     # SSE 并发流上限（防DoS）
MAX_BODY = 1024 * 1024     # 请求体上限1MB
import queue as _queue_mod   # 局部导入避免污染
    
TOOLS = []
BY_ID = {}
BY_NAME = {}
INDEX_TS = 0


def log(msg):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX:
            with open(LOG_FILE, "r", errors="ignore") as f:
                tail = f.readlines()[-2000:]
            with open(LOG_FILE, "w", errors="ignore") as f:
                f.writelines(tail)
        with open(LOG_FILE, "a", errors="ignore") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


_TL = threading.local()
TOOLOUT_DIR = "/data/lemonbrain/logs/toolout"

def cur_tool():
    return getattr(_TL, "tool", "slim") or "slim"

def set_cur_tool(name):
    _TL.tool = (name or "slim")[:80]

def dump_toolout(s):
    """全文落盘，返回路径；失败返回空串"""
    try:
        os.makedirs(TOOLOUT_DIR, exist_ok=True)
        safe = re.sub(r"[^0-9A-Za-z_.-]", "_", cur_tool())
        # 261101修复: 秒级时间戳同秒并发会覆盖，加随机后缀
        import random as _r
        path = os.path.join(TOOLOUT_DIR, "%s-p%d-%06x-%s.txt" % (
            time.strftime("%Y%m%d-%H%M%S"), os.getpid(), _r.getrandbits(24), safe))
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        return path
    except Exception as e:
        log("toolout落盘失败: %r" % (e,))
        return ""

def clip(s, n=None):
    if n is None:
        n = MAX_BYTES
    if not isinstance(s, str):
        return s
    if n <= 0:              # 全量模式（=0）：原样返回
        return s
    if "[slim] 输出" in s:
        return s          # 上游内核已分流+落盘，透传（防双层截断重复落盘）
    b = s.encode("utf-8", "replace")
    if len(b) <= n:
        return s
    cut = b[:n]
    # utf8安全：回退续字节，再丢不完整首字节（261101修复：原版漏后半）
    while cut and (cut[-1] & 0xC0) == 0x80:
        cut = cut[:-1]
    if cut and 0xC2 <= cut[-1] <= 0xF4:
        cut = cut[:-1]
    body = cut.decode("utf-8", "ignore")
    path = dump_toolout(s)
    tail = "\n[slim] 输出 %dB 超 %dB 上限" % (len(b), n)
    tail += ("，全文：" + path) if path else "（落盘失败）"
    return body + tail


def classify(name):
    low = name.lower()
    for tag, label, prefixes in DOMAINS:
        for p in prefixes:
            if low.startswith(p):
                return tag, label
    return "D9", "冷库"


def rpc(method, params, timeout=60):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or {}}).encode("utf-8")
    req = urllib.request.Request(UPSTREAM + "/", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def build_index(force=False):
    global TOOLS, BY_ID, BY_NAME, INDEX_TS
    if TOOLS and not force and (time.time() - INDEX_TS) < 300:
        return True
    tools = None
    try:
        resp = rpc("tools/list", {"all": True})   # 261101: 索引须全量(缺省lean只68个)
        tools = (resp.get("result") or {}).get("tools") or []
        log("索引拉取成功 tools=%d" % len(tools))
    except Exception as e:
        log("索引拉取失败: %r" % (e,))
    if not tools:
        cache = os.path.join(IDX_DIR, "tools_cache.json")
        if os.path.exists(cache):
            try:
                with open(cache, "r", encoding="utf-8") as f:
                    tools = json.load(f)
                log("使用本地缓存 tools=%d" % len(tools))
            except Exception as e:
                log("缓存读取失败: %r" % (e,))
    if not tools:
        return False
    try:
        os.makedirs(IDX_DIR, exist_ok=True)
        cache = os.path.join(IDX_DIR, "tools_cache.json")
        tmp = cache + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(tools, f, ensure_ascii=False)
        os.replace(tmp, cache)
    except Exception as e:
        log("缓存写入失败: %r" % (e,))
    seq = {}
    out = []
    base = {"D1": 0, "D2": 200, "D3": 400, "D4": 600, "D5": 800,
            "D6": 1000, "D7": 1200, "D8": 1400, "D9": 9000}
    for t in tools:
        if not isinstance(t, dict):
            continue
        nm = t.get("name")
        if not nm:
            continue
        tag, label = classify(nm)
        seq[tag] = seq.get(tag, 0) + 1
        tid = "T-%04d" % (base[tag] + seq[tag])
        out.append({"id": tid, "name": nm,
                    "desc": (t.get("description") or "")[:400],
                    "schema": t.get("inputSchema") or {"type": "object", "properties": {}},
                    "dom": tag, "domname": label})
    TOOLS = out
    BY_ID = {x["id"]: x for x in out}
    BY_NAME = {x["name"]: x for x in out}
    INDEX_TS = time.time()
    try:
        os.makedirs(IDX_DIR, exist_ok=True)
        with open(os.path.join(IDX_DIR, "工具索引.tsv"), "w", encoding="utf-8") as f:
            f.write("编号\t工具名\t域\t一句话\n")
            for x in out:
                f.write("%s\t%s\t%s-%s\t%s\n" % (x["id"], x["name"], x["dom"], x["domname"],
                                                 x["desc"].replace("\n", " ")[:120]))
    except Exception as e:
        log("索引落盘失败: %r" % (e,))
    return True


def split_kw(q):
    parts = re.split(r"[\s,，、/／]+", (q or "").strip())
    return [p for p in parts if p]


def do_find(q, limit=20):
    if not build_index():
        return "索引不可用：上游 8788 未响应且无本地缓存"
    kws = split_kw(q)
    if not kws:
        return "用法：tool_find 关键词（可多词）"
    try:
        limit = max(1, min(100, int(limit)))
    except Exception:
        limit = 20

    def hay(x):
        return (x["name"] + " " + x["desc"]).lower()

    hits = [x for x in TOOLS if all(k.lower() in hay(x) for k in kws)]
    mode = "AND"
    if not hits:
        hits = [x for x in TOOLS if any(k.lower() in hay(x) for k in kws)]
        mode = "OR降级"
    if not hits:
        return "未找到匹配 [%s] 的工具（共 %d 个）" % (q, len(TOOLS))
    lines = ["找到 %d 个（%s，显示前 %d）：" % (len(hits), mode, min(limit, len(hits)))]
    for x in hits[:limit]:
        lines.append("%s  %-28s %s" % (x["id"], x["name"], x["desc"].replace("\n", " ")[:80]))
    if len(hits) > limit:
        lines.append("... 还有 %d 个，缩小关键词或调大 limit" % (len(hits) - limit))
    lines.append("→ tool_get <编号>；tool_call <编号> {参数}")
    return clip("\n".join(lines))


def do_get(tid):
    if not build_index():
        return "索引不可用"
    x = BY_ID.get((tid or "").strip()) or BY_NAME.get((tid or "").strip())
    if not x:
        return "未找到：%s（用 tool_find 先搜）" % tid
    return clip(json.dumps({"id": x["id"], "name": x["name"],
                            "domain": x["dom"] + "-" + x["domname"],
                            "description": x["desc"], "inputSchema": x["schema"]},
                           ensure_ascii=False, indent=2))


def do_call(tid, args):
    if not build_index():
        return "索引不可用"
    x = BY_ID.get((tid or "").strip()) or BY_NAME.get((tid or "").strip())
    if not x:
        return "未找到：%s（用 tool_find 先搜）" % tid
    if not isinstance(args, dict):
        args = {}
    if x["name"] in FACADE:
        return "门面工具请直接调用，不要经 tool_call 转发"
    try:
        resp = rpc("tools/call", {"name": x["name"], "arguments": args}, timeout=120)
    except Exception as e:
        return "调用失败 %s: %r" % (x["name"], e)
    res = resp.get("result") or {}
    if resp.get("error"):
        return clip("上游错误: " + json.dumps(resp["error"], ensure_ascii=False))
    texts = []
    for c in (res.get("content") or []):
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text") or "")
    body = "\n".join(texts) if texts else json.dumps(res, ensure_ascii=False)
    return clip(body)


def slim_tools_list():
    defs = []
    try:
        resp = rpc("tools/list", {})
        alltools = (resp.get("result") or {}).get("tools") or []
        m = {t.get("name"): t for t in alltools if isinstance(t, dict)}
        for nm in HOT:
            if nm in m:
                defs.append(m[nm])
    except Exception as e:
        log("热档定义拉取失败: %r" % (e,))
    defs.extend(FACADE_DEFS)
    return defs


def sse_handle_rpc(req):
    """统一的 JSON-RPC 分发（POST 与 SSE 共用）；返回 dict 或 None(通知类)"""
    rid = req.get("id")
    method = req.get("method") or ""
    params = req.get("params") or {}
    if method == "initialize":
        # PROTO_ECHO_V2: 回显客户端请求的版本（老SDK发2024-11-05时不被新版本号吓退）
        cv = params.get("protocolVersion") or ""
        ver = cv if cv in ('2024-11-05', '2025-03-26', '2025-06-18') else PROTO
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": ver,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "小柠檬内核·slim门面", "version": "1.2.0"}}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": slim_tools_list()}}
    if method == "tools/call":
        name = params.get("name")
        set_cur_tool(name)
        args = params.get("arguments") or {}
        t0 = time.time()
        if name == "tool_find":
            out = do_find(args.get("q", ""), args.get("limit", 20))
        elif name == "tool_get":
            out = do_get(args.get("id", ""))
        elif name == "tool_call":
            out = do_call(args.get("id", ""), args.get("arguments") or {})
        else:
            try:
                resp = rpc("tools/call", {"name": name, "arguments": args}, timeout=120)
            except Exception as e:
                return {"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text",
                                 "text": clip("转发失败 %s: %r" % (name, e))}],
                    "isError": True}}
            res = resp.get("result") or {}
            for c in (res.get("content") or []):
                if isinstance(c, dict) and c.get("type") == "text":
                    c["text"] = clip(c.get("text") or "")
            log("SSE转发 %s %.0fms" % (name, (time.time() - t0) * 1000))
            return {"jsonrpc": "2.0", "id": rid, "result": res}
        log("SSE %s %.0fms" % (name, (time.time() - t0) * 1000))
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": out}], "isError": False}}
    if method in ("ping", "notifications/initialized", "notifications/cancelled"):
        if rid is None:
            return None
        return {"jsonrpc": "2.0", "id": rid, "result": {}}
    try:
        return rpc(method, params, timeout=60)
    except Exception as e:
        return {"jsonrpc": "2.0", "id": rid,
                "error": {"code": -32603, "message": "上游不可用: %r" % (e,)}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LemonSlim/1.0"

    def log_message(self, fmt, *args):
        # REQ_LOG + SAFETY_V13: 记录入站请求，token 脱敏不落盘
        try:
            p = self.path
            if SLIM_TOKEN and SLIM_TOKEN in p:
                p = p.replace(SLIM_TOKEN, "***T***")
            # REQ_PORT: 带监听端口，区分本机(8791)与公网(8792)请求
            try:
                _port = self.connection.getsockname()[1]
            except Exception:
                _port = 0
            log("REQ %s %s %s" % (_port, self.command, p))
        except Exception:
            pass

    def _auth_ok(self):
        # 8791 本机口：恒放行（仅绑 127.0.0.1，外部不可达；公网走 8792+HandlerPub 强制Token）
        # 铁律：LEMON_SLIM_HOST 必须保持 127.0.0.1
        return True


    # ---------- MCP SSE transport (2024-11-05) ----------
    def do_sse(self):
        """GET /sse：开 text/event-stream 长连接"""
        with SSE_LOCK:
            if len(SSE_SESSIONS) >= SSE_MAX_SESSIONS:
                self._send({"ok": False, "error": "too many streams"}, 503)
                return
        sid = os.urandom(16).hex()
        q = _queue_mod.Queue()
        with SSE_LOCK:
            SSE_SESSIONS[sid] = q
        log("SSE 会话建立 %s" % sid)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("Connection", "keep-alive")
            # 允许跨域（云端客户端）
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            # 首帧：告知客户端消息投递端点（带 sessionId 与 token 透传）
            # SAFETY_V13: endpoint 不带 token（sessionId 128bit 随机即凭证）
            self.wfile.write(("event: endpoint\ndata: /messages?sessionId=%s\n\n"
                              % sid).encode("utf-8"))
            self.wfile.flush()
        except Exception as e:
            log("SSE 开流失败: %r" % (e,))
            with SSE_LOCK:
                SSE_SESSIONS.pop(sid, None)
            return
        # 长驻：推送队列消息，定期心跳保活；V14_POLISH: 空闲600秒自动关（半开连接兜底）
        last_active = time.time()
        try:
            while True:
                try:
                    msg = q.get(timeout=15)
                    if msg is None:
                        break
                    self.wfile.write(("event: message\ndata: %s\n\n" % msg).encode("utf-8"))
                    self.wfile.flush()
                    last_active = time.time()
                except _queue_mod.Empty:
                    # 心跳（SSE 注释帧），检测连接是否已断
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    if time.time() - last_active > 600:
                        log("SSE 空闲超时清理 %s (600s无消息)" % sid)
                        break
        except Exception:
            pass
        finally:
            with SSE_LOCK:
                SSE_SESSIONS.pop(sid, None)
            log("SSE 会话关闭 %s" % sid)

    def do_messages(self):
        """POST /messages?sessionId=xxx：接收客户端 JSON-RPC，回推至 SSE 流"""
        sid = ""
        if "?" in self.path:
            import urllib.parse as _up
            qs = _up.parse_qs(self.path.split("?", 1)[1])
            sid = (qs.get("sessionId") or [""])[0]
        with SSE_LOCK:
            q = SSE_SESSIONS.get(sid)
        if q is None:
            self._send({"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32001, "message": "session not found: %s" % sid}}, 404)
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
        resp = sse_handle_rpc(req)
        if resp is not None:
            q.put(json.dumps(resp, ensure_ascii=False))
        self.send_response(202)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _deny(self):
        # SAFETY_V13: 伪装404，不向探测者暴露"这里有鉴权服务"
        p = self.path
        if SLIM_TOKEN and SLIM_TOKEN in p:
            p = p.replace(SLIM_TOKEN, "***T***")
        self._send({"jsonrpc": "2.0", "id": None,
                    "error": {"code": -32001, "message": "not found"}}, 404)
        log("拒绝(404) %s %s" % (self.command, p))

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

    def do_GET(self):
        # SSE_ROUTE_V2: /sse、/<token>/sse、/sse/<token> 全识别
        _p = (self.path or "").split("?", 1)[0]
        _segs = [s for s in _p.strip("/").split("/") if s]
        _is_sse = bool(_segs) and (("sse" in _segs) or _segs[-1] == "sse")
        if _is_sse:
            if not self._auth_ok():
                self._deny()
                return
            self.do_sse()
            return
        if not self._auth_ok():
            self._deny()
            return
        self._send({"ok": True, "server": "小柠檬内核·slim门面", "upstream": UPSTREAM,
                    "tools_exposed": len(slim_tools_list()),
                    "indexed": len(TOOLS)})

    def do_POST(self):
        # SSE_ROUTE_V2: /messages、/<token>/messages、/messages/<token> 全识别
        _p = (self.path or "").split("?", 1)[0]
        _segs = [s for s in _p.strip("/").split("/") if s]
        _is_msg = bool(_segs) and (("messages" in _segs) or _segs[-1] == "messages")
        if _is_msg:
            if not self._auth_ok():
                self._deny()
                return
            self.do_messages()
            return
        if not self._auth_ok():
            self._deny()
            return
        t0 = time.time()
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                self._send({"jsonrpc": "2.0", "id": None,
                            "error": {"code": -32600, "message": "payload too large"}}, 413)
                return
            raw = self.rfile.read(n) if n > 0 else b"{}"
            req = json.loads(raw.decode("utf-8", "replace") or "{}")
        except Exception as e:
            # V14_POLISH: 畸形JSON回 HTTP 400（原200，红队测试发现的瑕疵）
            self._send({"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error: %r" % (e,)}}, 400)
            return
        rid = req.get("id")
        method = req.get("method") or ""
        params = req.get("params") or {}
        try:
            if method == "initialize":
                cv = params.get("protocolVersion") or ""
                ver = cv if cv in ('2024-11-05', '2025-03-26', '2025-06-18') else PROTO
                self._send({"jsonrpc": "2.0", "id": rid, "result": {
                    "protocolVersion": ver,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "小柠檬内核·slim门面", "version": "1.2.0"}}})
                return
            if method == "tools/list":
                self._send({"jsonrpc": "2.0", "id": rid,
                            "result": {"tools": slim_tools_list()}})
                return
            if method == "tools/call":
                name = params.get("name")
                set_cur_tool(name)
                args = params.get("arguments") or {}
                if name == "tool_find":
                    out = do_find(args.get("q", ""), args.get("limit", 20))
                elif name == "tool_get":
                    out = do_get(args.get("id", ""))
                elif name == "tool_call":
                    out = do_call(args.get("id", ""), args.get("arguments") or {})
                else:
                    try:
                        resp = rpc("tools/call", {"name": name, "arguments": args}, timeout=120)
                    except Exception as e:
                        self._send({"jsonrpc": "2.0", "id": rid, "result": {
                            "content": [{"type": "text",
                                         "text": clip("转发失败 %s: %r" % (name, e))}],
                            "isError": True}})
                        return
                    res = resp.get("result") or {}
                    for c in (res.get("content") or []):
                        if isinstance(c, dict) and c.get("type") == "text":
                            c["text"] = clip(c.get("text") or "")
                    self._send({"jsonrpc": "2.0", "id": rid, "result": res})
                    log("转发 %s %.0fms" % (name, (time.time() - t0) * 1000))
                    return
                self._send({"jsonrpc": "2.0", "id": rid, "result": {
                    "content": [{"type": "text", "text": out}], "isError": False}})
                log("%s %.0fms" % (name, (time.time() - t0) * 1000))
                return
            if method in ("ping", "notifications/initialized", "notifications/cancelled"):
                if rid is not None:
                    self._send({"jsonrpc": "2.0", "id": rid, "result": {}})
                else:
                    self.send_response(204)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                return
            try:
                self._send(rpc(method, params, timeout=60))
            except Exception as e:
                self._send({"jsonrpc": "2.0", "id": rid,
                            "error": {"code": -32603, "message": "上游不可用: %r" % (e,)}})
        except Exception as e:
            log("处理异常 %s: %r" % (method, e))
            try:
                self._send({"jsonrpc": "2.0", "id": rid,
                            "error": {"code": -32603, "message": "%r" % (e,)}})
            except Exception:
                pass


class HandlerPub(Handler):
    """8792 公网口专用：强制 Token（Bearer头/路径密钥/query ?token=）
    SAFETY_V13: ①连续失败熔断(有效Token随时可解除) ②/messages 的 sessionId 等效鉴权"""
    def _auth_ok(self):
        if not SLIM_TOKEN:
            return False
        with FAIL_LOCK:
            cooling = time.time() < FAIL_COUNT.get("until", 0)
        ok = False
        h = self.headers.get("Authorization") or ""
        if h.strip() == "Bearer " + SLIM_TOKEN:
            ok = True
        if not ok:
            p = (self.path or "").split("?", 1)[0]
            if ("/" + SLIM_TOKEN) in p:
                ok = True
        if not ok:
            q = (self.path or "").split("?", 1)
            if len(q) > 1:
                try:
                    import urllib.parse as _up
                    qs = _up.parse_qs(q[1])
                    if (qs.get("token") or [""])[0] == SLIM_TOKEN:
                        ok = True
                    elif "/messages" in q[0]:
                        # SAFETY_V13: sessionId 在会话表内 = SSE 流建立时已过鉴权
                        sid = (qs.get("sessionId") or [""])[0]
                        with SSE_LOCK:
                            if sid and sid in SSE_SESSIONS:
                                ok = True
                except Exception:
                    pass
        with FAIL_LOCK:
            if ok:
                # 有效请求到达即清零并解除熔断（合法用户随时能进来）
                FAIL_COUNT["n"] = 0
                FAIL_COUNT["until"] = 0
            elif not cooling:
                FAIL_COUNT["n"] = FAIL_COUNT.get("n", 0) + 1
                if FAIL_COUNT["n"] >= FAIL_LIMIT:
                    FAIL_COUNT["n"] = 0
                    FAIL_COUNT["until"] = time.time() + BAN_SECONDS
                    log("SAFETY熔断: 连续%d次无效凭证, 冷却%d秒(有效Token可解除)" % (FAIL_LIMIT, BAN_SECONDS))
        return ok


def main():
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(IDX_DIR, exist_ok=True)
    log("=== slim_proxy 启动 port=%d upstream=%s pid=%d ===" %
        (LISTEN_PORT, UPSTREAM, os.getpid()))
    try:
        build_index()
    except Exception as e:
        log("预热失败: %r" % (e,))
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    srv.daemon_threads = True
    if SLIM_TOKEN:
        srv2 = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT2), HandlerPub)
        srv2.daemon_threads = True
        threading.Thread(target=srv2.serve_forever,
                         kwargs={"poll_interval": 0.5}, daemon=True).start()
        log("公网口 %s:%d 已监听(强制Token)" % (LISTEN_HOST, LISTEN_PORT2))
    log("监听 %s:%d 热档=%d 门面=%d 索引=%d" %
        (LISTEN_HOST, LISTEN_PORT, len(HOT), len(FACADE), len(TOOLS)))
    try:
        srv.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        log("收到中断，退出")
    finally:
        try:
            srv.server_close()
        except Exception:
            pass


if __name__ == "__main__":
    main()