#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_v150.py —— v1.5.0 验收：备用维护通道 + LOCKDOWN 熔断 + 金丝雀切换（故障注入）+ 双活看门狗"""
import http.client, json, os, re, shutil, signal, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
MAINT = os.path.join(BASE, "maint_server.py")
PROXY = os.path.join(BASE, "slim_proxy_v132.py")
SWITCH = os.path.join(BASE, "switch.sh")
WD = os.path.join(BASE, "watchdog_v150.sh")
TEST_HOME = "/tmp/v150_test"
UP = 19788          # mock 上游
MP = 19795          # maint 口
TOK = "maint-token-test-150"

PASS = [0]; FAIL = [0]; FAILURES = []
def T(cond, label):
    if cond: PASS[0] += 1
    else:
        FAIL[0] += 1; FAILURES.append(label); print("  ✗ FAIL:", label)

def cleanup():  # 杀掉 switch/nohup 拉起的游离进程（跨轮残留会让断言失真）
    for pat in ["maint_server.py", "slim_proxy_v13", "sw/slim_proxy.py", "watchdog_v150.sh"]:
        subprocess.run(["pkill", "-f", pat], capture_output=True)
    time.sleep(0.5)

cleanup()

# ---------- mock 上游 ----------
class MockH(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        m = req.get("method"); p = req.get("params") or {}
        if m == "tools/list":
            res = {"tools": [{"name": "sh", "description": "sh", "inputSchema": {"type": "object", "properties": {}}}]}
        elif m == "tools/call":
            a = p.get("arguments") or {}
            if p.get("name") == "sh":
                res = {"content": [{"type": "text", "text": "[exit=0]\nmock:%s" % (a.get("cmd") or "")}], "isError": False}
            elif p.get("name") == "file_write_text":
                res = {"content": [{"type": "text", "text": "written"}], "isError": False}
            else:
                res = {"content": [{"type": "text", "text": "echo"}], "isError": False}
        else:
            res = {}
        data = json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": res}, ensure_ascii=False).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

ThreadingHTTPServer.allow_reuse_address = True
mock = ThreadingHTTPServer(("127.0.0.1", UP), MockH)
mock.daemon_threads = True
threading.Thread(target=mock.serve_forever, daemon=True).start()

def req(port, method="GET", path="/", body=None, token=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    h = {}
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode()
        h["Content-Type"] = "application/json"
    if token: h["Authorization"] = "Bearer " + token
    try:
        c.request(method, path, body=data, headers=h)
    except (BrokenPipeError, ConnectionResetError, ConnectionRefusedError, OSError):
        c.close(); return 0, {}
    try:
        r = c.getresponse(); b = r.read()
    except Exception:
        c.close(); return 0, {}
    c.close()
    try: return r.status, json.loads(b.decode("utf-8", "replace"))
    except Exception: return r.status, b

def rpc(port, method, params=None, token=None, path="/"):
    return req(port, "POST", path, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, token=token)

def wait_port(port, timeout=10, want_down=False):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = socket.socket()
        try:
            s.settimeout(0.4); s.connect(("127.0.0.1", port)); s.close(); up = True
        except Exception:
            up = False
        finally:
            s.close()
        if up != want_down: return True
        time.sleep(0.2)
    return False

PROCS = []
def start(script, env_extra):
    env = dict(os.environ); env.update(env_extra)
    p = subprocess.Popen([sys.executable, script], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    PROCS.append(p)
    return p

# ================= M. maint_server =================
print("== M. 备用维护通道 ==")
shutil.rmtree(TEST_HOME, ignore_errors=True)
os.makedirs(os.path.join(TEST_HOME, "slimproxy"), exist_ok=True)

# M1 无令牌拒绝启动
p = start(MAINT, {"LEMON_HOME": TEST_HOME, "LEMON_MAINT_PORT": str(MP),
                  "LEMON_UPSTREAM": "http://127.0.0.1:%d" % UP})
time.sleep(2)
T(p.poll() is not None, "M1 无令牌拒绝启动（不裸奔）")
T(not wait_port(MP, 2), "M2 无令牌不监听")

with open(os.path.join(TEST_HOME, "slimproxy", ".token_maint"), "w") as f:
    f.write(TOK)
p = start(MAINT, {"LEMON_HOME": TEST_HOME, "LEMON_MAINT_PORT": str(MP),
                  "LEMON_UPSTREAM": "http://127.0.0.1:%d" % UP})
T(wait_port(MP), "M3 有令牌正常监听")

st, _ = req(MP)
T(st == 404, "M4 无令牌 404")
st, d = req(MP, token=TOK)
T(st == 200 and d.get("version") == "1.0.0", "M5 Bearer 令牌健康 200")
st, d = req(MP, path="/m/" + TOK)
T(st == 200, "M6 路径段令牌可用")
st, d = rpc(MP, "initialize", {"protocolVersion": "2025-03-26"}, token=TOK)
T(d["result"]["protocolVersion"] == "2025-03-26", "M7 initialize 回显")
T(d["result"]["serverInfo"]["name"] == "小柠檬内核·备用维护通道", "M8 serverInfo 名称")
st, d = rpc(MP, "tools/list", token=TOK)
names = [t["name"] for t in d["result"]["tools"]]
T(sorted(names) == ["file_read", "file_write_text", "sh", "upstream_ping"], "M9 恰好4个保命工具")

st, d = rpc(MP, "tools/call", {"name": "sh", "arguments": {"cmd": "echo hello"}}, token=TOK)
T("mock:echo hello" in d["result"]["content"][0]["text"], "M10 sh 直通上游")
st, d = rpc(MP, "tools/call", {"name": "sh", "arguments": {"cmd": "rm -rf /"}}, token=TOK)
T(d["result"]["isError"] and "[guard]" in d["result"]["content"][0]["text"], "M11 护栏拦 rm -rf /")
st, d = rpc(MP, "tools/call", {"name": "sh", "arguments": {"cmd": "cat /x/.token"}}, token=TOK)
T("[guard]" in d["result"]["content"][0]["text"], "M12 护栏拦读凭证")
st, d = rpc(MP, "tools/call", {"name": "sh", "arguments": {"cmd": "echo x >/dev/null 2>&1"}}, token=TOK)
T("[guard]" not in d["result"]["content"][0]["text"], "M13 放行 >/dev/null")

tf = os.path.join(TEST_HOME, "m.txt")
open(tf, "w", encoding="utf-8").write("维护通道文件读取测试" * 200)
st, d = rpc(MP, "tools/call", {"name": "file_read", "arguments": {"path": tf, "limit": 500}}, token=TOK)
txt = d["result"]["content"][0]["text"]
T("[file_read]" in txt and "下段 offset=" in txt, "M14 file_read 分段提示")
st, d = rpc(MP, "tools/call", {"name": "file_read", "arguments": {"path": os.path.join(TEST_HOME, "slimproxy", ".token_maint")}}, token=TOK)
T("[guard]" in d["result"]["content"][0]["text"], "M15 file_read 拦凭证")
st, d = rpc(MP, "tools/call", {"name": "upstream_ping"}, token=TOK)
T("上游存活" in d["result"]["content"][0]["text"], "M16 upstream_ping")
st, d = rpc(MP, "tools/call", {"name": "rm_everything"}, token=TOK)
T(d["result"]["isError"], "M17 未知工具报错")
st, _ = req(MP, "POST", "/", body=None, token=TOK)  # 空 body
T(st in (200, 400), "M18 空body不崩")
st, d = rpc(MP, "tools/call", {"name": "file_write_text", "arguments": {"path": "/dev/null", "text": "x"}}, token=TOK)
T("[guard]" in d["result"]["content"][0]["text"], "M19 写/dev被拦")
st, d = rpc(MP, "tools/call", {"name": "file_write_text", "arguments": {"path": tf, "text": "x"}}, token=TOK)
T("written" in d["result"]["content"][0]["text"], "M20 正常写放行")

# ================= L. LOCKDOWN 熔断（v1.3.2） =================
print("== L. LOCKDOWN 熔断 ==")
LP, LP2 = 19791, 19792
with open(os.path.join(TEST_HOME, "slimproxy", ".token"), "w") as f:
    f.write("master-150")
os.makedirs(os.path.join(TEST_HOME, "tools/_索引"), exist_ok=True)
p = start(PROXY, {"LEMON_HOME": TEST_HOME, "LEMON_SLIM_PORT": str(LP),
                  "LEMON_SLIM_PORT2": str(LP2),
                  "LEMON_UPSTREAM": "http://127.0.0.1:%d" % UP})
T(wait_port(LP) and wait_port(LP2), "L0 v1.3.2 双口启动")
st, d = req(LP2, token="master-150")
T(st == 200 and d.get("lockdown") is False, "L1 平时 lockdown=false")

LK = os.path.join(TEST_HOME, "slimproxy", "LOCKDOWN")
open(LK, "w").write("1")
st, d = req(LP2, token="master-150")
T(d.get("lockdown") is True, "L2 熔断后健康显示 lockdown=true（热生效免重启）")
st, d = rpc(LP2, "tools/call", {"name": "sh", "arguments": {"cmd": "echo x"}}, token="master-150")
T("权限不足" in d["result"]["content"][0]["text"], "L3 熔断中 root 令牌调 sh 被降级拒绝")
st, d = rpc(LP2, "tools/call", {"name": "file_write_text", "arguments": {"path": tf, "text": "y"}}, token="master-150")
T("权限不足" in d["result"]["content"][0]["text"], "L4 熔断中写文件被拒")
st, d = rpc(LP2, "tools/call", {"name": "tool_find", "arguments": {"q": "sh"}}, token="master-150")
T("T-" in d["result"]["content"][0]["text"], "L5 熔断中只读工具仍可用")
st, d = rpc(LP, "tools/call", {"name": "sh", "arguments": {"cmd": "echo local"}})
T("mock:echo local" in d["result"]["content"][0]["text"], "L6 本机口不受熔断影响")
os.remove(LK)
st, d = rpc(LP2, "tools/call", {"name": "sh", "arguments": {"cmd": "echo back"}}, token="master-150")
T("mock:echo back" in d["result"]["content"][0]["text"], "L7 解除熔断即恢复")

# ================= S. switch.sh 金丝雀切换 =================
print("== S. 金丝雀切换（故障注入） ==")
SWH = os.path.join(TEST_HOME, "sw")
shutil.rmtree(SWH, ignore_errors=True)
os.makedirs(SWH, exist_ok=True)
# 旧版（v1.3.2 改名装老）与“新版”（VERSION 改为 9.9.9-test）
shutil.copy(PROXY, os.path.join(SWH, "slim_proxy.py"))
newp = open(PROXY, encoding="utf-8").read().replace('VERSION = "1.3.2"', 'VERSION = "9.9.9-test"')
open(os.path.join(SWH, "slim_proxy_v133.py"), "w", encoding="utf-8").write(newp)
open(os.path.join(SWH, ".token"), "w").write("master-150")
# mock start.sh / stop.sh / start_maint.sh
open(os.path.join(SWH, "start.sh"), "w").write(
    '#!/system/bin/sh\nnohup env LEMON_HOME=%s LEMON_SLIM_PORT=$SWITCH_PORT LEMON_SLIM_PORT2=$SWITCH_PORT2 %s -u %s/slim_proxy.py >/dev/null 2>&1 &\necho $! > %s/.slim.$SWITCH_PORT.pid\n' % (TEST_HOME, sys.executable, SWH, SWH))
open(os.path.join(SWH, "stop.sh"), "w").write(
    '#!/system/bin/sh\nkill $(cat %s/.slim.$SWITCH_PORT.pid) 2>/dev/null\n' % SWH)
open(os.path.join(SWH, "start_maint.sh"), "w").write(
    '#!/system/bin/sh\nnohup env LEMON_HOME=%s LEMON_MAINT_PORT=$SWITCH_MAINT_PORT LEMON_UPSTREAM=http://127.0.0.1:%d %s -u %s/maint_server.py >/dev/null 2>&1 &\n' % (TEST_HOME, UP, sys.executable, BASE))
# maint 令牌
# （TEST_HOME/slimproxy/.token_maint 已在上面 M 阶段写好）

SWP, SWP2, SWM, SWPRE = 19881, 19882, 19885, 19883
swenv = {"SWITCH_HOME": SWH, "SWITCH_PORT": str(SWP), "SWITCH_PORT2": str(SWP2),
         "SWITCH_MAINT_PORT": str(SWM), "SWITCH_PRE_PORT": str(SWPRE),
         "SWITCH_PRE_PORT2": "19884", "SWITCH_PY": sys.executable,
         "SWITCH_TOKEN_DIR": os.path.join(TEST_HOME, "slimproxy"),
         "LEMON_HOME": TEST_HOME,
         "SWITCH_LOG": os.path.join(TEST_HOME, "switch.log"),
         "SWITCH_PROXY_LOG": os.path.join(TEST_HOME, "proxy.log")}
# maint token 需要落到 TEST_HOME/slimproxy —— start_maint 用 LEMON_HOME=TEST_HOME ✓

def run_switch(newfile):
    env = dict(os.environ); env.update(swenv)
    r = subprocess.run(["sh", SWITCH, newfile], env=env, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr

# S1: 新版文件不存在 → 拒绝
rc, out = run_switch("nonexistent.py")
T(rc == 1 and "缺少" in out, "S1 缺文件拒绝切换")

# S2: 备用通道死 + start_maint 坏 → 拒绝（exit 2）
os.rename(os.path.join(SWH, "start_maint.sh"), os.path.join(SWH, "start_maint.sh.bak"))
rc, out = run_switch("slim_proxy_v133.py")
T(rc == 2 and "拒绝切换" in out, "S2 备用通道不可用拒绝开工")
os.rename(os.path.join(SWH, "start_maint.sh.bak"), os.path.join(SWH, "start_maint.sh"))

# S3: 备用通道死 → switch 自动拉起 maint → 继续
rc, out = run_switch("slim_proxy_v133.py")
T("备用通道存活" in out, "S3 switch 自动拉起备用通道")
T(wait_port(SWM), "S4 maint 已被拉起")
# 此刻旧版未在跑（首次切换），switch 会起新版
T(rc == 0 and "切换完成" in out, "S5 首次切换成功")
st, d = req(SWP)
T(d.get("version") == "9.9.9-test", "S6 新版已上线")

# S7: 预热失败（坏py）→ 旧版不动
open(os.path.join(SWH, "broken.py"), "w").write("def broken(:\n")
rc, out = run_switch("broken.py")
T(rc == 3, "S7 预热失败 exit=3")
st, d = req(SWP)
T(d.get("version") == "9.9.9-test", "S8 旧版（实为上一新版）未被破坏")
T(not os.path.exists(os.path.join(SWH, ".switching")), "S9 切换结束后 .switching 标志已被 trap 清除")

# ================= W. 双活看门狗 =================
print("== W. 双活看门狗 ==")
WDH = os.path.join(TEST_HOME, "wd")
shutil.rmtree(WDH, ignore_errors=True)
os.makedirs(WDH, exist_ok=True)
wdlog = os.path.join(TEST_HOME, "wd.log")
env = dict(os.environ)
env.update({"WD_HOME": WDH, "WD_LOG": wdlog, "WD_DRYRUN": "1"})
# 先放一个新鲜 .switching 标志：看门狗应跳过巡检（不和 switch.sh 抢端口）
open(os.path.join(WDH, ".switching"), "w").write(str(int(time.time())))
wdp = subprocess.Popen(["sh", WD, "secondary"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PROCS.append(wdp)
time.sleep(6)
lg = open(wdlog, encoding="utf-8").read() if os.path.exists(wdlog) else ""
T("双活看门狗 v5.0 启动" in lg and "secondary" in lg, "W1 secondary 启动留痕")
T(os.path.exists(os.path.join(WDH, ".hb", "secondary")), "W2 心跳文件写入")
T("切换进行中" in lg and "本轮巡检跳过" in lg, "W4 存在 .switching 时看门狗跳过巡检")
T("primary 进程失踪" not in lg, "W5 切换标志生效期间不误报补位")
# 删掉标志：看门狗恢复巡检，应检测到 primary 失联并补位
os.remove(os.path.join(WDH, ".switching"))
time.sleep(8)
wdp.terminate()
lg = open(wdlog, encoding="utf-8").read()
T("primary 进程失踪" in lg, "W3 标志清除后检测到 primary 失联（接管逻辑触发）")

# ================= 汇总 =================
for p in PROCS:
    try: p.terminate()
    except Exception: pass
cleanup()
total = PASS[0] + FAIL[0]
print("=" * 50)
print("v1.5.0 测试：共 %d 项断言，通过 %d，失败 %d" % (total, PASS[0], FAIL[0]))
if FAILURES:
    for f in FAILURES: print("  -", f)
    sys.exit(1)
print("全部通过 ✓")
