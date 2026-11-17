#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
slim_proxy_v130.py —— 小柠檬内核·瘦身代理 v1.3.0（261111 安全与体验加固版）
基于 v1.2.0 全量保留，新增：
  ① 分级令牌（.tokens.json 可选：readonly/write/root；缺省=旧行为完全兼容）
  ② 危险命令护栏（sh/shell_exec/shell_script/file_write 前置拦截，.cmdguard.json 可配）
  ③ file_write_text 写前自动快照（/data/lemonbrain/snapshots/，保留最近200份）
  ④ 结构化截断（result._meta.slim.events：truncated/total_bytes/full_path）
  ⑤ 新门面工具 file_read（offset/limit 分段读，治 4KB 截断多轮痛点）
  ⑥ 审计日志 audit.jsonl（参数只落 sha256，不落明文）
  ⑦ /metrics 指标端点（仅本机口 8791）
  ⑧ 顺手修复：KeyboardInterrupt 分支裸语句补回 log()
环境开关：LEMON_GUARD=0 / LEMON_SNAPSHOT=0 / LEMON_AUDIT=0 / LEMON_HOME=<目录>
作用：客户端连 8791，只看到 15 个工具（热档11 + 门面4）
上游：127.0.0.1:8788
"""

import json
import os
import hmac
import random
import re
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("LEMON_UPSTREAM", "http://127.0.0.1:8788")
# ---- 261112 v1.3.4：MT 管理器 MCP(8787) 集成 ----
MT_URL = os.environ.get("LEMON_MT_URL", "http://127.0.0.1:8787/mcp")
MT_TIMEOUT = float(os.environ.get("LEMON_MT_TIMEOUT", "15"))
MT_BREAK_S = float(os.environ.get("LEMON_MT_BREAK_S", "30"))
global MT_TOOLS, MT_BY_ID, MT_BY_NAME, MT_INDEX_TS, MT_DOWN_UNTIL, MT_LAST_ERR
MT_TOOLS = []
MT_BY_ID = {}
MT_BY_NAME = {}
MT_INDEX_TS = 0.0
MT_DOWN_UNTIL = 0.0
MT_LAST_ERR = ""
MT_LOCK = threading.Lock()

LISTEN_PORT = int(os.environ.get("LEMON_SLIM_PORT", "8791"))
LISTEN_HOST = os.environ.get("LEMON_SLIM_HOST", "127.0.0.1")
LEMON_HOME = os.environ.get("LEMON_HOME", "/data/lemonbrain")
VERSION = "1.5.0"

# ==== v1.3.6 五域 resources 接口（可选模块：加载失败即降级，老链路零影响）====
import os as _os
import sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
try:
    import lemon_res as _LR
    RES_ON = True
except Exception as _res_imp_err:
    _LR = None
    RES_ON = False
IDX_DIR = os.path.join(LEMON_HOME, "tools/_索引")
LOG_DIR = os.path.join(LEMON_HOME, "logs")
LOG_FILE = os.path.join(LOG_DIR, "slimproxy.log")
MAX_BYTES = 4096       # #418 标准：4KB 限长 + 全文落盘（261101 恢复分流，lemon-user钦定）
LOG_MAX = 2 * 1024 * 1024
PROTO = "2025-06-18"

# ---- gate64k (261113, lemon-user批准): 输出门禁按需升级 ----
GATE_MAX = 65536       # max_bytes 硬上限
GATE_RESERVE = 128     # file_read 块+提示预留（生产验证值，默认行为逐字节不变）

def effective_gate(args):
    """默认 MAX_BYTES 不变；显式 max_bytes 按需升高，钳制 [MAX_BYTES, GATE_MAX]。
    返回 (gate, warn或None)"""
    a = args if isinstance(args, dict) else {}
    try:
        req = int(a.get("max_bytes") or MAX_BYTES)
    except Exception:
        req = MAX_BYTES
    if req < MAX_BYTES:
        req = MAX_BYTES
    warn = None
    if req > GATE_MAX:
        warn = {"requested": req, "applied": GATE_MAX,
                "note": "max_bytes 超硬上限，已钳到 %d" % GATE_MAX}
        req = GATE_MAX
    return req, warn

# ---- 261103 公网鉴权 ----
# 开启条件：环境变量 LEMON_SLIM_TOKEN 或 /data/lemonbrain/slimproxy/.token 非空
# 通过方式：Authorization: Bearer <token> 或请求路径含 /<token>（URL 即密钥）
# 为空 = 不鉴权（纯本机回环模式，行为与旧版完全一致）
def _load_token():
    t = os.environ.get("LEMON_SLIM_TOKEN", "").strip()
    if t:
        return t
    try:
        with open(os.path.join(LEMON_HOME, "slimproxy", ".token"), "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""
SLIM_TOKEN = _load_token()
# 公网隧道专用口（cloudflared 连这里，强制Token；Token未配置则不监听，防裸奔）
LISTEN_PORT2 = int(os.environ.get("LEMON_SLIM_PORT2", "8792"))

HOT = ["sh", "shell_exec", "task_poll", "task_submit",
       "file_write_text", "file_head", "file_ls", "file_cat",
       "text_search_regex", "file_find", "shell_script"]

FACADE = ["tool_find", "tool_get", "tool_call", "file_read", "task_submit", "task_status", "task_result"]

FACADE_DEFS = [
    {"name": "task_submit",
     "description": "[门面] 提交异步长任务：立即返回 task_id，后台执行任意工具，根治隧道超时。用 task_status 查进度、task_result 取结果。",
     "inputSchema": {"type": "object", "properties": {
         "tool": {"type": "string", "description": "要执行的工具名或T-编号"},
         "arguments": {"type": "object", "description": "工具参数对象，无参传 {}"}},
         "required": ["tool"]}},
    {"name": "task_status",
     "description": "[门面] 查异步任务状态：task_id → running/done/failed + 耗时秒。",
     "inputSchema": {"type": "object", "properties": {
         "task_id": {"type": "string", "description": "task_submit 返回的ID"}},
         "required": ["task_id"]}},
    {"name": "task_result",
     "description": "[门面] 取异步任务结果：task_id → 工具输出（done时）。可带 max_bytes 升门禁（默认4096最高65536）。",
     "inputSchema": {"type": "object", "properties": {
         "task_id": {"type": "string", "description": "任务ID"},
         "max_bytes": {"type": "integer", "description": "输出门禁字节数"}},
         "required": ["task_id"]}},
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
     "description": "[门面] 按编号执行工具：T-编号/工具名 + arguments 对象。输出超门禁自动截断并提示（默认4KB；可带 max_bytes 最高65536）。",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string", "description": "T-编号或工具名"},
         "arguments": {"type": "object", "description": "参数对象，无参传 {}"},
         "max_bytes": {"type": "integer", "description": "单次输出门禁字节数，默认4096，最高65536（超过自动钳制）；不传=老行为"}},
         "required": ["id"]}},
    {"name": "file_read",
     "description": "[门面] 分段读取本地文件：path + offset(字节,默认0) + limit(字节,默认门禁-128)。UTF-8 安全截断，返回带 next_offset/eof，适合读大文件。默认门禁4096(段3968)；可带 max_bytes 最高65536(段65408)。",
     "inputSchema": {"type": "object", "properties": {
         "path": {"type": "string", "description": "目标路径"},
         "offset": {"type": "integer", "description": "起始字节，默认0"},
         "limit": {"type": "integer", "description": "读取字节数，默认门禁-128（默认3968；带 max_bytes=65536 时最大65408）"},
         "max_bytes": {"type": "integer", "description": "单次输出门禁字节数，默认4096，最高65536（超过自动钳制）；不传=老行为"}},
         "required": ["path"]}},
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

# ==================== v1.3.0 安全与体验加固（261111 · lemon-user验收）====================
# 新增：①分级令牌(.tokens.json,可选,缺省完全兼容旧行为) ②危险命令护栏 ③写前快照
#       ④结构化截断 _meta ⑤file_read 分段读取 ⑥审计日志 ⑦/metrics(仅本机口)
# 全部默认开启安全项；LEMON_GUARD=0 / LEMON_SNAPSHOT=0 / LEMON_AUDIT=0 可关
SNAP_DIR = os.path.join(LEMON_HOME, "snapshots")
AUDIT_FILE = os.path.join(LOG_DIR, "audit.jsonl")
TOKENS_FILE = os.path.join(LEMON_HOME, "slimproxy", ".tokens.json")
GUARD_CONF = os.path.join(LEMON_HOME, "slimproxy", ".cmdguard.json")
LOCKDOWN_FILE = os.path.join(LEMON_HOME, "slimproxy", "LOCKDOWN")   # v1.3.2 熔断：存在即公网只读
SNAP_KEEP = int(os.environ.get("LEMON_SNAP_KEEP", "200") or "200")
SNAP_MAX_BYTES = 5 * 1024 * 1024      # 单文件快照上限 5MB
GUARD_ON = os.environ.get("LEMON_GUARD", "1") != "0"
SNAP_ON = os.environ.get("LEMON_SNAPSHOT", "1") != "0"
AUDIT_ON = os.environ.get("LEMON_AUDIT", "1") != "0"
AUDIT_MAX = 1024 * 1024               # 审计日志限长 1MB
SCOPE_RANK = {"none": 0, "readonly": 1, "write": 2, "root": 3}

# ---- 分级令牌 ----
# .tokens.json 形如 {"readonly":"tokR","write":"tokW","root":"tokX","default_scope":"write"}
# 文件不存在 = 旧行为：.token 主令牌 = root 全权（现有 takin 链接不受影响）
def _load_scoped_tokens():
    try:
        with open(TOKENS_FILE, "r", encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict) and any((d.get(k) or "").strip() for k in ("readonly", "write", "root")):
            return d
    except Exception:
        pass
    return None
SCOPED_TOKENS = _load_scoped_tokens()

# ---- v1.3.3 令牌热加载：mtime 变化即重读，轮换/吊销免重启（stat 开销微秒级）----
_TOK_CACHE = {"mt1": "?", "mt2": "?", "token": "", "scoped": None}
_TOK_LOCK = threading.Lock()

def _tokens_hot():
    with _TOK_LOCK:
        try: mt1 = os.stat(os.path.join(LEMON_HOME, "slimproxy", ".token")).st_mtime_ns
        except Exception: mt1 = None
        try: mt2 = os.stat(TOKENS_FILE).st_mtime_ns
        except Exception: mt2 = None
        if mt1 != _TOK_CACHE["mt1"] or mt2 != _TOK_CACHE["mt2"]:
            _TOK_CACHE["mt1"] = mt1; _TOK_CACHE["mt2"] = mt2
            _TOK_CACHE["token"] = _load_token()
            _TOK_CACHE["scoped"] = _load_scoped_tokens()
        return _TOK_CACHE["token"], _TOK_CACHE["scoped"]


ROOT_TOOLS = {"sh", "shell_exec", "shell_exec_root", "shell_script",
              "cmd_timeout_run", "cmd_watch", "shell_exec_root2",
              # 261112 红队修复：桥/任务分发 = 任意内核执行，恒 root
              # 实锤：readonly 经 lemon_call_tool{name,args} 跑出 uid=0；经 task_submit{cmd} 提交执行
              "lemon_call_tool", "task_submit", "task_cancel"}
READ_TOOLS = {"task_status", "task_result", "tool_find", "tool_get", "file_read", "file_cat", "file_head",
              "file_ls", "file_find", "text_search_regex"}

def required_scope(name):
    n = (name or "").lower()
    if n == "tool_call":
        return "readonly"     # 门面本身只读；真实要求由 do_call 对目标工具二次判定
    if n in READ_TOOLS:
        return "readonly"
    if n in ROOT_TOOLS or "exec" in n or n.startswith("su_"):
        return "root"
    if any(k in n for k in ("write", "append", "create", "delete", "_rm", "format", "flash")):
        return "write"
    _t, _sc = _tokens_hot()
    return (_sc or {}).get("default_scope") or "write"

def scope_ok(have, need):
    return SCOPE_RANK.get(have or "none", 0) >= SCOPE_RANK.get(need or "write", 2)

# ---- 危险命令/路径护栏 ----
_GUARD_CMD_RULES = [
    # 261111红队修复: ①支持长选项(--no-preserve-root) ②路径两侧容忍引号
    ("rm 毁根/一级目录", r"\brm\s+(-{1,2}[a-zA-Z][a-zA-Z-]*\s+)*[\"']?(/\*|/|/(data|system|vendor|dev|proc|sys|odm|product|system_ext|vendor_dlkm))[\"']?(['\"\s;|&)]|$)"),
    ("dd 写设备节点", r"\bdd\b[^|;]*\bof\s*=\s*[\"']?/dev/(?!(null|zero|full)([\"'\s;|&)]|$))"),
    ("重定向写设备节点", r">\s*[\"']?/dev/(?!(null|zero|full|stdin|stdout|stderr|tty)([\"'\s;|&)]|$))"),
    ("mkfs 格式化", r"\bmkfs[.\w-]*\s+[\"']?/dev/(?!(null|zero|full)([\"'\s;|&)]|$))"),
    ("fork 炸弹", r":\s*\(\s*\)\s*\{"),
    ("根目录递归改权", r"\b(chmod|chown|chgrp)\s+(-[a-zA-Z]*R[a-zA-Z]*\s+)+\S*\s+[\"']?/[\"']?(['\"\s;|&)]|$)"),
    ("刷写分区", r"\b(flash_image|fastboot\s+flash)\b"),
    ("wipe/format 分区", r"\b(wipe|format)\s+(data|system|all)\b"),
    # 261111红队修复: shell 直读凭证文件（堵 readonly→root 提权链的 shell 侧）
    ("读取凭证文件", r"\b(cat|less|more|head|tail|strings|xxd|od|base64)\b[^|;]*(/\.token(\.|$)|\.tokens\.json)"),
]
_GUARD_PATH_RULES = [
    ("凭证文件", r"/\.token(\.|$)"),
    ("分级令牌文件", r"\.tokens\.json$"),
    ("设备/内核接口节点", r"^/(dev|proc|sys)/"),
    ("门面包身文件", r"/slimproxy/[^/]*\.(py|sh)$"),
]
# 读取类工具的敏感路径（凭证即权限，读=偷）
_GUARD_READ_RULES = [
    ("凭证文件", r"/\.token(\.|$)"),
    ("分级令牌文件", r"\.tokens\.json$"),
]
_GUARD_CONF_CACHE = {"ts": 0, "conf": {}}

def _guard_conf():
    if time.time() - _GUARD_CONF_CACHE["ts"] < 60:
        return _GUARD_CONF_CACHE["conf"]
    conf = {}
    try:
        with open(GUARD_CONF, "r", encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict):
            conf = d
    except Exception:
        pass
    _GUARD_CONF_CACHE["ts"] = time.time()
    _GUARD_CONF_CACHE["conf"] = conf
    return conf

def _match_rules(text, rules, extra):
    for label, pat in rules:
        try:
            if re.search(pat, text):
                return label
        except Exception:
            pass
    for i, pat in enumerate(extra or []):
        try:
            if re.search(pat, text):
                return "自定义规则#%d" % i
        except Exception:
            pass
    return None

def _norm_path(p):
    """路径规范化：合并多余斜杠+消解 . / ..（261111红队修复：//dev/null 绕过）"""
    try:
        p = os.path.realpath(p)
        p = os.path.normpath(p)
        p = re.sub(r"^/+", "/", p)
    except Exception:
        pass
    return p

