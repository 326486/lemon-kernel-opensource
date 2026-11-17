#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lemon_res.py —— 小柠檬五域 resources 接口核心模块（slim 门面 v136）

设计依据：plans/2026-11-13-五域resources接口-design.md
特性：纯标准库、无第三方依赖；URI 解析 / 目录列举 / 编号池解析 / 权限查表 /
      保护名单 / 强制快照删除 / 回收站恢复 / 游标分页 / 输出门禁预算。
接入方式：slim_proxy_v136.py 在方法分发处调本模块，本模块异常不影响老链路。
"""

import json
import os
import random
import re
import shutil
import threading
import time

try:                                    # py3
    from urllib.parse import unquote
except ImportError:                     # pragma: no cover
    from urlparse import unquote        # pragma: no cover

NUM_RE = re.compile(r"^([LZC]-[0-9A-Za-z._-]{1,12})$")
RES_METHODS = ["resources/list", "resources/read", "resources/write",
               "resources/remove", "resources_restore"]

# 坑 1 的正解：删除的 root 门槛在模块内查表自判，不依赖现网
# required_scope() 的关键词启发式（其列表里没有 remove，会被降级成 write）
METHOD_SCOPE = {
    "resources/list": "readonly",
    "resources/read": "readonly",
    "resources/write": "write",
    "resources/remove": "root",
    "resources_restore": "write",
}
SCOPE_RANK = {"none": 0, "readonly": 1, "write": 2, "root": 3}
# LOCKDOWN 熔断时，除只读外一律拒绝（比现网"降级只读"更严）
WRITE_METHODS = {"resources/write", "resources/remove", "resources_restore"}

LISTABLE_KINDS = ("domain", "dir", "num_root", "trash")


class ResError(Exception):
    """code: -32602 参数非法 / -32000 越界或穿越 / -32001 不可用 / -32003 保护名单"""

    def __init__(self, code, message):
        Exception.__init__(self, message)
        self.code = code
        self.message = message


class Pool(object):
    __slots__ = ("index", "path_col", "root", "has_header", "domain")

    def __init__(self, index, path_col, root, has_header=False, domain=None):
        self.index = index
        self.path_col = path_col        # 1-based；<=0 表示列序未实测，拒绝解析
        self.root = root
        self.has_header = has_header
        self.domain = domain


class Cfg(object):
    __slots__ = ("domains", "pools", "protected", "trash_dir", "snap_dir",
                 "snap_max_bytes", "hidden_prefix")

    def __init__(self, domains, pools, protected, trash_dir, snap_dir,
                 snap_max_bytes=64 * 1024 * 1024, hidden_prefix=("_", ".")):
        self.domains = domains
        self.pools = pools
        self.protected = [os.path.realpath(p) for p in protected]
        self.trash_dir = trash_dir
        self.snap_dir = snap_dir
        self.snap_max_bytes = snap_max_bytes
        self.hidden_prefix = hidden_prefix


# ---------------- 索引缓存（仅缓存编号索引，mtime 变化即失效） ----------------
_INDEX_CACHE = {}
_INDEX_LOCK = threading.Lock()


def _read_pool(pool, no_cache=False):
    """返回 [(编号, 名称, 绝对路径)]；列数不足的行跳过而不整体失败。
    索引缺失或列序未实测 → 抛 -32001，由调用方决定降级(list)或报错(resolve)。"""
    if not pool.index:
        raise ResError(-32001, "编号池未配置索引文件")
    if pool.path_col <= 0:
        raise ResError(-32001, "编号池 %s 未接入（索引列序未实测，拒绝猜测）" % pool.index)
    try:
        mtime = os.stat(pool.index).st_mtime_ns
    except OSError:
        raise ResError(-32001, "编号索引不存在：%s" % pool.index)
    key = pool.index
    with _INDEX_LOCK:
        if not no_cache:
            hit = _INDEX_CACHE.get(key)
            if hit and hit[0] == mtime:
                return hit[1]
    rows = []
    with open(pool.index, "r", encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            line = line.rstrip("\n").rstrip("\r")
            if not line.strip():
                continue
            if pool.has_header and i == 0:
                continue
            cols = line.split("\t")
            if len(cols) < pool.path_col:
                continue
            num, name = cols[0].strip(), (cols[1].strip() if len(cols) > 1 else "")
            raw = cols[pool.path_col - 1].strip()
            if not NUM_RE.match(num) or not raw:
                continue
            path = raw if raw.startswith("/") else os.path.join(pool.root, raw)
            rows.append((num, name or num, os.path.normpath(path)))
    rows.sort(key=lambda x: x[0])
    with _INDEX_LOCK:
        _INDEX_CACHE[key] = (mtime, rows)
    return rows


def _find_num(num, cfg, no_cache=False):
    broken = []
    for pfx in ("L", "Z", "C"):
        pool = cfg.pools.get(pfx)
        if not pool:
            continue
        try:
            rows = _read_pool(pool, no_cache)
        except ResError:
            broken.append(pfx)      # 某池不可用不影响其他池查号
            continue
        for n, name, path in rows:
            if n == num:
                return pfx, pool, name, path
    msg = "编号未登记：%s" % num
    if broken:
        msg += "（编号池 %s 索引不可用，未能核对）" % "/".join(broken)
    raise ResError(-32001, msg)


# ---------------- 路径安全 ----------------
def protected_hit(path, cfg):
    p = os.path.realpath(path)
    for pre in cfg.protected:
        if p == pre or p.startswith(pre + os.sep):
            return pre
    return ""


def _guard_inside(root, target, what):
    r_root = os.path.realpath(root)
    r_tgt = os.path.realpath(target)
    if r_tgt != r_root and not r_tgt.startswith(r_root + os.sep):
        raise ResError(-32000, "%s 越出边界：%s" % (what, target))
    return r_tgt


def _clean_seg(seg, uri):
    if "\x00" in seg:
        raise ResError(-32602, "URI 含 NUL：%s" % uri)
    for ch in seg:
        if ord(ch) < 0x20 or ord(ch) == 0x7f:
            raise ResError(-32602, "URI 含控制字符：%s" % uri)
    if "/" in seg or "\\" in seg:
        raise ResError(-32000, "URI 段解码后含路径分隔符（疑似注入）：%s" % uri)
    if seg == "..":
        raise ResError(-32000, "URI 含上级穿越：%s" % uri)
    if seg == ".":
        raise ResError(-32000, "URI 含当前目录段：%s" % uri)


def resolve(uri, cfg, must_exist=True):
    """lemon:// URI → {kind, path, uri, domain, pool}；含 canonical 与符号链接校验。"""
    if not isinstance(uri, str) or not uri.startswith("lemon://"):
        raise ResError(-32602, "URI 必须以 lemon:// 开头")
    rest_all = uri[len("lemon://"):]
    if not rest_all:
        raise ResError(-32602, "URI 缺少域")
    host, slash, tail = rest_all.partition("/")
    host = unquote(host)
    if host == "num":
        if not slash:
            return {"kind": "num_root", "path": "", "uri": "lemon://num", "domain": None}
        num = unquote(tail)
        if not NUM_RE.match(num):
            raise ResError(-32602, "编号格式非法：%s" % num)
        pfx, pool, name, path = _find_num(num, cfg)
        if must_exist and not os.path.exists(path):
            raise ResError(-32001, "编号目标文件不存在：%s -> %s" % (num, path))
        _guard_inside(pool.root, path, "编号 %s" % num)
        return {"kind": "num", "path": os.path.realpath(path), "uri": uri,
                "domain": pool.domain, "pool": pfx, "num": num, "name": name}
    if host == "trash":
        base = cfg.trash_dir
        if not tail or tail in ("", "/"):
            return {"kind": "trash", "path": base, "uri": "lemon://trash", "domain": None}
        segs = [s for s in tail.split("/") if s != ""]
        if len(segs) != 1:
            raise ResError(-32602, "回收站 URI 只允许一层")
        _clean_seg(unquote(segs[0]), uri)
        pkg = os.path.join(base, unquote(segs[0]))
        _guard_inside(base, pkg, "回收站条目")
        if must_exist and not os.path.isdir(pkg):
            raise ResError(-32001, "回收站条目不存在：%s" % segs[0])
        return {"kind": "trash_pkg", "path": pkg, "uri": uri, "domain": None}
    if host not in cfg.domains:
        raise ResError(-32602, "未知域：%s（可用 mem/repo/learn/mcp/kern）" % host)
    root = cfg.domains[host]
    if not os.path.isdir(root):
        raise ResError(-32001, "域不可用（目录不存在）：%s -> %s" % (host, root))
    r_root = os.path.realpath(root)
    segs = [s for s in tail.split("/") if s != ""]
    cur = r_root
    for s in segs:
        seg = unquote(s)
        _clean_seg(seg, uri)
        cur = os.path.join(cur, seg)
    path = _guard_inside(r_root, cur, "域 %s" % host)
    if must_exist and not os.path.exists(path):
        raise ResError(-32001, "路径不存在：%s" % uri)
    if path == r_root:
        kind = "domain"
    elif os.path.isdir(path):
        kind = "dir"
    else:
        kind = "file"
    return {"kind": kind, "path": path, "uri": uri, "domain": host}


