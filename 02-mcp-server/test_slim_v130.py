#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_slim_v130.py —— 小柠檬 slim 门面 v1.3.0 自动化验收测试
用法（Termux / 任意 Python3）：
    python3 test_slim_v130.py /path/to/slim_proxy_v130.py
自带 mock 上游（模拟 lemoncore），不碰真机 8788；全部走临时目录。
"""
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROXY = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "slim_proxy_v130.py")
HOME = "/tmp/lemonhome_test"
UP_PORT, LO_PORT, PUB_PORT = 18788, 18791, 18792
MASTER = "master-token-test-261111"
SCOPED = {"readonly": "tok-readonly-111", "write": "tok-write-222", "root": "tok-root-333"}

PASS = [0]
FAIL = [0]
FAILURES = []

def T(cond, label):
    if cond:
        PASS[0] += 1
    else:
        FAIL[0] += 1
        FAILURES.append(label)
        print("  ✗ FAIL:", label)

# ---------------- mock 上游（模拟 lemoncore 8788） ----------------
FAKE_TOOLS = [
    {"name": "sh", "description": "[Shell] 以 root 执行任意 shell 命令",
     "inputSchema": {"type": "object", "properties": {"cmd": {"type": "string"}}}},
    {"name": "shell_exec", "description": "[Shell] root 执行任意 shell 命令(支持 timeoutMs)",
     "inputSchema": {"type": "object", "properties": {"cmd": {"type": "string"}}}},
    {"name": "shell_exec_root", "description": "[Legacy] 以root执行任意shell命令",
     "inputSchema": {"type": "object", "properties": {"cmd": {"type": "string"}}}},
    {"name": "shell_script", "description": "[Shell] 执行脚本",
     "inputSchema": {"type": "object", "properties": {"script": {"type": "string"}}}},
    {"name": "file_write_text", "description": "[文件] root 写入文本文件",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "text": {"type": "string"}}}},
    {"name": "file_cat", "description": "[文件] cat 输出整个文件",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "file_head", "description": "[文件] 读文件头N行",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "file_ls", "description": "[文件] 列目录",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "file_find", "description": "[文件] 找文件",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "text_search_regex", "description": "[文件] 正则搜文本",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}}}},
    {"name": "task_poll", "description": "[编排] 轮询任务", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "task_submit", "description": "[编排] 提交任务", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "apk_sign", "description": "[逆向] APK 签名", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "net_wifi", "description": "[网络] WiFi 控制", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "ko_load", "description": "[内核] 加载内核模块", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "big_output", "description": "[测试] 返回超大输出", "inputSchema": {"type": "object", "properties": {}}},
]
BIG_TEXT = ("小柠檬内核·大输出测试行。abcdefghijklmnopqrstuvwxyz0123456789。\n" * 200)  # >10KB

def mock_result(method, params):
    if method == "tools/list":
        return {"tools": FAKE_TOOLS}
    if method == "tools/call":
        name = (params or {}).get("name")
        args = (params or {}).get("arguments") or {}
        if name == "big_output":
            return {"content": [{"type": "text", "text": BIG_TEXT}], "isError": False}
        if name == "file_write_text":
            p = args.get("path")
            with open(p, "a" if str(args.get("append")) == "1" else "w", encoding="utf-8") as f:
                f.write(args.get("text") or "")
            return {"content": [{"type": "text", "text": "written %s" % p}], "isError": False}
        if name == "file_cat":
            with open(args.get("path"), encoding="utf-8") as f:
                return {"content": [{"type": "text", "text": f.read()}], "isError": False}
        return {"content": [{"type": "text",
                             "text": "echo %s %s" % (name, json.dumps(args, ensure_ascii=False))}],
                "isError": False}
    if method == "initialize":
        return {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                "serverInfo": {"name": "mock-lemoncore", "version": "0"}}
    if method == "custom/method":
        return {"echo": params}
    return {}

class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        resp = {"jsonrpc": "2.0", "id": req.get("id"),
                "result": mock_result(req.get("method"), req.get("params"))}
        data = json.dumps(resp, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

def start_mock():
    srv = ThreadingHTTPServer(("127.0.0.1", UP_PORT), MockHandler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv

# ---------------- 工具函数 ----------------
def wait_port(port, timeout=15):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = socket.socket()
        try:
            s.settimeout(0.5)
            s.connect(("127.0.0.1", port))
            s.close()
            return True
        except Exception:
            time.sleep(0.2)
        finally:
            s.close()
    return False

PROC = [None]

def start_proxy(scoped=False):
    shutil.rmtree(HOME, ignore_errors=True)
    os.makedirs(os.path.join(HOME, "slimproxy"), exist_ok=True)
    with open(os.path.join(HOME, "slimproxy", ".token"), "w") as f:
        f.write(MASTER)
    if scoped:
        with open(os.path.join(HOME, "slimproxy", ".tokens.json"), "w") as f:
            json.dump(dict(SCOPED, default_scope="write"), f)
    env = dict(os.environ)
    env.update({"LEMON_HOME": HOME, "LEMON_SLIM_PORT": str(LO_PORT),
                "LEMON_SLIM_PORT2": str(PUB_PORT), "LEMON_UPSTREAM": "http://127.0.0.1:%d" % UP_PORT})
    env.pop("LEMON_SLIM_TOKEN", None)
    p = subprocess.Popen([sys.executable, PROXY], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    PROC[0] = p
    assert wait_port(LO_PORT), "本机口未起来"
    assert wait_port(PUB_PORT), "公网口未起来"
    return p

def stop_proxy():
    if PROC[0]:
        PROC[0].terminate()
        try:
            PROC[0].wait(timeout=5)
        except Exception:
            PROC[0].kill()
            PROC[0].wait(timeout=5)
        print("  [dbg] stop_proxy: pid=%s poll=%s" % (PROC[0].pid, PROC[0].poll()))
        PROC[0] = None
    time.sleep(0.5)
    # 端口必须释放，否则下一阶段会串到旧进程
    t0 = time.time()
    while time.time() - t0 < 5:
        if not wait_port(LO_PORT, timeout=0.3):
            break
        time.sleep(0.2)
    assert not wait_port(LO_PORT, timeout=0.3), "旧进程端口未释放！"
    print("  [dbg] 端口已释放")

def req(port, method="GET", path="/", body=None, token=None, raw=False, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    h = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode() if not isinstance(body, (bytes, str)) else body
        if isinstance(data, str):
            data = data.encode()
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = "Bearer " + token
    try:
        c.request(method, path, body=data, headers=h)
    except (BrokenPipeError, ConnectionResetError):
        pass  # 服务器可能已提前回 413/400 并关连接（I8 场景）
    try:
        r = c.getresponse()
        b = r.read()
    except Exception:
        c.close()
        return 0, b""
    c.close()
    if raw:
        return r.status, b
    try:
        return r.status, json.loads(b.decode("utf-8", "replace"))
    except Exception:
        return r.status, b

def rpc(port, method, params=None, path="/", token=None, headers=None):
    return req(port, "POST", path, {"jsonrpc": "2.0", "id": 1, "method": method,
                                    "params": params or {}}, token=token, headers=headers)

def call_tool(name, args=None, port=LO_PORT, **kw):
    st, d = rpc(port, "tools/call", {"name": name, "arguments": args or {}}, **kw)
    assert st == 200, "HTTP %s" % st
    return d.get("result") or {}

def text_of(result):
    return "\n".join(c.get("text", "") for c in result.get("content", [])
                     if isinstance(c, dict) and c.get("type") == "text")

# ================= 测试主体 =================
print("== 启动 mock 上游 ==")
start_mock()
print("== 阶段1：旧模式（单主令牌） ==")
start_proxy(scoped=False)

# --- A. 健康与协议 ---
st, d = req(LO_PORT)
T(st == 200, "A1 健康检查 200")
T(d.get("ok") is True and d.get("version") == "1.3.1", "A2 健康含 v1.3.1")
T(d.get("guard") is True and d.get("snapshot") is True, "A3 加固开关默认开")
T(d.get("tools_exposed") == 15, "A4 暴露 15 个工具（热档11+门面4）")
st, d = rpc(LO_PORT, "initialize", {"protocolVersion": "2024-11-05"})
T(d["result"]["protocolVersion"] == "2024-11-05", "A5 initialize 回显旧版本")
st, d = rpc(LO_PORT, "initialize", {"protocolVersion": "2025-03-26"})
T(d["result"]["protocolVersion"] == "2025-03-26", "A6 initialize 回显 2025-03-26")
st, d = rpc(LO_PORT, "initialize", {"protocolVersion": "2099-01-01"})
T(d["result"]["protocolVersion"] == "2025-06-18", "A7 未知版本回落 2025-06-18")
T(d["result"]["serverInfo"]["version"] == "1.3.1", "A8 serverInfo v1.3.1")
st, d = rpc(LO_PORT, "tools/list")
tools = [t["name"] for t in d["result"]["tools"]]
T("file_read" in tools, "A9 tools/list 含 file_read")
fr = [t for t in d["result"]["tools"] if t["name"] == "file_read"][0]
T("path" in fr["inputSchema"].get("required", []), "A10 file_read 必填 path")
T("tool_find" in tools and "sh" in tools, "A11 门面与热档齐全")

# --- B. 门面三件套 ---
r = call_tool("tool_find", {"q": "apk"})
T("T-" in text_of(r), "B1 tool_find 命中 apk")
r = call_tool("tool_find", {"q": "apk 签名"})
T("apk_sign" in text_of(r), "B2 AND 语义命中")
r = call_tool("tool_find", {"q": "apk zzz不存在词"})
T("OR降级" in text_of(r) or "未找到" in text_of(r), "B3 零命中 OR 降级")
r = call_tool("tool_find", {"q": ""})
T("用法" in text_of(r), "B4 空关键词给用法")
r = call_tool("tool_find", {"q": "file", "limit": 3})
T(len([l for l in text_of(r).split("\n") if l.startswith("T-")]) <= 3, "B5 limit 生效")
hits = re.findall(r"T-\d{4}", text_of(call_tool("tool_find", {"q": "apk"})))
r = call_tool("tool_get", {"id": hits[0]})
T("apk_sign" in text_of(r) and "inputSchema" in text_of(r), "B6 tool_get 按编号")
r = call_tool("tool_get", {"id": "apk_sign"})
T("T-" in text_of(r), "B7 tool_get 按名称")
r = call_tool("tool_get", {"id": "T-9999"})
T("未找到" in text_of(r), "B8 tool_get 不存在")
r = call_tool("tool_call", {"id": "apk_sign", "arguments": {}})
T("echo apk_sign" in text_of(r), "B9 tool_call 转发执行")
r = call_tool("tool_call", {"id": "tool_find", "arguments": {}})
T("未找到" in text_of(r) or "门面工具请直接调用" in text_of(r), "B10 tool_call 拒转门面")

# --- C. 结构化截断 ---
r = call_tool("big_output")
t = text_of(r)
T("[slim] 输出" in t and "超 4096B 上限" in t, "C1 截断文本提示保留")
ev = (r.get("_meta") or {}).get("slim", {}).get("events", [])
slim_ev = [e.get("slim") for e in ev if e.get("slim")]
T(bool(slim_ev), "C2 _meta.slim.events 存在")
T(slim_ev and slim_ev[0]["truncated"] is True, "C3 truncated=true")
T(slim_ev and slim_ev[0]["total_bytes"] == len(BIG_TEXT.encode()), "C4 total_bytes 精确")
fp = slim_ev[0].get("full_path") if slim_ev else None
T(fp and os.path.isfile(fp), "C5 全文落盘文件存在")
T(fp and os.path.getsize(fp) == len(BIG_TEXT.encode()), "C6 落盘字节数等于原文")
body = t.split("\n[slim]")[0]
T("�" not in body, "C7 UTF-8 边界无乱码")
T(len(t.encode()) <= 4096 + 200, "C8 截断后总长受控")

# --- D. file_read 分段读取 ---
target = os.path.join(HOME, "big_cn.txt")
original = ("第%d行·小柠檬内核中文分段读取测试·abcdefgh·\n" % i for i in range(300))
orig_text = "".join(original)
with open(target, "w", encoding="utf-8") as f:
    f.write(orig_text)
orig_bytes = orig_text.encode()
r = call_tool("file_read", {"path": target, "offset": 0, "limit": 4096})
t = text_of(r)
ev = [e.get("file_read") for e in (r.get("_meta") or {}).get("slim", {}).get("events", []) if e.get("file_read")]
T(bool(ev), "D1 file_read 返回 meta")
T(ev[0]["size"] == len(orig_bytes), "D2 size 精确")
nxt = ev[0]["next_offset"]
T(isinstance(nxt, int) and 0 < nxt <= 4096, "D3 next_offset 有效")
T("下段 offset=" in t, "D4 文本提示下段位置")
# 循环读完全文并重组
buf, off = b"", 0
rounds = 0
while True:
    rounds += 1
    r = call_tool("file_read", {"path": target, "offset": off, "limit": 4096})
    txt = text_of(r)
    chunk_txt = txt.split("\n[file_read]")[0]
    buf += chunk_txt.encode()
    meta = [e.get("file_read") for e in (r.get("_meta") or {}).get("slim", {}).get("events", []) if e.get("file_read")][0]
    if meta["next_offset"] is None:
        break
    off = meta["next_offset"]
    T("�" not in chunk_txt, "D5.%d 第%d段无乱码" % (rounds, rounds))
T(buf == orig_bytes, "D6 分段重组 == 原文（逐字节一致）")
T("已读完" in text_of(r), "D7 末段提示已读完")
r = call_tool("file_read", {"path": target, "offset": len(orig_bytes) + 100})
T("已读完" in text_of(r), "D8 越界 offset 安全收尾")
r = call_tool("file_read", {"path": target, "offset": -50})
T("[file_read]" in text_of(r), "D9 负 offset 归零不炸")
r = call_tool("file_read", {"path": target, "limit": 999999})
meta = [e.get("file_read") for e in (r.get("_meta") or {}).get("slim", {}).get("events", []) if e.get("file_read")][0]
T(meta["bytes"] <= 65536, "D10 limit 钳到 65536")
r = call_tool("file_read", {"path": "/nonexistent/xxx"})
T("读取失败" in text_of(r), "D11 不存在文件报错")
r = call_tool("file_read", {})
T("用法" in text_of(r), "D12 缺 path 给用法")
r = call_tool("file_read", {"path": target, "limit": 0})
meta = [e.get("file_read") for e in (r.get("_meta") or {}).get("slim", {}).get("events", []) if e.get("file_read")][0]
T(meta["bytes"] >= 1, "D13 limit=0 至少读 1 字节")

# --- E. 危险护栏 ---
blocked_cmds = [
    ("rm -rf /", "E1"), ("rm -rf /*", "E2"), ("rm -rf /data", "E3"),
    ("rm -rf /system", "E4"), ("rm -rf /vendor", "E5"),
    ("dd if=/sdcard/x.img of=/dev/block/bootdevice/by-name/boot", "E6"),
    ("mkfs.ext4 /dev/block/sda", "E7"), (":(){ :|:& };:", "E8"),
    ("chmod -R 777 /", "E9"), ("flash_image boot /sdcard/x.img", "E10"),  # 261112: 夹具路径改/sdcard,拦截看flash_image关键字
    ("wipe data", "E11"),
]
for cmd, tag in blocked_cmds:
    r = call_tool("sh", {"cmd": cmd})
    T(r.get("isError") is True and "[guard]" in text_of(r), "%s 拦截: %s" % (tag, cmd))
r = call_tool("sh", {"cmd": "rm -rf /data/lemonbrain/logs/old.log"})
T(r.get("isError") is not True and "[guard]" not in text_of(r), "E12 放行: rm 具体文件")
r = call_tool("sh", {"cmd": "dd if=/dev/zero of=/sdcard/slimtest_e13.img bs=1M count=1"})  # 261112: 不再往/data根写垃圾
T("[guard]" not in text_of(r), "E13 放行: dd 写普通文件")
r = call_tool("sh", {"cmd": "echo hello"})
T("echo sh" in text_of(r) and "hello" in text_of(r), "E14 放行: echo")
r = call_tool("shell_exec", {"cmd": "rm -rf /"})
T("[guard]" in text_of(r), "E15 shell_exec 同样被拦")
r = call_tool("shell_script", {"script": "rm -rf /data"})
T("[guard]" in text_of(r), "E16 shell_script 被拦")
r = call_tool("file_write_text", {"path": os.path.join(HOME, "slimproxy", ".token"), "text": "x"})
T("[guard]" in text_of(r), "E17 拦: 写 .token 凭证")
r = call_tool("file_write_text", {"path": "/dev/null", "text": "x"})
T("[guard]" in text_of(r), "E18 拦: 写 /dev")
r = call_tool("file_write_text", {"path": "/proc/sys/test", "text": "x"})
T("[guard]" in text_of(r), "E19 拦: 写 /proc")
r = call_tool("file_write_text", {"path": os.path.join(HOME, "slimproxy", "slim_proxy.py"), "text": "x"})
T("[guard]" in text_of(r), "E20 拦: 写门面包身")
r = call_tool("tool_call", {"id": "sh", "arguments": {"cmd": "rm -rf /"}})
T("[guard]" in text_of(r), "E21 tool_call 内层护栏生效")

# --- E·红队回归（261111 复查逮出的绕过手法） ---
r = call_tool("sh", {"cmd": 'rm -rf "/"'})
T("[guard]" in text_of(r), "E22 拦: 引号包裹的 rm -rf \"/\"")
r = call_tool("sh", {"cmd": "rm --no-preserve-root -rf /"})
T("[guard]" in text_of(r), "E23 拦: 长选项 rm --no-preserve-root")
r = call_tool("sh", {"cmd": "rm -rf '/' "})
T("[guard]" in text_of(r), "E24 拦: 单引号+尾空格")
r = call_tool("file_write_text", {"path": "//dev/null", "text": "x"})
T("[guard]" in text_of(r), "E25 拦: 双斜杠 //dev/null")
r = call_tool("file_write_text", {"path": "/dev/../dev/null", "text": "x"})
T("[guard]" in text_of(r), "E26 拦: /dev/../dev/null 穿越")
r = call_tool("sh", {"cmd": "cat " + os.path.join(HOME, "slimproxy", ".token")})
T("[guard]" in text_of(r), "E27 拦: shell 直读 .token 凭证")
r = call_tool("file_read", {"path": os.path.join(HOME, "slimproxy", ".token")})
T("[guard]" in text_of(r), "E28 拦: file_read 读 .token（分级提权链）")
r = call_tool("tool_call", {"id": "file_cat", "arguments": {"path": os.path.join(HOME, "slimproxy", ".token")}})
T("[guard]" in text_of(r), "E29 拦: tool_call→file_cat 读 .token")
r = call_tool("file_read", {"path": os.path.join(HOME, "slimproxy", ".tokens.json")})
T("[guard]" in text_of(r), "E30 拦: file_read 读 .tokens.json")
r = call_tool("sh", {"cmd": "cat /etc/hosts"})
T("[guard]" not in text_of(r), "E31 放行: cat 普通文件不误伤")
r = call_tool("sh", {"cmd": "rm -rf " + os.path.join(HOME, "logs", "toolout")})  # 261112: 放行语义不变,不留静态死路径
T("[guard]" not in text_of(r), "E32 放行: rm 具体子目录不误伤")
r = call_tool("file_write_text", {"path": os.path.join(HOME, "slimproxy2", "x.py"), "text": "x"})
T("[guard]" not in text_of(r), "E33 放行: slimproxy2 相似目录不误伤")

# --- E·v1.3.1 误伤回归（/dev/null 等无害设备放行） ---
r = call_tool("sh", {"cmd": "echo hi >/dev/null 2>&1"})
T("[guard]" not in text_of(r), "E34 放行: >/dev/null 2>&1")
r = call_tool("sh", {"cmd": "nohup sh /data/lemonbrain/slimproxy/watchdog_v130.sh >/dev/null 2>&1 &"})
T("[guard]" not in text_of(r), "E35 放行: nohup 看门狗（部署命令形态）")
r = call_tool("sh", {"cmd": "dd if=/dev/zero of=/dev/null"})
T("[guard]" not in text_of(r), "E36 放行: dd of=/dev/null")
r = call_tool("sh", {"cmd": "echo x > /dev/block/sda"})
T("[guard]" in text_of(r), "E37 拦: 重定向写 /dev/block")
r = call_tool("sh", {"cmd": "mkfs.ext4 /dev/null"})
T("[guard]" not in text_of(r), "E38 放行: mkfs /dev/null（伪目标）")

# --- F. 写前快照 ---
victim = os.path.join(HOME, "victim.txt")
r = call_tool("file_write_text", {"path": victim, "text": "第一版内容"})
T("written" in text_of(r), "F1 首次写入成功")
snap_dir = os.path.join(HOME, "snapshots")
n_before = len(os.listdir(snap_dir)) if os.path.isdir(snap_dir) else 0
T(n_before == 0, "F2 首次写入(文件不存在)无快照")
r = call_tool("file_write_text", {"path": victim, "text": "第二版内容"})
T("written" in text_of(r), "F3 覆盖写入成功")
snaps = os.listdir(snap_dir) if os.path.isdir(snap_dir) else []
T(len(snaps) == 1, "F4 覆盖写入产生 1 份快照")
snap_file = os.path.join(snap_dir, snaps[0]) if snaps else ""
T(snap_file and open(snap_file, encoding="utf-8").read() == "第一版内容", "F5 快照内容=旧版")
ev = (r.get("_meta") or {}).get("slim", {}).get("events", [])
T(any("snapshot" in e for e in ev), "F6 _meta 携带快照路径")
T(open(victim, encoding="utf-8").read() == "第二版内容", "F7 新内容已生效")

# --- G. 审计日志 ---
audit_file = os.path.join(HOME, "logs", "audit.jsonl")
T(os.path.isfile(audit_file), "G1 审计日志已生成")
lines = open(audit_file, encoding="utf-8").read().strip().split("\n")
recs = [json.loads(l) for l in lines if l.strip()]
T(len(recs) >= 30, "G2 审计条数充足")
T(all("args_sha256" in r and "ts" in r and "ms" in r for r in recs), "G3 字段齐全")
T(all(MASTER not in l for l in lines), "G4 审计不落令牌明文")
T(any(r.get("note") and "guard" in str(r.get("note")) for r in recs), "G5 拦截事件有记录")
T(any(r.get("ok") is True for r in recs), "G6 正常调用有记录")

# --- H. /metrics ---
st, m = req(LO_PORT, "GET", "/metrics")
T(st == 200 and m.get("version") == "1.3.1", "H1 本机口 /metrics 200")
T(m.get("calls", 0) > 30, "H2 calls 计数")
T(m.get("blocked", 0) >= 12, "H3 blocked 计数")
T(m.get("truncated", 0) >= 1, "H4 truncated 计数")
T(m.get("snapshots", 0) >= 1, "H5 snapshots 计数")
T(isinstance(m.get("by_tool"), dict) and m["by_tool"].get("sh", 0) > 0, "H6 by_tool 分桶")
st, _ = req(PUB_PORT, "GET", "/metrics", token=MASTER)
T(st == 404, "H7 公网口 /metrics 拒绝")

# --- I. 公网口鉴权（旧单令牌模式） ---
st, _ = req(PUB_PORT, "GET", "/")
T(st == 404, "I1 无令牌 404")
st, _ = req(PUB_PORT, "GET", "/", token="wrong-token")
T(st == 404, "I2 错令牌 404")
st, d = req(PUB_PORT, "GET", "/", token=MASTER)
T(st == 200 and d.get("ok"), "I3 Bearer 主令牌放行")
st, d = req(PUB_PORT, "GET", "/mcp/" + MASTER)
T(st == 200 and d.get("ok"), "I4 路径段令牌放行（takin 链接形态）")
st, d = req(PUB_PORT, "GET", "/?token=" + MASTER)
T(st == 200, "I5 query 令牌放行")
for i in range(9):
    req(PUB_PORT, "GET", "/", token="bad-%d" % i)
st, d = req(PUB_PORT, "GET", "/", token=MASTER)
T(st == 200, "I6 熔断中有效令牌仍可解除（合法用户不锁死）")
st, b = req(PUB_PORT, "POST", "/", body="{bad json", token=MASTER, raw=True)
T(st == 400, "I7 畸形 JSON 回 400")
st, b = req(PUB_PORT, "POST", "/", body=b"x" * (1024 * 1024 + 10), token=MASTER, raw=True)
T(st == 413, "I8 超 1MB 回 413")

# --- J. 杂项协议 ---
st, d = rpc(LO_PORT, "ping")
T(st == 200 and d.get("result") == {}, "J1 ping")
st, b = req(LO_PORT, "POST", "/", body={"jsonrpc": "2.0", "method": "notifications/initialized"}, raw=True)
T(st == 204, "J2 无 id 通知回 204")
st, d = rpc(LO_PORT, "custom/method", {"a": 1})
T((d.get("result") or {}).get("echo", {}).get("a") == 1, "J3 未知方法透传上游")
st, d = rpc(LO_PORT, "tools/call", {"name": "sh", "arguments": "not-a-dict"})
T(st == 200, "J4 非对象参数不炸")

# --- K. SSE ---
try:
    c = http.client.HTTPConnection("127.0.0.1", LO_PORT, timeout=8)
    c.request("GET", "/sse")
    resp = c.getresponse()
    T(resp.status == 200, "K1 SSE 200")
    T("text/event-stream" in (resp.getheader("Content-Type") or ""), "K2 SSE content-type")
    first = resp.read1(4096).decode("utf-8", "replace")
    m = re.search(r"sessionId=([0-9a-f]+)", first)
    T(bool(m), "K3 endpoint 帧含 sessionId")
    sid = m.group(1) if m else ""
    st, _ = req(LO_PORT, "POST", "/messages?sessionId=" + sid,
                {"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}})
    T(st == 202, "K4 /messages 202")
    chunk = resp.read1(8192).decode("utf-8", "replace")
    T("protocolVersion" in chunk and "2025-03-26" in chunk, "K5 SSE 回推 initialize 响应")
    st, d = req(LO_PORT, "POST", "/messages?sessionId=bogus", {"jsonrpc": "2.0", "id": 1, "method": "ping"})
    T(st == 404, "K6 假 sessionId 404")
    # K7: SSE 通道内 tools/call（覆盖 dispatch_call 的 SSE 分支）
    st, _ = req(LO_PORT, "POST", "/messages?sessionId=" + sid,
                {"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                 "params": {"name": "file_read", "arguments": {"path": target, "limit": 200}}})
    T(st == 202, "K7 SSE tools/call 202")
    chunk = resp.read1(8192).decode("utf-8", "replace")
    T("file_read" in chunk and "第0行" in chunk, "K8 SSE 通道 file_read 正常回推")
    c.close()
except Exception as e:
    T(False, "K-SSE 异常: %r" % e)

stop_proxy()

# ================= 阶段2：分级令牌模式 =================
print("== 阶段2：分级令牌（.tokens.json） ==")
start_proxy(scoped=True)
target = os.path.join(HOME, "big_cn.txt")
with open(target, "w", encoding="utf-8") as f:
    f.write(orig_text)

st, d = req(PUB_PORT, "GET", "/", token=SCOPED["root"])
T(st == 200 and d.get("scoped_tokens") is True, "L1 分级模式生效")
st, d = req(PUB_PORT, "GET", "/", token=MASTER)
T(st == 200, "L2 旧主令牌兼容=root")

# readonly 令牌
tok = SCOPED["readonly"]
r = call_tool("tool_find", {"q": "apk"}, port=PUB_PORT, token=tok)
T("apk_sign" in text_of(r), "L3 readonly 可用 tool_find")
r = call_tool("file_read", {"path": target, "limit": 100}, port=PUB_PORT, token=tok)
T("[file_read]" in text_of(r), "L4 readonly 可用 file_read")
r = call_tool("file_write_text", {"path": os.path.join(HOME, "x.txt"), "text": "x"}, port=PUB_PORT, token=tok)
T("权限不足" in text_of(r), "L5 readonly 禁 file_write_text")
r = call_tool("sh", {"cmd": "echo hi"}, port=PUB_PORT, token=tok)
T("权限不足" in text_of(r), "L6 readonly 禁 sh")
r = call_tool("tool_call", {"id": "file_cat", "arguments": {"path": target}}, port=PUB_PORT, token=tok)
T("权限不足" not in text_of(r) and "第0行" in text_of(r), "L7 readonly 经 tool_call 调只读工具放行")
r = call_tool("tool_call", {"id": "sh", "arguments": {"cmd": "echo hi"}}, port=PUB_PORT, token=tok)
T("权限不足" in text_of(r), "L8 readonly 经 tool_call 调 sh 被拦")
r = call_tool("tool_call", {"id": "apk_sign", "arguments": {}}, port=PUB_PORT, token=tok)
T("权限不足" in text_of(r), "L9 readonly 调未知工具按默认 write 拦截")

# write 令牌
tok = SCOPED["write"]
r = call_tool("file_write_text", {"path": os.path.join(HOME, "x.txt"), "text": "x"}, port=PUB_PORT, token=tok)
T("written" in text_of(r), "L10 write 可写文件")
r = call_tool("sh", {"cmd": "echo hi"}, port=PUB_PORT, token=tok)
T("权限不足" in text_of(r), "L11 write 禁 sh")
r = call_tool("tool_call", {"id": "apk_sign", "arguments": {}}, port=PUB_PORT, token=tok)
T("echo apk_sign" in text_of(r), "L12 write 调未知工具(默认write)放行")
r = call_tool("tool_find", {"q": "apk"}, port=PUB_PORT, token=tok)
T("apk_sign" in text_of(r), "L13 write 可用只读门面")

# root 令牌
tok = SCOPED["root"]
r = call_tool("sh", {"cmd": "echo root-ok"}, port=PUB_PORT, token=tok)
T("root-ok" in text_of(r), "L14 root 可用 sh")
r = call_tool("tool_call", {"id": "sh", "arguments": {"cmd": "echo root2"}}, port=PUB_PORT, token=tok)
T("root2" in text_of(r), "L15 root 经 tool_call 调 sh 放行")

# 路径段形态的分级令牌
st, d = req(PUB_PORT, "GET", "/mcp/" + SCOPED["readonly"])
T(st == 200, "L16 分级令牌路径段形态可用")

# 分级模式下的危险护栏仍生效（root 令牌也不能 rm -rf /）
r = call_tool("sh", {"cmd": "rm -rf /"}, port=PUB_PORT, token=SCOPED["root"])
T("[guard]" in text_of(r), "L17 root 令牌仍受危险护栏约束")

stop_proxy()

# ================= 汇总 =================
total = PASS[0] + FAIL[0]
print("=" * 50)
print("测试完成：共 %d 项断言，通过 %d，失败 %d" % (total, PASS[0], FAIL[0]))
if FAILURES:
    print("失败明细：")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1)
print("全部通过 ✓")