def guard_hit(name, args):
    """命中返回 '类别:规则名'，未命中返回 None"""
    if not GUARD_ON:
        return None
    conf = _guard_conf()
    if conf.get("disabled"):
        return None
    n = (name or "").lower()
    a = args if isinstance(args, dict) else {}
    if n in ("sh", "shell_exec", "shell_exec_root", "cmd_timeout_run", "cmd_watch"):
        cmd = a.get("cmd") or a.get("command") or ""
        hit = _match_rules(str(cmd), _GUARD_CMD_RULES, conf.get("extra_cmd_patterns"))
        if hit:
            return "shell:" + hit
    if n == "shell_script":
        body = a.get("script") or a.get("cmd") or a.get("content") or ""
        hit = _match_rules(str(body), _GUARD_CMD_RULES, conf.get("extra_cmd_patterns"))
        if hit:
            return "script:" + hit
    if n.startswith("file_write") or n in ("dspp_write_file", "dspp_append_file", "file_append_text"):
        p = _norm_path(str(a.get("path") or ""))
        hit = _match_rules(p, _GUARD_PATH_RULES, conf.get("protected_paths"))
        if hit:
            return "path:" + hit
    # [261112 攻防三波] 通用写类工具参数路径检查:
    # 堵 gz_compress/text_replace/file_move/file_truncate 等旁路(不经 file_write* 的写操作)
    if any(k in n for k in ("write", "compress", "move", "copy", "delete", "_rm", "rm_",
                             "truncate", "replace", "patch", "append", "push",
                             "zip_", "_zip", "tar_", "_tar", "shred", "chmod", "chown",
                             "symlink", "link_", "chattr", "base64", "encode", "decode",
                             "b64", "hex_patch", "dd", "dump")):
        for pk in ("path", "src", "dst", "to", "zip", "tar", "file", "out", "dir", "from", "of", "if", "hex"):
            v = a.get(pk)
            if isinstance(v, str) and v:
                p = _norm_path(v)
                hit = _match_rules(p, _GUARD_PATH_RULES, conf.get("protected_paths"))
                if hit:
                    return "path2:" + hit
    # 261111红队修复: 读类工具保护凭证路径（readonly 令牌读 .token = 提权）
    if n in ("file_read", "file_cat", "file_head", "file_tail", "text_search_regex", "file_find"):
        p = _norm_path(str(a.get("path") or ""))
        hit = _match_rules(p, _GUARD_READ_RULES, conf.get("protected_read_paths"))
        if hit:
            return "read:" + hit
    return None