# ---------------- 权限 / 熔断 ----------------
def check_scope(method, have):
    need = METHOD_SCOPE.get(method)
    if need is None:
        return False
    return SCOPE_RANK.get(have or "none", 0) >= SCOPE_RANK[need]


def lockdown_denies(method, lockdown_active):
    return bool(lockdown_active) and method in WRITE_METHODS


# ---------------- 转调计划（复用内核既有工具） ----------------
def read_plan(uri, cfg):
    ref = resolve(uri, cfg)
    return "file_read", {"path": ref["path"]}


def write_plan(uri, cfg, text, append=False):
    ref = resolve(uri, cfg, must_exist=False)
    hit = protected_hit(ref["path"], cfg)
    if hit:
        raise ResError(-32003, "保护名单，禁止写入：%s" % hit)
    args = {"path": ref["path"], "text": text}
    if append:
        args["append"] = "1"
    return "file_write_text", args       # 走门面既有链路 → 自动获得写前快照与审计


# ---------------- 列举 ----------------
def _entry(uri, name, level, path=None, domain=None, size=None, mtime=None,
           pool=None, file_count=None):
    e = {"uri": uri, "name": name, "level": level}
    if domain:
        e["domain"] = domain
    if pool:
        e["pool"] = pool
    if size is not None:
        e["size_bytes"] = size
    if mtime is not None:
        e["mtime"] = int(mtime)
    if file_count is not None:
        e["file_count"] = file_count
    if path is not None and not path.startswith("lemon://"):
        try:
            st = os.stat(path)
            e["size_bytes"] = st.st_size
            e["mtime"] = int(st.st_mtime)
        except OSError:
            pass
    return e


