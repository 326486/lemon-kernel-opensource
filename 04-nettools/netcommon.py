# 小柠檬内核·免费网络工具公共模块（仅标准库；urllib失败自动回退Termux curl）
import sys, json, gzip, subprocess, urllib.request, urllib.parse

UA = "Mozilla/5.0 (Linux; Android 16; PLQ110) LemonKernel/1.3"
CURL = '/data/data/com.termux/files/usr/bin/curl'

def clean(v, default=None):
    if v is None: return default
    if isinstance(v, str) and (v.startswith('$') or v == ''): return default
    return v

def _curl_raw(url, data=None, headers=None, timeout=30, method=None):
    cmd = [CURL, '-s', '--compressed', '-m', str(int(timeout)), '-A', UA]
    if method: cmd += ['-X', method]
    for k, v in (headers or {}).items():
        if k.lower() in ('accept-encoding', 'user-agent'): continue
        cmd += ['-H', '%s: %s' % (k, v)]
    if data is not None:
        cmd += ['--data-binary', data if isinstance(data, str) else data.decode('utf-8', 'replace')]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, timeout=int(timeout) + 15)
    if r.returncode != 0:
        raise RuntimeError('curl回退失败 rc=%d: %s' % (r.returncode, r.stderr.decode('utf-8', 'replace')[:150]))
    return r.stdout

def http_raw(url, data=None, headers=None, timeout=30, method=None):
    h = {"User-Agent": UA, "Accept-Encoding": "gzip"}
    if headers: h.update(headers)
    if isinstance(data, str): data = data.encode('utf-8')
    try:
        req = urllib.request.Request(url, data=data, headers=h, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            if r.headers.get('Content-Encoding') == 'gzip':
                raw = gzip.decompress(raw)
            return raw
    except Exception:
        return _curl_raw(url, data=data, headers=headers, timeout=timeout, method=method)

def http(url, data=None, headers=None, timeout=30, method=None):
    return http_raw(url, data=data, headers=headers, timeout=timeout, method=method).decode('utf-8', 'replace')

def out(obj):
    s = json.dumps(obj, ensure_ascii=False, indent=1)
    b = s.encode('utf-8')
    if len(b) > 3400:
        s = b[:3300].decode('utf-8', 'ignore') + '\n...[输出截断]'
    print(s)

def die(msg):
    print(json.dumps({"error": str(msg)}, ensure_ascii=False))
    sys.exit(1)

def trunc(s, n):
    s = ' '.join(str(s).split())
    return s if len(s) <= n else s[:n] + '…'