# ---- 写前快照 ----
def snapshot_before_write(args):
    if not SNAP_ON:
        return ""
    path = str((args or {}).get("path") or "")
    if not path or not os.path.isfile(path):
        return ""
    try:
        os.makedirs(SNAP_DIR, exist_ok=True)
        import random as _r
        base = re.sub(r"[^0-9A-Za-z_.-]", "_", os.path.basename(path))[:60] or "noname"
        dst = os.path.join(SNAP_DIR, "%s-p%d-%06x-%s" % (
            time.strftime("%Y%m%d-%H%M%S"), os.getpid(), _r.getrandbits(24), base))
        with open(path, "rb") as fi, open(dst, "wb") as fo:
            fo.write(fi.read(SNAP_MAX_BYTES))
        try:    # 修剪：只留最近 SNAP_KEEP 份
            fs = sorted((os.path.join(SNAP_DIR, x) for x in os.listdir(SNAP_DIR)),
                        key=lambda p: os.path.getmtime(p))
            while len(fs) > SNAP_KEEP:
                os.remove(fs.pop(0))
        except Exception:
            pass
        metric("snapshots")
        log("写前快照 %s -> %s" % (path, dst))
        return dst
    except Exception as e:
        log("快照失败 %s: %r" % (path, e))
        return ""

# ---- 审计日志（哈希取证，不落明文参数） ----
_AUDIT_LOCK = threading.Lock()

def audit(tool, args, ok, note, t0):
    if not AUDIT_ON:
        return
    try:
        import hashlib as _hl
        if isinstance(args, dict):
            ah = _hl.sha256(json.dumps(args, ensure_ascii=False, sort_keys=True)
                            .encode("utf-8", "replace")).hexdigest()[:16]
        else:
            ah = "na"
        rec = {"ts": int(time.time()), "tool": (tool or "")[:80],
               "args_sha256": ah, "ok": bool(ok),
               "ms": int((time.time() - t0) * 1000)}
        if note:
            rec["note"] = str(note)[:160]
        line = json.dumps(rec, ensure_ascii=False)
        with _AUDIT_LOCK:
            os.makedirs(LOG_DIR, exist_ok=True)
            if os.path.exists(AUDIT_FILE) and os.path.getsize(AUDIT_FILE) > AUDIT_MAX:
                with open(AUDIT_FILE, "r", errors="ignore") as f:
                    tail = f.readlines()[-2000:]
                with open(AUDIT_FILE, "w", errors="ignore") as f:
                    f.writelines(tail)
            with open(AUDIT_FILE, "a", errors="ignore") as f:
                f.write(line + "\n")
    except Exception:
        pass

# ---- 指标 ----
METRICS = {"start": int(time.time()), "calls": 0, "blocked": 0,
           "denied": 0, "truncated": 0, "snapshots": 0, "by_tool": {}}
MET_LOCK = threading.Lock()

def metric(k, tool=None):
    try:
        with MET_LOCK:
            METRICS[k] = METRICS.get(k, 0) + 1
            if tool:
                bt = METRICS["by_tool"]
                bt[tool] = bt.get(tool, 0) + 1
    except Exception:
        pass

# ---- 敏感令牌脱敏 ----
def _all_tokens():
    ts = []
    SLIM_TOKEN, SCOPED_TOKENS = _tokens_hot()   # v1.3.3 热加载（脱敏也要认新令牌）
    if SLIM_TOKEN:
        ts.append(SLIM_TOKEN)
    if SCOPED_TOKENS:
        for k in ("root", "write", "readonly"):
            v = (SCOPED_TOKENS.get(k) or "").strip()
            if v:
                ts.append(v)
    return ts

def mask_secrets(p):
    for t in _all_tokens():
        if t and t in p:
            p = p.replace(t, "***T***")
    return p

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
TOOLOUT_DIR = os.path.join(LOG_DIR, "toolout")

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

# ---- 结构化截断（v1.3.0：文本提示保留 + _meta 结构化字段，兼容老客户端）----
_SLIM_TAIL_RE = re.compile(r"\n\[slim\] 输出 (\d+)B 超 (\d+)B 上限(?:，全文：(\S+))?$")

# ---- 261112 E1 统一出口脱敏（灵光）：四条返回路径统一过滤敏感面 ----
# 依据红方攻防经验E1：配置路径/环境变量名/重启方式/令牌片段 不外泄；
# 全文落盘路径保留（dump_toolout 先落盘后脱敏，原文可从审计与落盘取回）。
import re as _re
_SAN_PATS = [
    (_re.compile(r"/data/(?:lemonbrain|adb|local/tmp)[^\s，。）；】」\\'\"<>]*\.(?:json|conf|sh|ko|c|log|py|bin)"), "[配置路径]"),
    (_re.compile(r"\bLEMON_[A-Z_]+\s*=\s*\S+"), "[环境开关]"),
    (_re.compile(r"\bLEMON_[A-Z_]+\b(?!\s*=)"), "[环境变量]"),
    (_re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~-]{12,}"), "Bearer [令牌]"),
    (_re.compile(r"\b[A-Za-z0-9]{40,}\b"), "[令牌片段]"),
    (_re.compile(r"\breboot\b"), "[重启命令]"),
    (_re.compile(r"重启门面"), "[重启方式]"),
    (_re.compile(r"重启 MT 管理器的 MCP 服务"), "[重启方式]"),
]
def sanitize_out(s):
    if not isinstance(s, str):
        return s
    for _p, _r in _SAN_PATS:
        s = _p.sub(_r, s)
    return s