def _pool_entries(pool_key, cfg, no_cache=False, unavailable=None):
    """编号池条目；某池索引缺失/未接入时降级跳过并登记原因，绝不整体失败。"""
    out = []
    pool = cfg.pools.get(pool_key)
    if not pool:
        return out
    try:
        rows = _read_pool(pool, no_cache)
    except ResError as e:
        if unavailable is not None:
            unavailable.append({"pool": pool_key, "reason": e.message})
        return out
    for n, name, path in rows:
        if not os.path.exists(path):
            continue                        # 幽灵条目不进 list
        out.append(_entry("lemon://num/" + n, name, "num", domain=pool.domain,
                          pool=pool_key))
    return out


def list_resources(uri, cfg, limit=200, cursor=0, gate=65536, no_cache=False):
    """目录级/域级/编号级列举；文件级 URI 不可列举。gate 为输出字节预算。"""
    ref = resolve(uri, cfg, must_exist=(not uri.rstrip("/").endswith("trash")))
    if ref["kind"] not in LISTABLE_KINDS:
        raise ResError(-32602, "该 URI 不是可列举层级：%s" % uri)
    entries = []
    unavailable = []
    if ref["kind"] == "domain":
        names = sorted(os.listdir(ref["path"]))
        for n in names:
            if n.startswith(cfg.hidden_prefix):
                continue
            p = os.path.join(ref["path"], n)
            if os.path.isdir(p):
                try:
                    fc = len([x for x in os.listdir(p) if not x.startswith(".")])
                except OSError:
                    fc = None
                entries.append(_entry("lemon://%s/%s" % (ref["domain"], n), n,
                                      "dir", path=p, domain=ref["domain"],
                                      file_count=fc))
        for pk, pool in cfg.pools.items():
            if pool.domain == ref["domain"]:
                entries += _pool_entries(pk, cfg, no_cache, unavailable)
    elif ref["kind"] == "dir":
        for n in sorted(os.listdir(ref["path"])):
            if n.startswith(cfg.hidden_prefix):
                continue
            p = os.path.join(ref["path"], n)
            if not os.path.isdir(p):
                continue                    # 文件级不进 list
            pre = "lemon://%s/" % ref["domain"]
            rel = os.path.relpath(p, os.path.realpath(cfg.domains[ref["domain"]]))
            entries.append(_entry(pre + rel.replace(os.sep, "/"), n, "dir",
                                  path=p, domain=ref["domain"]))
    elif ref["kind"] == "num_root":
        for pk in sorted(cfg.pools.keys()):
            entries += _pool_entries(pk, cfg, no_cache, unavailable)
    elif ref["kind"] == "trash":
        names = []
        try:
            names = sorted(os.listdir(ref["path"]))
        except OSError:
            names = []
        for n in names:
            entries.append(_entry("lemon://trash/" + n, n, "trash_pkg",
                                  path=os.path.join(ref["path"], n)))

    cursor = int(cursor or 0)
    limit = max(1, min(int(limit or 200), 300))
    total = len(entries)
    window = entries[cursor:cursor + limit]

    # gate 预算：逐条累计 JSON 实际字节，宁少不超，剩余部分留给游标
    budget, used, kept = int(gate), 0, []
    for e in window:
        cost = len(json.dumps(e, ensure_ascii=False).encode("utf-8")) + 2
        if used + cost > budget:
            break
        kept.append(e)
        used += cost
    consumed = cursor + len(kept)
    has_more = consumed < total or (len(kept) < len(window))
    return {
        "uri": uri,
        "level": ref["kind"],
        "entries": kept,
        "truncated": bool(len(kept) < total),
        "next_cursor": consumed if has_more else None,
        "pools_unavailable": unavailable,
        "total_estimate": total,
    }


