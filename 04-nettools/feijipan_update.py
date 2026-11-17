#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# feijipan_update.py —— 飞践盘(网盘)即更新源（取长补短·源自 MT论坛Pro UpdateChecker 逆向）
# 协议（已从 4.7.9 逆向还原）：
#   POST https://api.feijipan.com/ws/share/list?code=&shareId=<SID>&userId=&type=0&offset=1
#        &limit=110&referer=https://share.feijipan.com/s/<SID>&devType=3&devModel=Android
#        &uuid=<UUID>&extra=2&timestamp=<AES-128-ECB(key="dingHao-disk-app", PKCS7)加密毫秒时间戳→hex>
#   响应 code==200 → {list:[{fileType(2=目录), folderId|sortId, fileName, updTime|addTime, ...}]}
# 用法：
#   python3 feijipan_update.py [--shareid EV7ERHQw] [--version 4.7.9]
import sys, os, re, json, time, uuid, urllib.request, urllib.parse

API_URL = "https://api.feijipan.com/ws/share/list"
AES_KEY = b"dingHao-disk-app"        # 16B → AES-128
VER_RE = re.compile(r"([0-9]+(?:\.[0-9]+)*)$")

def _aes_backend():
    for mod in ("Crypto", "Cryptodome"):
        try:
            m = __import__(mod + ".Cipher.AES", fromlist=["AES"])
            return mod, m
        except ImportError:
            continue
    return None, None

def enc_timestamp() -> str:
    ts = str(int(time.time() * 1000)).encode()
    mod, AES = _aes_backend()
    if AES is not None:
        c = AES.new(AES_KEY, AES.MODE_ECB)
        pad = 16 - (len(ts) % 16)
        data = ts + bytes([pad]) * pad   # PKCS7
        return c.encrypt(data).hex()
    # openssl CLI 兜底
    import subprocess
    p = subprocess.run(["openssl", "enc", "-aes-128-ecb", "-K", AES_KEY.hex(), "-nosalt"],
                       input=ts, capture_output=True, timeout=20)
    if p.returncode != 0:
        raise RuntimeError("openssl enc failed")
    return p.stdout.hex()

def api_list(share_id: str, client_uuid: str, folder_id=None):
    q = {
        "code": "", "shareId": share_id, "userId": "", "type": "0",
        "offset": "1", "limit": "110", "referer": "https://share.feijipan.com/s/" + share_id,
        "devType": "3", "devModel": "Android", "uuid": client_uuid, "extra": "2",
        "timestamp": enc_timestamp(),
    }
    if folder_id:
        q["folderId"] = folder_id
    url = API_URL + "?" + urllib.parse.urlencode(q)
    req = urllib.request.Request(url, data=b"", method="POST",
                                 headers={"User-Agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36"})
    with urllib.request.urlopen(req, timeout=25) as r:   # 25s 硬超时，防挂死
        obj = json.loads(r.read().decode("utf-8", "replace"))
    if obj.get("code") != 200:
        raise RuntimeError("网盘 API 返回异常: %s" % obj.get("msg", obj.get("code")))
    return obj

def extract_ver(name: str):
    base = name.rsplit(".", 1)[0] if "." in name else name
    m = VER_RE.search(base.strip())
    return m.group(1) if m else None

def ver_tuple(v):
    try:
        return tuple(int(x) for x in v.split("."))
    except ValueError:
        return (0,)

def main() -> int:
    share_id, local_ver = "EV7ERHQw", None
    a = sys.argv[1:]
    i = 0
    while i < len(a):   # 有界推进
        if a[i] == "--shareid" and i + 1 < len(a):
            share_id = a[i+1]; i += 2; continue
        if a[i] == "--version" and i + 1 < len(a):
            local_ver = a[i+1]; i += 2; continue
        i += 1
    # client uuid：持久化，跨次稳定（模仿 App 的 getOrCreateUuid）
    uidf = "/data/lemonbrain/logs/.feiji_uuid"
    client_uuid = ""
    try:
        with open(uidf) as f:
            client_uuid = f.read().strip()
    except OSError:
        pass
    if not client_uuid:
        client_uuid = str(uuid.uuid4())
        try:
            with open(uidf, "w") as f:
                f.write(client_uuid)
        except OSError:
            pass
    try:
        root = api_list(share_id, client_uuid)
        lst = root.get("list") or []
        if not lst:
            raise RuntimeError("分享根目录为空")
        first = lst[0]
        fid = first.get("folderId") or first.get("sortId") or ""
        if not fid:
            raise RuntimeError("无法获取更新文件夹")
        inner = api_list(share_id, client_uuid, fid)
        files = [x for x in (inner.get("list") or []) if x.get("fileType", 1) != 2]
        if not files:
            raise RuntimeError("文件夹内没有文件")
        best, best_v = None, None
        for x in files:   # 有界循环
            v = extract_ver(x.get("fileName") or x.get("name") or "")
            if v is None:
                continue
            t = x.get("updTime") or x.get("addTime") or ""
            if best is None or ver_tuple(v) > ver_tuple(best_v) or (ver_tuple(v) == ver_tuple(best_v) and t > (best.get("updTime") or best.get("addTime") or "")):
                best, best_v = x, v
        if best is None:
            raise RuntimeError("未从文件名中识别到版本号")
        newer = None if not local_ver else (ver_tuple(best_v) > ver_tuple(local_ver))
        out = {
            "ok": True, "share_id": share_id,
            "latest_version": best_v,
            "file_name": best.get("fileName") or best.get("name"),
            "file_size": best.get("fileSize"),
            "update_time": best.get("updTime") or best.get("addTime"),
            "local_version": local_ver, "has_update": newer,
            "download_page": "https://share.feijipan.com/s/" + share_id,
            "file_meta": {k: best.get(k) for k in ("fileId", "fileType", "listIcon", "uploadTime") if k in best},
        }
        print(json.dumps(out, ensure_ascii=False))
        return 0
    except Exception as e:
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}, ensure_ascii=False))
        return 1

if __name__ == '__main__':
    sys.exit(main())