def sanitize_jsonrpc(obj):
    if isinstance(obj, dict):
        return {k: sanitize_jsonrpc(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [sanitize_jsonrpc(x) for x in obj]
    if isinstance(obj, str):
        return sanitize_out(obj)
    return obj

def clip_meta(s, n=None, san=True):
    """返回 (文本, meta或None)。meta = {"truncated","total_bytes","limit","full_path"}
    san=False：file_read/file_cat 内容保真（访问控制由 guard 负责，E1 不破坏文件数据）"""
    _so = sanitize_out if san else (lambda x: x)
    if n is None:
        n = MAX_BYTES
    if not isinstance(s, str):
        return s, None
    if n <= 0:
        return s, None
    if "[slim] 输出" in s:
        # 上游已分流落盘，透传防双层截断；gate64k: 解析尾巴重建结构化meta；E1: 出口脱敏
        s = _so(s)
        m = _SLIM_TAIL_RE.search(s)
        if m:
            body = s[:m.start()]
            return s, {"truncated": True, "total_bytes": int(m.group(1)),
                       "returned_bytes": len(body.encode("utf-8", "replace")),
                       "limit": int(m.group(2)), "full_path": m.group(3) or None,
                       "upstream": True}
        return s, None
    b = s.encode("utf-8", "replace")
    if len(b) <= n:
        return _so(s), None
    cut = b[:n]
    while cut and (cut[-1] & 0xC0) == 0x80:
        cut = cut[:-1]
    if cut and 0xC2 <= cut[-1] <= 0xF4:
        cut = cut[:-1]
    body = cut.decode("utf-8", "ignore")
    path = dump_toolout(s)
    tail = "\n[slim] 输出 %dB 超 %dB 上限" % (len(b), n)
    tail += ("，全文：" + path) if path else "（落盘失败）"
    metric("truncated")
    return _so(body + tail), {"truncated": True, "total_bytes": len(b),
                         "returned_bytes": len(body.encode("utf-8", "replace")),
                         "limit": n, "full_path": path or None}

def clip(s, n=None):
    return sanitize_out(clip_meta(s, n)[0])

# ---- file_read：分段读取（门面直读本地，绕开 4KB 限制的多轮痛点）----
def do_file_read(args, gate=None):
    """返回 (文本, meta或None)。按字节 offset/limit，UTF-8 安全截断。"""
    a = args if isinstance(args, dict) else {}
    if gate is None:
        gate, _ = effective_gate(a)
    path = str(a.get("path") or "")
    if not path:
        return "用法：file_read {path, offset?=0, limit?=门禁-128, max_bytes?=4096(最高65536)}", None
    try:
        offset = max(0, int(a.get("offset") or 0))
    except Exception:
        offset = 0
    try:
        limit = int(a.get("limit") or (gate - GATE_RESERVE))
    except Exception:
        limit = gate - GATE_RESERVE
    # 治 D4 教训：块 + 提示尾巴必须整体 ≤ 门禁，否则 hint 会被门禁切掉
    limit = max(1, min(gate - GATE_RESERVE, limit))
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(offset)
            b = f.read(limit)
    except Exception as e:
        return "读取失败 %s: %r" % (path, e), None
    chunk = b
    while chunk and (chunk[-1] & 0xC0) == 0x80:
        chunk = chunk[:-1]
    if chunk and 0xC2 <= chunk[-1] <= 0xF4:
        chunk = chunk[:-1]
    text = chunk.decode("utf-8", "replace")
    next_off = offset + len(chunk)
    done = next_off >= size
    meta = {"path": path, "size": size, "offset": offset,
            "bytes": len(chunk), "next_offset": (None if done else next_off),
            "eof": done}
    hint = "\n[file_read] %d/%dB" % (next_off, size)
    hint += "（已读完）" if done else "，下段 offset=%d" % next_off
    return text + hint, meta

# ---- 统一 tools/call 调度（POST 与 SSE 共用）：授权→护栏→快照→执行→审计 ----
# ---- v1.5.0 异步长任务接口（task_submit/status/result）----
import uuid
TASK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tasks")
TASK_MAX_RUNNING = 4
TASK_TTL = 86400
_task_lock = threading.Lock()

def _task_path(tid):
    return os.path.join(TASK_DIR, tid + ".json")

def _task_write(tid, data):
    os.makedirs(TASK_DIR, exist_ok=True)
    tmp = _task_path(tid) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, _task_path(tid))

def _task_read(tid):
    try:
        with open(_task_path(tid), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def _task_cleanup():
    now = time.time()
    try:
        for fn in os.listdir(TASK_DIR):
            if fn.endswith(".json"):
                p = os.path.join(TASK_DIR, fn)
                try:
                    if now - os.path.getmtime(p) > TASK_TTL:
                        os.remove(p)
                except OSError:
                    pass
    except OSError:
        pass

def _run_task(tid, tool, arguments, scope):
    try:
        res = dispatch_call(tool, arguments, scope)
        d = _task_read(tid) or {}
        d.update(state="done", finished=time.time(), result=res)
        _task_write(tid, d)
    except Exception as e:
        d = _task_read(tid) or {}
        d.update(state="failed", finished=time.time(), error=repr(e))
        _task_write(tid, d)

def do_task_submit(args, scope="root"):
    tool = args.get("tool") or ""
    arguments = args.get("arguments") or {}
    if not tool:
        return "用法：task_submit tool=工具名 arguments={...}"
    if tool == "task_submit":
        return "不允许嵌套提交任务"
    with _task_lock:
        _task_cleanup()
        running = 0
        try:
            for fn in os.listdir(TASK_DIR):
                if fn.endswith(".json"):
                    d = _task_read(fn[:-5])
                    if d and d.get("state") == "running":
                        running += 1
        except OSError:
            pass
        if running >= TASK_MAX_RUNNING:
            return "并发任务已达上限 %d，请稍后再提交" % TASK_MAX_RUNNING
        tid = "t%d-%s" % (int(time.time()), uuid.uuid4().hex[:8])
        _task_write(tid, {"state": "running", "tool": tool, "arguments": arguments,
                          "scope": scope, "started": time.time()})
    threading.Thread(target=_run_task, args=(tid, tool, arguments, scope), daemon=True).start()
    return json.dumps({"task_id": tid, "state": "running", "tool": tool}, ensure_ascii=False)

def do_task_status(args):
    tid = args.get("task_id") or ""
    d = _task_read(tid)
    if not d:
        return "未找到任务 %s" % tid
    now = time.time()
    info = {"task_id": tid, "state": d.get("state"), "tool": d.get("tool"),
            "elapsed_s": int(now - d.get("started", now))}
    if d.get("state") == "failed":
        info["error"] = d.get("error", "")
    return json.dumps(info, ensure_ascii=False)

def do_task_result(args, gate=None):
    tid = args.get("task_id") or ""
    d = _task_read(tid)
    if not d:
        return "未找到任务 %s" % tid
    st = d.get("state")
    if st == "running":
        return "任务仍在运行（%d秒），用 task_status 查询或稍后再取" % int(time.time() - d.get("started", time.time()))
    if st == "failed":
        return "任务失败：%s" % d.get("error", "")
    res = d.get("result") or {}
    texts = [c.get("text") or "" for c in (res.get("content") or [])
             if isinstance(c, dict) and c.get("type") == "text"]
    out = "\n".join(texts) if texts else json.dumps(res, ensure_ascii=False)
    g = gate or 4096
    if len(out.encode("utf-8", "ignore")) > g:
        out = out.encode("utf-8", "ignore")[:g].decode("utf-8", "ignore") + "\n[task_result 截断至 %d 字节，可用 max_bytes 提升]" % g
    return out

def dispatch_call(name, args, scope="root"):
    t0 = time.time()
    name = name or ""
    set_cur_tool(name)
    if not isinstance(args, dict):
        args = {}
    gate, gate_warn = effective_gate(args)   # gate64k: 默认4096不变，按需升64KB
    gate_explicit = "max_bytes" in args      # gate64k: 显式才翻译上游maxChars，老行为零改动
    _TL.scope = scope or "root"
    metric("calls", name)   # v1.3.0: 计数一切调用（含被拦/被拒），便于审计流量
    # 1) 分级授权
    need = required_scope(name)
    if not scope_ok(scope, need):
        msg = "[guard] 权限不足：%s 需要 %s 级令牌（当前 %s）" % (name, need, scope)
        audit(name, args, False, msg, t0)
        metric("denied")
        return {"content": [{"type": "text", "text": msg}], "isError": True}
    # 2) 危险操作护栏
    hit = guard_hit(name, args)
    if hit:
        # 261112红队复盘修复: 响应只回事件ID，规则名/放行方法仅落本地审计日志
        evt = "E%d%04x" % (int(time.time() * 1000) & 0xFFFFFFFF, (id(hit) ^ id(args)) & 0xFFFF)
        detail = ("[guard] 已拦截危险操作（%s）。确需执行：在 %s 放行，"
               "或以 LEMON_GUARD=0 重启门面") % (hit, GUARD_CONF)
        audit(name, args, False, detail + " evt=" + evt, t0)
        metric("blocked")
        return {"content": [{"type": "text", "text": "[guard] 策略拒绝（事件ID %s）" % evt}], "isError": True}
    # 3) 写前快照
    snap = ""
    if name.startswith("file_write") or name in ("dspp_write_file", "dspp_append_file"):
        snap = snapshot_before_write(args)
    # 4) 执行
    metas = []
    if gate_warn:
        metas.append({"gate": gate_warn})
    if name == "task_submit":
        out = do_task_submit(args, scope)
    elif name == "task_status":
        out = do_task_status(args)
    elif name == "task_result":
        out = do_task_result(args, gate)
    elif name == "tool_find":
        out = do_find(args.get("q", ""), args.get("limit", 20))
    elif name == "tool_get":
        out = do_get(args.get("id", ""))
    elif name == "tool_call":
        out = do_call(args.get("id", ""), args.get("arguments") or {},
                      gate if gate_explicit else None)
    elif name == "file_read":
        out, m = do_file_read(args, gate)
        if m:
            metas.append({"file_read": m})
    else:
        fwd_args = {k: v for k, v in args.items() if k != "max_bytes"}  # gate64k: 门面本地消费，不透传上游
        if gate_explicit:
            fwd_args["maxChars"] = gate   # gate64k: 翻译成C核心逐调用门禁覆盖
        try:
            resp = rpc("tools/call", {"name": name, "arguments": fwd_args}, timeout=120)
        except Exception as e:
            out = clip("转发失败 %s: %r" % (name, e))
            audit(name, args, False, "upstream-fail", t0)
            return {"content": [{"type": "text", "text": out}], "isError": True}
        res = resp.get("result") or {}
        for c in (res.get("content") or []):
            if isinstance(c, dict) and c.get("type") == "text":
                txt, m = clip_meta(c.get("text") or "", gate, san=(name != "file_cat"))
                c["text"] = txt
                if m:
                    if name == "file_cat":   # gate64k: 续读游标扣除shell包装头，防间隙
                        _k = txt.find("\n[exit=")
                        _k2 = txt.find("\n", _k + 1) if _k >= 0 else -1
                        _wlen = (_k2 + 1) if _k2 >= 0 else 0
                        m["next_offset"] = max(0, (m.get("returned_bytes") or 0) - _wlen)
                        m["eof"] = False
                    metas.append({"slim": m})
        result = res
        if snap:
            metas.append({"snapshot": snap})
        if metas:
            result.setdefault("_meta", {})["slim"] = {"events": metas}
        audit(name, args, True, "", t0)
        return result
    out, m = clip_meta(out, gate, san=(name != "file_read"))
    if m:
        metas.append({"slim": m})
    if snap:
        metas.append({"snapshot": snap})
    result = {"content": [{"type": "text", "text": out}], "isError": False}
    if metas:
        result["_meta"] = {"slim": {"events": metas}}
    audit(name, args, True, "", t0)
    return result


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


def mt_rpc(method, params, timeout=None):
    """直连 MT MCP（8787）。它无会话态（#203 实测直连兜底可用）。"""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or {}}).encode("utf-8")
    req = urllib.request.Request(MT_URL, data=body, headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=timeout or MT_TIMEOUT) as r:
        raw = r.read().decode("utf-8", "replace")
        ct = r.headers.get("Content-Type", "")
    if "text/event-stream" in ct:
        for ln in raw.splitlines():
            if not ln.startswith("data:"):
                continue
            return json.loads(ln[5:].strip())
        raise RuntimeError("MT SSE 应答无 data 行")
    return json.loads(raw)


