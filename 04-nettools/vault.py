#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vault.py —— 凭据保险箱（取长补短·源自 MT论坛Pro CookieCrypto：AES-256-GCM/AndroidKeyStore 思想）
# 用法：
#   python3 vault.py put <key> <value>        # 存（value 也可用 --stdin 从管道读）
#   python3 vault.py put <key> --stdin
#   python3 vault.py get <key>                # 取（打印明文）
#   python3 vault.py list                     # 列 key + 修改时间（永不打印明文）
#   python3 vault.py del <key>               # 删
# 存储：/data/lemonbrain/vault/<key>.vault，AES-256-GCM（12B IV+128bit tag）优先，
#       无加密库时兜底 openssl AES-256-CBC + HMAC-SHA256（encrypt-then-mac），格式带 MAGIC 头。
# 密钥：/data/lemonbrain/vault/.vault.key（0600，首次自动生成 32B 随机，仅 root 可读）
# 后端：pycryptodome(Crypto) → pycryptodomex(Cryptodome) → cryptography → openssl CLI 兜底
# 安全：key 白名单 ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$，防路径穿越；写后 chmod 600。
import sys, os, json, base64, re, hmac, hashlib, subprocess, secrets

VAULT_DIR = "/data/lemonbrain/vault"
KEY_FILE = os.path.join(VAULT_DIR, ".vault.key")
KEY_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_.\-]{0,63}$')
MAGIC_GCM = b"LV1:"   # GCM 条目
MAGIC_CBC = b"LV2:"   # CBC+HMAC 兜底条目
OPENSSL = "/data/data/com.termux/files/usr/bin/openssl"  # 不存在时回退 PATH 查找

def _backend():
    try:
        from Crypto.Cipher import AES
        return ("pycryptodome", AES)
    except ImportError:
        pass
    try:
        from Cryptodome.Cipher import AES
        return ("pycryptodomex", AES)
    except ImportError:
        pass
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        return ("cryptography", AESGCM)
    except ImportError:
        return (None, None)

def _openssl_bin() -> str:
    if os.path.exists(OPENSSL):
        return OPENSSL
    return "openssl"