# ---------------- 删除 / 恢复 ----------------
def _new_event_id(seed):
    return "R%d%04x" % (int(time.time() * 1000) & 0xFFFFFFFF,
                        (seed ^ int(time.time())) & 0xFFFF)


def do_remove(uri, cfg, confirm="", snapshot_fn=None, scope="root"):
    """强制快照 + 软删入回收站；快照失败即中止；非空目录拒绝递归。"""
    want = "remove:" + uri
    if confirm != want:
        raise ResError(-32602, "缺少或错误的 confirm（需原样回传 %s）" % want)
    ref = resolve(uri, cfg)
    hit = protected_hit(ref["path"], cfg)
    if hit:
        raise ResError(-32003, "保护名单，禁止删除：%s" % hit)
    is_dir = os.path.isdir(ref["path"])
    snap = ""
    if is_dir:
        try:
            children = os.listdir(ref["path"])
        except OSError as e:
            raise ResError(-32001, "目录不可读：%r" % e)
        if children:
            raise ResError(-32602, "非空目录禁止删除（不支持递归）；"
                                   "请逐条删除目录内文件")
    else:
        if snapshot_fn is None:
            raise ResError(-32001, "删除前必须提供快照能力")
        snap = snapshot_fn(ref["path"], cfg.snap_max_bytes) or ""
        if not snap or not os.path.exists(snap):        # 坑 2：硬阻断
            raise ResError(-32001, "删除中止：快照未成功，原文件保持不动")
    evt = _new_event_id(id(uri) ^ len(uri))
    pkg_name = "%s-p%d-%06x" % (time.strftime("%Y%m%d-%H%M%S"),
                                os.getpid(), random.getrandbits(24))
    pkg = os.path.join(cfg.trash_dir, pkg_name)
    os.makedirs(pkg, exist_ok=True)
    moved_name = os.path.basename(ref["path"].rstrip(os.sep)) or "noname"
    try:
        shutil.move(ref["path"], os.path.join(pkg, moved_name))
    except Exception as e:
        shutil.rmtree(pkg, ignore_errors=True)
        raise ResError(-32001, "移入回收站失败：%r" % e)
    man = {"uri": uri, "original_path": ref["path"], "moved_name": moved_name,
           "snapshot": snap or None, "event_id": evt, "scope": scope,
           "domain": ref.get("domain"), "pool": ref.get("pool"),
           "is_dir": bool(is_dir), "removed_at": int(time.time())}
    with open(os.path.join(pkg, "_manifest.json"), "w", encoding="utf-8") as f:
        json.dump(man, f, ensure_ascii=False, indent=1)
    return {"removed": True, "trash": pkg_name, "original_path": ref["path"],
            "snapshot": snap or None, "event_id": evt}