def mt_alive_quick():
    return time.time() >= MT_DOWN_UNTIL


def build_mt_index(force=False):
    """拉取 MT 工具索引；失败回落内存→磁盘缓存；连续失败进熔断。绝不阻塞主索引。"""
    global MT_TOOLS, MT_BY_ID, MT_BY_NAME, MT_INDEX_TS, MT_DOWN_UNTIL, MT_LAST_ERR
    if not MT_URL:
        return False
    with MT_LOCK:
        if MT_TOOLS and not force and (time.time() - MT_INDEX_TS) < 300:
            return True
        tools = None
        if mt_alive_quick() or not MT_TOOLS:
            try:
                resp = mt_rpc("tools/list", {}, timeout=MT_TIMEOUT)
                tools = (resp.get("result") or {}).get("tools") or []
                MT_LAST_ERR = ""
            except Exception as e:
                MT_LAST_ERR = repr(e)
                log(f"MT 索引拉取失败: {e!r}")
                if not MT_TOOLS:
                    MT_DOWN_UNTIL = time.time() + MT_BREAK_S
        if not tools and not MT_TOOLS:
            cache = os.path.join(IDX_DIR, "mt_tools_cache.json")
            if os.path.exists(cache):
                try:
                    with open(cache, "r", encoding="utf-8") as f:
                        tools = json.load(f)
                except Exception as e:
                    log(f"MT 缓存读取失败: {e!r}")
                else:
                    log("MT 使用磁盘缓存 tools=%d" % len(tools))
        if tools:
            seq = 0
            out = []
            for t in tools:
                if not (isinstance(t, dict) and t.get("name")):
                    continue
                seq += 1
                out.append({"id": "T-%04d" % (5000 + seq), "name": t["name"],
                            "desc": (t.get("description") or "")[:400],
                            "schema": t.get("inputSchema") or
                                      {"type": "object", "properties": {}},
                            "dom": "D0", "domname": "MT管理器", "src": "mt"})
            MT_TOOLS = out
            MT_BY_ID = {x["id"]: x for x in out}
            MT_BY_NAME = {x["name"]: x for x in out}
            MT_INDEX_TS = time.time()
            try:
                os.makedirs(IDX_DIR, exist_ok=True)
                cache = os.path.join(IDX_DIR, "mt_tools_cache.json")
                tmp = cache + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump([{"name": x["name"], "description": x["desc"],
                                "inputSchema": x["schema"]} for x in out], f,
                              ensure_ascii=False)
                os.replace(tmp, cache)
            except Exception as e:
                log(f"MT 缓存写入失败: {e!r}")
        return bool(MT_TOOLS)



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

    build_mt_index()
    pool = TOOLS + MT_TOOLS
    hits = [x for x in pool if all(k.lower() in hay(x) for k in kws)]
    mode = "AND"
    if not hits:
        hits = [x for x in pool if any(k.lower() in hay(x) for k in kws)]
        mode = "OR降级"
    if not hits:
        return "未找到匹配 [%s] 的工具（共 %d 个）" % (q, len(pool))
    lines = ["找到 %d 个（%s，显示前 %d）：" % (len(hits), mode, min(limit, len(hits)))]
    for x in hits[:limit]:
        tag = "[MT] " if x.get("src") == "mt" else ""
        lines.append("%s  %s%-28s %s" % (x["id"], tag, x["name"], x["desc"].replace("\n", " ")[:80]))
    if len(hits) > limit:
        lines.append("... 还有 %d 个，缩小关键词或调大 limit" % (len(hits) - limit))
    lines.append("→ tool_get <编号>；tool_call <编号> {参数}")
    return clip("\n".join(lines))