def _master_key() -> bytes:
    os.makedirs(VAULT_DIR, mode=0o700, exist_ok=True)
    if os.path.exists(KEY_FILE):
        with open(KEY_FILE, 'rb') as f:
            k = f.read()
        if len(k) == 32:
            return k
    k = secrets.token_bytes(32)
    fd = os.open(KEY_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(k)
    return k

def _enc_gcm(key: bytes, pt: bytes):
    name, AES = _backend()
    iv = secrets.token_bytes(12)
    if name in ("pycryptodome", "pycryptodomex"):
        c = AES.new(key, AES.MODE_GCM, nonce=iv)
        ct, tag = c.encrypt_and_digest(pt)
    else:
        ct = AES(key).encrypt(iv, pt, None)
        tag = b""
    return MAGIC_GCM + base64.b64encode(iv + ct + tag)

def _dec_gcm(key: bytes, blob: bytes):
    raw = base64.b64decode(blob)
    iv, ct = raw[:12], raw[12:]
    name, AES = _backend()
    if name in ("pycryptodome", "pycryptodomex"):
        c = AES.new(key, AES.MODE_GCM, nonce=iv)
        if len(ct) >= 16:
            tag = ct[-16:]; body = ct[:-16]
            return c.decrypt_and_verify(body, tag)
        raise ValueError("bad gcm blob")
    return AES(key).decrypt(iv, ct, None)

def _enc_cbc(key: bytes, pt: bytes) -> bytes:
    iv = secrets.token_bytes(16)
    ek = hashlib.sha256(key + b"|E").digest()
    mk = hashlib.sha256(key + b"|M").digest()
    p = subprocess.run([_openssl_bin(), "enc", "-aes-256-cbc", "-K", ek.hex(), "-iv", iv.hex()],
                       input=pt, capture_output=True, timeout=30)
    if p.returncode != 0:
        raise RuntimeError("openssl enc failed")
    ct = p.stdout
    mac = hmac.new(mk, iv + ct, hashlib.sha256).digest()
    return MAGIC_CBC + base64.b64encode(iv + ct + mac)

def _dec_cbc(key: bytes, blob: bytes) -> bytes:
    raw = base64.b64decode(blob)
    iv, ct, mac = raw[:16], raw[16:-32], raw[-32:]
    mk = hashlib.sha256(key + b"|M").digest()
    if not hmac.compare_digest(mac, hmac.new(mk, iv + ct, hashlib.sha256).digest()):
        raise ValueError("HMAC 校验失败（数据被篡改或密钥不符）")
    ek = hashlib.sha256(key + b"|E").digest()
    p = subprocess.run([_openssl_bin(), "enc", "-d", "-aes-256-cbc", "-K", ek.hex(), "-iv", iv.hex()],
                       input=ct, capture_output=True, timeout=30)
    if p.returncode != 0:
        raise ValueError("openssl dec failed")
    return p.stdout

def vault_path(k: str) -> str:
    if not KEY_RE.match(k):
        raise ValueError("key 非法：须匹配 ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$（防路径穿越）")
    return os.path.join(VAULT_DIR, k + ".vault")

def cmd_put(k: str, val: str):
    mk = _master_key()
    backend = _backend()
    if backend[0]:
        blob = _enc_gcm(mk, val.encode('utf-8')); mode = "AES-256-GCM (" + backend[0] + ")"
    else:
        blob = _enc_cbc(mk, val.encode('utf-8')); mode = "AES-256-CBC+HMAC (兜底)"
    p = vault_path(k)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(blob)
    print(json.dumps({"ok": True, "op": "put", "key": k, "mode": mode}, ensure_ascii=False)); return 0

def cmd_get(k: str):
    p = vault_path(k)
    if not os.path.exists(p):
        print(json.dumps({"ok": False, "error": "key 不存在"}, ensure_ascii=False)); return 2
    with open(p, 'rb') as f:
        blob = f.read()
    mk = _master_key()
    if blob.startswith(MAGIC_GCM):
        pt = _dec_gcm(mk, blob[len(MAGIC_GCM):]).decode('utf-8')
    elif blob.startswith(MAGIC_CBC):
        pt = _dec_cbc(mk, blob[len(MAGIC_CBC):]).decode('utf-8')
    else:
        print(json.dumps({"ok": False, "error": "条目格式非法（非 vault 生成）"}, ensure_ascii=False)); return 2
    print(pt)   # get 直接出明文，便于管道复用
    return 0

def cmd_list():
    os.makedirs(VAULT_DIR, exist_ok=True)
    items = []
    for fn in sorted(os.listdir(VAULT_DIR)):   # 有界：目录列表
        if fn.endswith(".vault"):
            p = os.path.join(VAULT_DIR, fn)
            with open(p, 'rb') as f:
                head = f.read(4)
            items.append({"key": fn[:-6], "mode": "GCM" if head == MAGIC_GCM else ("CBC+HMAC" if head == MAGIC_CBC else "?"),
                          "mtime": int(os.path.getmtime(p)), "bytes": os.path.getsize(p)})
    print(json.dumps({"ok": True, "op": "list", "count": len(items), "items": items}, ensure_ascii=False)); return 0

def cmd_del(k: str):
    p = vault_path(k)
    if not os.path.exists(p):
        print(json.dumps({"ok": False, "error": "key 不存在"}, ensure_ascii=False)); return 2
    os.remove(p)
    print(json.dumps({"ok": True, "op": "del", "key": k}, ensure_ascii=False)); return 0

def main() -> int:
    a = sys.argv[1:]
    if not a:
        print(json.dumps({"ok": False, "error": "用法: vault put|get|list|del [args]"}, ensure_ascii=False)); return 2
    op = a[0]
    try:
        if op == "list":
            return cmd_list()
        if op in ("put", "get", "del") and len(a) >= 2:
            k = a[1]
            if op == "put":
                if len(a) >= 3:
                    val = a[2]
                    if val.startswith("@") and len(val) > 1:
                        with open(val[1:], "r", encoding="utf-8") as f:
                            val = f.read()
                    return cmd_put(k, val)
                if not sys.stdin.isatty():
                    return cmd_put(k, sys.stdin.read())
                print(json.dumps({"ok": False, "error": "put 需要 value（参数或管道）"}, ensure_ascii=False)); return 2
            if op == "get":
                return cmd_get(k)
            return cmd_del(k)
        print(json.dumps({"ok": False, "error": "参数不合法"}, ensure_ascii=False)); return 2
    except ValueError as e:
        print(json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)); return 2
    except Exception as e:
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}, ensure_ascii=False)); return 1

if __name__ == '__main__':
    sys.exit(main())