def do_restore(pkg_name, cfg):
    if not pkg_name or "/" in pkg_name or "\\" in pkg_name or pkg_name.startswith("."):
        raise ResError(-32602, "回收站条目名非法")
    pkg = os.path.join(cfg.trash_dir, pkg_name)
    _guard_inside(cfg.trash_dir, pkg, "回收站条目")
    man_path = os.path.join(pkg, "_manifest.json")
    if not os.path.isfile(man_path):
        raise ResError(-32001, "回收站条目缺少清单：%s" % pkg_name)
    with open(man_path, encoding="utf-8") as f:
        man = json.load(f)
    original = man.get("original_path") or ""
    if not original:
        raise ResError(-32001, "清单缺少原路径")
    if os.path.exists(original):
        raise ResError(-32003, "原路径已存在，拒绝覆盖：%s" % original)
    hit = protected_hit(original, cfg)
    if hit:
        raise ResError(-32003, "保护名单，禁止恢复到：%s" % hit)
    src = os.path.join(pkg, man.get("moved_name") or "")
    if not os.path.exists(src):
        raise ResError(-32001, "回收站内文件缺失：%s" % src)
    parent = os.path.dirname(original)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    shutil.move(src, original)
    shutil.rmtree(pkg, ignore_errors=True)
    return {"restored": True, "path": original, "event_id": man.get("event_id")}


# ---------------- 生产默认配置 ----------------
_RES = "$LEMON_DATA"
_MEM = os.path.join(_RES, "小柠檬记忆中心")
_REPO = os.path.join(_RES, "小柠檬仓库中心")
_LEARN = os.path.join(_MEM, "小柠檬学习中心")
_ZDIR = os.path.join(_RES, "小柠檬专用文件夹")
_SLIM = "/data/lemonbrain/slimproxy"

DEFAULT_CFG = Cfg(
    domains={
        "mem": _MEM,
        "repo": _REPO,
        "learn": _LEARN,
        "mcp": _SLIM,
        "kern": "/data/local/tmp/kernel_common-android15-6.6",
    },
    pools={
        "L": Pool(os.path.join(_LEARN, "_索引", "编号索引.tsv"), 5, _LEARN,
                  has_header=False, domain="learn"),
        "C": Pool(os.path.join(_REPO, "_索引", "编号索引.tsv"), 4, _REPO,
                  has_header=True, domain="repo"),
        # Z 池列序尚未实测（path_col<=0 → 解析时安全拒绝而非猜），真机确认后回填
        "Z": Pool(os.path.join(_ZDIR, "_索引", "编号索引.tsv"), 0, _ZDIR,
                  has_header=False, domain=None),
    },
    protected=[
        os.path.join(_REPO, "六号备份仓库"),
        os.path.join(_MEM, "内置记忆只读禁止修改"),
        os.path.join(_SLIM, ".token"),
        os.path.join(_SLIM, ".tokens.json"),
        os.path.join(_SLIM, ".token_maint"),
        os.path.join(_SLIM, ".cmdguard.json"),
        os.path.join(_SLIM, "LOCKDOWN"),
        "/data/adb/lemon_core",
        "/data/adb/lemon_kernel",
        "/data/lemonbrain/trash",
    ],
    trash_dir="/data/lemonbrain/trash",
    snap_dir="/data/lemonbrain/snapshots",
    snap_max_bytes=64 * 1024 * 1024,
)