def do_get(tid):
    if not build_index():
        return "索引不可用"
    build_mt_index()
    x = (BY_ID.get((tid or "").strip()) or MT_BY_ID.get((tid or "").strip())
         or BY_NAME.get((tid or "").strip()) or MT_BY_NAME.get((tid or "").strip()))
    if not x:
        return "未找到：%s（用 tool_find 先搜）" % tid
    return clip(json.dumps({"id": x["id"], "name": x["name"],
                            "domain": x["dom"] + "-" + x["domname"],
                            "source": "MT管理器(8787)" if x.get("src") == "mt" else "lemoncore(8788)",
                            "description": x["desc"], "inputSchema": x["schema"]},
                           ensure_ascii=False, indent=2))

def do_meta_stats(args):
    """261113修复: 门面本地调用统计。核心侧计数器不认门面转发流量(恒0)，
    以门面 METRICS 为准（自门面启动起，含被拦/被拒）；MT镜像同名工具一并接管。"""
    try:
        top = int((args or {}).get("top") or 15)
    except Exception:
        top = 15
    top = max(1, min(100, top))
    with MET_LOCK:
        total = METRICS.get("calls", 0)
        tcalls = METRICS.get("t_calls", 0)
        bt = dict(METRICS.get("by_tool") or {})
        blocked = METRICS.get("blocked", 0)
        denied = METRICS.get("denied", 0)
        trunc = METRICS.get("truncated", 0)
        up = int(time.time()) - METRICS.get("start", int(time.time()))
    lines = ["total_calls=%d (门面入口,自启动起)" % total,
             "t_calls=%d (经tool_call执行的T工具次数)" % tcalls,
             "called_tools=%d/%d" % (len(bt), len(TOOLS) + len(MT_TOOLS or [])),
             "blocked=%d denied=%d truncated=%d uptime_s=%d" % (blocked, denied, trunc, up),
             "热门(门面入口与T工具混合计数):"]
    for nm, c in sorted(bt.items(), key=lambda kv: -kv[1])[:top]:
        lines.append("%6d  %s" % (c, nm))
    return "\n".join(lines)


def do_call(tid, args, gate=None):
    global MT_DOWN_UNTIL, MT_LAST_ERR
    if not build_index():
        return "索引不可用"
    build_mt_index()
    x = (BY_ID.get((tid or "").strip()) or MT_BY_ID.get((tid or "").strip())
         or BY_NAME.get((tid or "").strip()) or MT_BY_NAME.get((tid or "").strip()))
    if not x:
        return "未找到：%s（用 tool_find 先搜）" % tid
    if not isinstance(args, dict):
        args = {}
    if gate is not None and x.get("src") != "mt":
        args = dict(args)
        args["maxChars"] = gate   # gate64k: C核心逐调用门禁覆盖（0=全量仅内部用，此处恒≥4096）
    if x["name"] in FACADE:
        return "门面工具请直接调用，不要经 tool_call 转发"
    # 261113修复: 核心侧 meta_stats 不统计门面转发流量(恒0)，改用门面本地 METRICS
    if x["name"] == "meta_stats":
        return do_meta_stats(args)
    # v1.3.0：tool_call 目标工具同样过分级授权与危险护栏
    _cur_scope = getattr(_TL, "scope", "root")
    _need = required_scope(x["name"])
    if not scope_ok(_cur_scope, _need):
        return "[guard] 权限不足：%s 需要 %s 级令牌（当前 %s）" % (x["name"], _need, _cur_scope)
    _hit = guard_hit(x["name"], args)
    if _hit:
        # 261112红队复盘修复: 不回显规则名，仅事件ID
        _evt = "E%d%04x" % (int(time.time() * 1000) & 0xFFFFFFFF, (id(_hit) ^ id(args)) & 0xFFFF)
        return "[guard] 策略拒绝（事件ID %s）" % _evt
    metric("t_calls", x["name"])  # 261113: T工具执行计数(供热榜)
    if x.get("src") == "mt":
        if not mt_alive_quick():
            return "[MT熔断] MT MCP(8787) 疑似假死，熔断中（%.0fs 后自动试通）。最近错误：%s" % (
                max(0, MT_DOWN_UNTIL - time.time()), MT_LAST_ERR or "未知")
        try:
            resp = mt_rpc("tools/call", {"name": x["name"], "arguments": args},
                          timeout=MT_TIMEOUT)
            MT_LAST_ERR = ""
        except Exception as e:
            MT_DOWN_UNTIL = time.time() + MT_BREAK_S
            MT_LAST_ERR = repr(e)
            return "[MT熔断] 调用 %s 超时/失败：%r。MT MCP(8787) 疑似假死，已熔断 %.0fs（可重启 MT 管理器的 MCP 服务）" % (
                x["name"], e, MT_BREAK_S)
    else:
        try:
            resp = rpc("tools/call", {"name": x["name"], "arguments": args}, timeout=120)
        except Exception as e:
            return "调用失败 %s: %r" % (x["name"], e)
    res = resp.get("result") or {}
    if resp.get("error"):
        return "上游错误: " + json.dumps(resp["error"], ensure_ascii=False)
    texts = []
    for c in (res.get("content") or []):
        if isinstance(c, dict) and c.get("type") == "text":
            texts.append(c.get("text") or "")
    body = "\n".join(texts) if texts else json.dumps(res, ensure_ascii=False)
    return body   # gate64k: 外层统一 clip_meta 上门禁并出结构化meta（修复内层clip吞meta）

def slim_tools_list():
    defs = []
    try:
        resp = rpc("tools/list", {})
        alltools = (resp.get("result") or {}).get("tools") or []
        m = {t.get("name"): t for t in alltools if isinstance(t, dict)}
        for nm in HOT:
            if nm in m:
                t = m[nm]
                if nm == "file_cat":   # gate64k: max_bytes 门面本地消费，注入schema
                    t = json.loads(json.dumps(t))
                    props = t.setdefault("inputSchema", {}).setdefault("properties", {})
                    props["max_bytes"] = {"type": "integer",
                        "description": "单次输出门禁字节数，默认4096，最高65536（超过自动钳制）；不传=老行为"}
                    t["description"] = (t.get("description") or "") + " 可带 max_bytes 提升单次输出门禁(默认4096,最高65536)；截断时 _meta 带 next_offset 供 file_read 续读。"
                defs.append(t)
    except Exception as e:
        log("热档定义拉取失败: %r" % (e,))
    defs.extend(FACADE_DEFS)
    return defs



# ================= v1.3.6 五域 resources 接入 =================
def _res_safe(fn, *a, **kw):
    """旁路函数（log/audit/metric）签名不符或异常时静默，绝不让 resources 接口炸掉。"""
    try:
        return fn(*a, **kw)
    except Exception:
        return None


def _res_err(rid, code, msg):
    return {"jsonrpc": "2.0", "id": rid,
            "error": {"code": code, "message": _res_safe(sanitize_out, msg) or msg}}


def _res_snapshot(path, max_bytes):
    """删除前强制快照；失败返回空串，由 do_remove 硬中止（不覆盖 v135 原有快照逻辑）。"""
    try:
        os.makedirs(SNAP_DIR, exist_ok=True)
        import random as _r
        base = re.sub(r"[^0-9A-Za-z_.-]", "_", os.path.basename(path))[:60] or "noname"
        dst = os.path.join(SNAP_DIR, "%s-del-p%d-%06x-%s" % (
            time.strftime("%Y%m%d-%H%M%S"), os.getpid(), _r.getrandbits(24), base))
        with open(path, "rb") as fi, open(dst, "wb") as fo:
            fo.write(fi.read(int(max_bytes)))
        _res_safe(log, "res 删除前快照 %s -> %s" % (path, dst))
        return dst
    except Exception as e:
        _res_safe(log, "res 快照失败 %s: %r" % (path, e))
        return ""


def dispatch_res(method, params, scope, rid):
    """resources/* 统一入口：熔断 → 授权 → 执行 → 审计。返回 JSON-RPC dict。"""
    t0 = time.time()
    params = params if isinstance(params, dict) else {}
    if not RES_ON:
        return _res_err(rid, -32002, "resources 模块未加载，接口不可用")
    # 1) 熔断：LOCKDOWN 存在时写/删/恢复一律拒绝（比现网"降级只读"更严）
    if _LR.lockdown_denies(method, os.path.exists(LOCKDOWN_FILE)):
        _res_safe(metric, "denied", "res_" + method)
        _res_safe(audit, method, params, False, "[res] LOCKDOWN 熔断拒绝写入/删除", t0)
        return _res_err(rid, -32003, "LOCKDOWN 熔断生效中，该操作被拒绝")
    # 2) 授权：删除的 root 门槛在模块内查表判定，不依赖 required_scope 关键词启发式
    if not _LR.check_scope(method, scope or "root"):
        need = _LR.METHOD_SCOPE.get(method)
        _res_safe(metric, "denied", "res_" + method)
        _res_safe(audit, method, params, False,
                  "[res] 权限不足：%s 需 %s，当前 %s" % (method, need, scope), t0)
        return _res_err(rid, -32003, "权限不足：%s 需要 %s 级令牌" % (method, need))
    uri = params.get("uri") or ""
    cfg = _LR.DEFAULT_CFG
    try:
        if method == "resources/list":
            gate, _w = effective_gate({"max_bytes": params.get("max_bytes")}
                                      if params.get("max_bytes") else {})
            out = _LR.list_resources(uri, cfg,
                                     limit=int(params.get("limit") or 200),
                                     cursor=int(params.get("cursor") or 0),
                                     gate=gate,
                                     no_cache=bool(params.get("no_cache")))
            _res_safe(metric, "calls", "resources_list")
            _res_safe(audit, method, {"uri": uri}, True,
                      "entries=%d cursor=%s" % (len(out["entries"]), out["next_cursor"]), t0)
            # v1.3.7：输出规范形状 result.resources[]（此前是 tools 风格 content[]）
            return {"jsonrpc": "2.0", "id": rid, "result": _LR.spec_list_result(out)}
        if method == "resources/read":
            ref = _LR.resolve_file(uri, cfg)   # 目录/域根在解析层即拒（-32602），不给假成功
            args = {"path": ref["path"]}
            if params.get("max_bytes"):
                args["max_bytes"] = params["max_bytes"]
            if params.get("offset") is not None:
                args["offset"] = params["offset"]
            _res_safe(metric, "calls", "resources_read")
            inner = dispatch_call("file_read", args, scope) or {}
            # v1.3.7：内层失败必须回真 error，而不是 isError 包在成功信封里
            if inner.get("isError"):
                txt = ""
                for _it in (inner.get("content") or []):
                    if _it.get("type") == "text":
                        txt = _it.get("text") or ""
                        break
                return _res_err(rid, -32001, ("读取失败：%s" % (txt or "未知原因"))[:400])
            parts = [i.get("text") or "" for i in (inner.get("content") or [])
                     if i.get("type") == "text"]
            return {"jsonrpc": "2.0", "id": rid, "result": _LR.spec_read_result(
                uri, "\n".join(parts), ref.get("domain"), ref["path"],
                inner.get("_meta") or {})}
        if method == "resources/write":
            tool, args = _LR.write_plan(uri, cfg,
                                        text=params.get("text") or params.get("content") or "",
                                        append=bool(params.get("append")))
            _res_safe(metric, "calls", "resources_write")
            return {"jsonrpc": "2.0", "id": rid, "result": dispatch_call(tool, args, scope)}
        if method == "resources/remove":
            out = _LR.do_remove(uri, cfg, confirm=params.get("confirm") or "",
                                snapshot_fn=_res_snapshot, scope=scope)
            _res_safe(metric, "calls", "resources_remove")
            _res_safe(audit, method, {"uri": uri}, True,
                      "trash=%s evt=%s" % (out["trash"], out["event_id"]), t0)
            return {"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text",
                             "text": json.dumps(out, ensure_ascii=False)}],
                "isError": False}}
        if method == "resources_restore":
            out = _LR.do_restore(params.get("from_trash") or "", cfg)
            _res_safe(metric, "calls", "resources_restore")
            _res_safe(audit, method, params, True, "restored=%s" % out["path"], t0)
            return {"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text",
                             "text": json.dumps(out, ensure_ascii=False)}],
                "isError": False}}
        return _res_err(rid, -32601, "未知 resources 方法：%s" % method)
    except _LR.ResError as e:
        _res_safe(metric, "denied", "res_" + method)
        _res_safe(audit, method, {"uri": uri}, False, "[res] %s" % e.message, t0)
        return _res_err(rid, e.code, e.message)
    except Exception as e:
        _res_safe(log, "res 内部异常 %s: %r" % (method, e))
        _res_safe(audit, method, {"uri": uri}, False, "[res] 内部异常 %r" % (e,), t0)
        return _res_err(rid, -32603, "resources 内部错误")


def sse_handle_rpc(req, scope="root"):
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
            "capabilities": {"tools": {}, "resources": {}},
            "serverInfo": {"name": "小柠檬内核·slim门面", "version": VERSION}}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": slim_tools_list()}}
    if method == "tools/call":
        # v1.3.0：统一走 dispatch_call（授权/护栏/快照/审计/结构化截断）
        t0 = time.time()
        result = dispatch_call(params.get("name"), params.get("arguments") or {}, scope)
        log("SSE %s %.0fms" % (params.get("name"), (time.time() - t0) * 1000))
        return {"jsonrpc": "2.0", "id": rid, "result": result}
    if RES_ON and method in _LR.RES_METHODS:
        return dispatch_res(method, params, scope, rid)
    if method in ("ping", "notifications/initialized", "notifications/cancelled"):
        if rid is None:
            return None
        return {"jsonrpc": "2.0", "id": rid, "result": {}}
    try:
        return sanitize_jsonrpc(rpc(method, params, timeout=60))
    except Exception as e:
        return {"jsonrpc": "2.0", "id": rid,
                "error": {"code": -32603, "message": sanitize_out("上游不可用: %r" % (e,))}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LemonSlim/" + VERSION

    def log_message(self, fmt, *args):
        # REQ_LOG + SAFETY_V13: 记录入站请求，token 脱敏不落盘（v1.3.0 全令牌脱敏）
        try:
            p = mask_secrets(self.path)
            # REQ_PORT: 带监听端口，区分本机(8791)与公网(8792)请求
            try:
                _port = self.connection.getsockname()[1]
            except Exception:
                _port = 0
            log("REQ %s %s %s" % (_port, self.command, p))
        except Exception:
            pass

    def _auth_scope(self):
        # 8791 本机口：恒 root（仅绑 127.0.0.1，外部不可达；公网走 8792+HandlerPub 强制Token）
        # 铁律：LEMON_SLIM_HOST 必须保持 127.0.0.1
        self._scope = "root"
        return "root"

    def _auth_ok(self):
        self._scope = "root"
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
        _scope = getattr(self, "_scope", "root") or "root"
        with SSE_LOCK:
            SSE_SESSIONS[sid] = (q, _scope)   # v1.3.0: 会话绑定 scope
        log("SSE 会话建立 %s scope=%s" % (sid, _scope))
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
            _ent = SSE_SESSIONS.get(sid)
        if _ent is None:
            self._send({"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32001, "message": "session not found: %s" % sid}}, 404)
            return
        q, _msg_scope = _ent
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
        resp = sse_handle_rpc(req, _msg_scope)
        if resp is not None:
            q.put(json.dumps(resp, ensure_ascii=False))
        self.send_response(202)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _deny(self):
        # SAFETY_V13: 伪装404，不向探测者暴露"这里有鉴权服务"
        p = mask_secrets(self.path)
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
        # v1.3.0: /metrics 仅本机口（8791），公网口拒绝
        _p2 = (self.path or "").split("?", 1)[0]
        _segs2 = [s for s in _p2.strip("/").split("/") if s]
        if "metrics" in _segs2:
            try:
                _lp = self.connection.getsockname()[1]
            except Exception:
                _lp = 0
            if _lp != LISTEN_PORT:
                self._deny()
                return
            with MET_LOCK:
                m = dict(METRICS)
                m["by_tool"] = dict(METRICS["by_tool"])
            m["uptime_s"] = int(time.time()) - m.pop("start", int(time.time()))
            m["version"] = VERSION
            self._send(m)
            return
        self._send({"ok": True, "server": "小柠檬内核·slim门面", "version": VERSION,
                    "upstream": UPSTREAM,
                    "tools_exposed": len(slim_tools_list()),
                    "indexed": len(TOOLS),
                    "guard": GUARD_ON, "snapshot": SNAP_ON,
                    "scoped_tokens": bool(_tokens_hot()[1]),
                    "lockdown": os.path.exists(LOCKDOWN_FILE), "auth": "bearer-only",
                    "mt": {"enabled": bool(MT_URL), "tools": len(MT_TOOLS),
                           "index_age_s": int(time.time() - MT_INDEX_TS) if MT_INDEX_TS else None,
                           "circuit_open": not mt_alive_quick(),
                           "last_err": MT_LAST_ERR or None}})

    def do_POST(self):
        # SSE_ROUTE_V2: /messages、/<token>/messages、/messages/<token> 全识别
        _p = (self.path or "").split("?", 1)[0]
        _segs = [s for s in _p.strip("/").split("/") if s]
        # [261112 攻防加固] POST 路径白名单: 仅根/mcp/messages 通道,其余伪装404(堵路径面探测)
        if _segs and _segs[0] not in ("mcp", "messages"):
            self._deny()
            return
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
                    "capabilities": {"tools": {}, "resources": {}},
                    "serverInfo": {"name": "小柠檬内核·slim门面", "version": VERSION}}})
                return
            if method == "tools/list":
                self._send({"jsonrpc": "2.0", "id": rid,
                            "result": {"tools": slim_tools_list()}})
                return
            if method == "tools/call":
                # v1.3.0：统一走 dispatch_call（授权/护栏/快照/审计/结构化截断）
                _scope = getattr(self, "_scope", "root") or "root"
                result = dispatch_call(params.get("name"), params.get("arguments") or {}, _scope)
                self._send({"jsonrpc": "2.0", "id": rid, "result": result})
                log("%s %.0fms" % (params.get("name"), (time.time() - t0) * 1000))
                return
            if RES_ON and method in _LR.RES_METHODS:
                _scope = getattr(self, "_scope", "root") or "root"
                self._send(dispatch_res(method, params, _scope, rid))
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
                self._send(sanitize_jsonrpc(rpc(method, params, timeout=60)))
            except Exception as e:
                self._send({"jsonrpc": "2.0", "id": rid,
                            "error": {"code": -32603, "message": sanitize_out("上游不可用: %r" % (e,))}})
        except Exception as e:
            log("处理异常 %s: %r" % (method, e))
            try:
                self._send({"jsonrpc": "2.0", "id": rid,
                            "error": {"code": -32603, "message": sanitize_out("%r" % (e,))}})
            except Exception:
                pass