# ============ MCP 规范输出转换（v137）============
# 之前把结果塞进 tools 风格的 content[] 里，标准 MCP 客户端读不到 resources/contents。
_MIME_MAP = {
    ".md": "text/markdown", ".markdown": "text/markdown",
    ".json": "application/json", ".txt": "text/plain", ".log": "text/plain",
    ".tsv": "text/tab-separated-values", ".csv": "text/csv",
    ".sh": "text/x-shellscript", ".py": "text/x-python", ".c": "text/x-c",
    ".h": "text/x-c", ".js": "text/javascript",
    ".zip": "application/zip", ".gz": "application/gzip", ".tar": "application/x-tar",
    ".apk": "application/vnd.android.package-archive",
    ".pyc": "application/octet-stream", ".so": "application/octet-stream",
}


def mime_of(path_or_uri):
    """按扩展名给 mimeType；未知一律 text/plain（宁可当文本也别报二进制）。"""
    name = str(path_or_uri or "").split("?")[0]
    base = name.rsplit("/", 1)[-1]
    dot = base.rfind(".")
    if dot <= 0:
        return "text/plain"
    return _MIME_MAP.get(base[dot:].lower(), "text/plain")


def spec_list_result(raw):
    """内部列举结果 -> MCP resources/list 规范 result。"""
    items = []
    for e in raw.get("entries") or []:
        it = {"uri": e.get("uri"), "name": e.get("name")}
        lvl = e.get("level") or ""
        bits = []
        if lvl == "dir":
            bits.append("目录")
            if e.get("file_count") is not None:
                bits.append("%d 个条目" % e["file_count"])
        elif lvl == "num":
            bits.append("编号条目(%s)" % (e.get("pool") or "?"))
        elif lvl == "file":
            bits.append("文件")
        else:
            bits.append(str(lvl))
        if e.get("size_bytes") is not None:
            bits.append("%d 字节" % e["size_bytes"])
        if e.get("domain"):
            bits.append("域 %s" % e["domain"])
        it["description"] = " · ".join(bits)
        base = str(e.get("uri") or "").rsplit("/", 1)[-1]
        if "." in base and base != ".":
            it["mimeType"] = mime_of(base)
        items.append(it)
    out = {"resources": items}
    nc = raw.get("next_cursor")
    if nc is not None:
        out["nextCursor"] = str(nc)
    out["_meta"] = {
        "uri": raw.get("uri"),
        "level": raw.get("level"),
        "returned": len(items),
        "total_estimate": raw.get("total_estimate"),
        "truncated": bool(raw.get("truncated")),
        "pools_unavailable": raw.get("pools_unavailable") or [],
    }
    return out


def spec_read_result(uri, text, domain=None, resolved_path=None, meta=None):
    """文件正文 -> MCP resources/read 规范 result；分段信息留在 _meta。"""
    item = {"uri": uri, "mimeType": mime_of(resolved_path or uri), "text": text or ""}
    out = {"contents": [item]}
    m = dict(meta or {})
    m["resolved_path"] = resolved_path
    if domain:
        m["domain"] = domain
    out["_meta"] = m
    return out


def resolve_file(uri, cfg):
    """resources/read 专用：只接受可读文件。
    目录/域根不是可读资源，必须在解析层拒绝——否则底层 file_read 对目录的报错
    不会置 isError，会被当成正文包进 contents，向客户端返回假成功。"""
    ref = resolve(uri, cfg)
    # 编号 URI 的 kind 是 num，一律以底层路径是否为真实文件为准
    if os.path.isfile(ref["path"]):
        ref = dict(ref)
        ref["kind"] = "file"
        return ref
    what = "目录" if os.path.isdir(ref["path"]) else (ref.get("kind") or "未知")
    raise ResError(-32602, "该 URI 不是可读文件（%s），请用 resources/list 列举：%s"
                   % (what, uri))