class HandlerPub(Handler):
    """8792 公网口专用：强制 Token（Bearer头/路径密钥/query ?token=）
    SAFETY_V13: ①连续失败熔断(有效Token随时可解除) ②/messages 的 sessionId 等效鉴权
    v1.3.0: 分级令牌——.tokens.json 存在时按 readonly/write/root 定级；
            不存在时旧 .token 恒 root（完全兼容现有 takin 链接）"""
    def _token_scope(self, tok):
        tok = (tok or "").strip()
        if not tok:
            return None
        SLIM_TOKEN, SCOPED_TOKENS = _tokens_hot()   # v1.3.3 热加载
        if SCOPED_TOKENS:
            rev = SCOPED_TOKENS.get("revoked") or []
            if isinstance(rev, list) and any(hmac.compare_digest(tok, rv) for rv in [str(x).strip() for x in rev] if rv):
                with FAIL_LOCK:   # 吊销令牌重试 = 攻击信号，计入熔断
                    FAIL_COUNT["n"] = FAIL_COUNT.get("n", 0) + 1
                    if FAIL_COUNT["n"] >= FAIL_LIMIT:
                        FAIL_COUNT["until"] = time.time() + BAN_SECONDS
                log("吊销令牌尝试访问，已计入熔断计数")
                return None
            for sc in ("root", "write", "readonly"):
                if hmac.compare_digest(tok, (SCOPED_TOKENS.get(sc) or "").strip()):
                    return sc
            if SLIM_TOKEN and hmac.compare_digest(tok, SLIM_TOKEN):
                return "root"      # 旧主令牌恒 root（兼容）
            return None
        if SLIM_TOKEN and hmac.compare_digest(tok, SLIM_TOKEN):
            return "root"
        return None

    def _auth_scope(self):
        self._scope = None
        SLIM_TOKEN, SCOPED_TOKENS = _tokens_hot()   # v1.3.3 热加载
        if not SLIM_TOKEN and not SCOPED_TOKENS:
            return None
        with FAIL_LOCK:
            cooling = time.time() < FAIL_COUNT.get("until", 0)
        scope = None
        # v1.3.3 安全加固：Bearer-only。路径段/查询串不再携带令牌——
        # URL 会进隧道服务端/CDN/浏览器历史等日志，令牌放 URL = 半公开泄露
        h = (self.headers.get("Authorization") or "").strip()
        if h.startswith("Bearer "):
            scope = self._token_scope(h[7:].strip())
        if scope is None and "/messages" in (self.path or ""):
            # SAFETY_V13: sessionId 在会话表内 = SSE 流建立时已过鉴权
            try:
                import urllib.parse as _up
                sid = (_up.parse_qs((self.path).split("?", 1)[1]).get("sessionId") or [""])[0]
                with SSE_LOCK:
                    _ent = SSE_SESSIONS.get(sid)
                if _ent:
                    scope = _ent[1]
            except Exception:
                pass
        with FAIL_LOCK:
            if scope:
                # 有效请求到达即清零并解除熔断（合法用户随时能进来）
                FAIL_COUNT["n"] = 0
                FAIL_COUNT["until"] = 0
            elif not cooling:
                # 261114 lemon-user拍板 四档阶梯: 错1次封10分钟 → 连错5次封30分钟 → 连错3次封128分钟 → 之后每错一次随机封24~360小时
                _tier = min(FAIL_COUNT.get("bans", 0), 3)
                _th, _sec = ((1, 600), (5, BAN_SECONDS), (3, 7680), (1, 0))[_tier]
                if _tier == 3:
                    _sec = random.randint(86400, 12960000)
                FAIL_COUNT["n"] = FAIL_COUNT.get("n", 0) + 1
                if FAIL_COUNT["n"] >= _th:
                    FAIL_COUNT["n"] = 0
                    FAIL_COUNT["until"] = time.time() + _sec
                    FAIL_COUNT["bans"] = min(FAIL_COUNT.get("bans", 0) + 1, 3)
                    log("SAFETY封禁第%d档: 连错%d次, 封%d秒%s(有效Token可解除)" % (_tier + 1, _th, _sec, "(随机24~360小时)" if _tier == 3 else ""))
        # v1.3.2 LOCKDOWN：文件存在 → 公网口任何令牌一律降级只读
        if scope and os.path.exists(LOCKDOWN_FILE):
            if scope != "readonly":
                log("LOCKDOWN 生效：%s 级令牌降级为 readonly" % scope)
            scope = "readonly"
        if scope:
            self._scope = scope
        return scope

    def _auth_ok(self):
        return self._auth_scope() is not None


def main():
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(IDX_DIR, exist_ok=True)
    log("=== slim_proxy v%s 启动 port=%d upstream=%s pid=%d guard=%s snapshot=%s scoped=%s ===" %
        (VERSION, LISTEN_PORT, UPSTREAM, os.getpid(), GUARD_ON, SNAP_ON, bool(SCOPED_TOKENS)))
    try:
        build_index()
    except Exception as e:
        log("预热失败: %r" % (e,))
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    srv.daemon_threads = True
    if SLIM_TOKEN or SCOPED_TOKENS:   # [261112] 分级令牌模式也开公网口(防裸奔逻辑保留:两类令牌都无=不监听)
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