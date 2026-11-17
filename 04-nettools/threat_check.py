#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""threat_check.py — 小柠檬内核威胁情报哈希信誉 v1.0（261116）
文件/哈希/URL → SHA256 → MalwareBazaar/URLhaus（abuse.ch，需免费 Auth-Key）判定。
用法: threat_check.sh '{"action":"file","path":"/path/to/file"}'
      action: file <path> | hash <sha256> | url <url>
配置: 同目录 threat.conf（ABUSE_AUTH_KEY，auth.abuse.ch 免费注册），环境变量可覆盖。
无 key 时优雅降级返回 no_key；查询不到返回 clean_unknown（不在恶意库，非绝对干净）。
"""
import sys, os, json, hashlib, urllib.request, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
MB = 'https://mb-api.abuse.ch/api/v1/'
UH = 'https://urlhaus-api.abuse.ch/v1/'

def load_conf():
    conf = {}
    try:
        for line in open(os.path.join(HERE, 'threat.conf'), encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                conf[k.strip()] = v.strip()
    except OSError:
        pass
    if os.environ.get('ABUSE_AUTH_KEY'):
        conf['ABUSE_AUTH_KEY'] = os.environ['ABUSE_AUTH_KEY']
    return conf

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

def _post(url, fields, key):
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body, headers={
        'Auth-Key': key, 'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'lemon-kernel-threat/1.0'})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

def check_hash(sha, conf):
    sha = sha.lower().strip()
    key = conf.get('ABUSE_AUTH_KEY', '')
    if not key or key.startswith('<'):
        return {'sha256': sha, 'verdict': 'no_key',
                'note': '未配置 ABUSE_AUTH_KEY（auth.abuse.ch 免费注册），在线查询不可用', 'results': []}
    results = []
    malicious = False
    try:
        d = _post(MB, {'query': 'get_info', 'hash': sha}, key)
        qs = d.get('query_status')
        if qs == 'ok' and d.get('data'):
            info = d['data'][0]
            malicious = True
            results.append({'source': 'MalwareBazaar', 'hit': True,
                            'signature': info.get('signature'), 'file_type': info.get('file_type'),
                            'first_seen': info.get('first_seen'), 'tags': info.get('tags')})
        else:
            results.append({'source': 'MalwareBazaar', 'hit': False, 'status': qs})
    except Exception as e:
        results.append({'source': 'MalwareBazaar', 'error': str(e)[:80]})
    try:
        d = _post(UH + 'payload/', {'sha256': sha}, key)
        qs = d.get('query_status')
        if qs == 'ok':
            malicious = True
            results.append({'source': 'URLhaus', 'hit': True, 'threat': d.get('threat'),
                            'url_count': len(d.get('urls', []))})
        else:
            results.append({'source': 'URLhaus', 'hit': False, 'status': qs})
    except Exception as e:
        results.append({'source': 'URLhaus', 'error': str(e)[:80]})
    if malicious:
        verdict = 'malicious'
    elif all(r.get('hit') is False for r in results):
        verdict = 'clean_unknown'
    else:
        verdict = 'unknown'
    return {'sha256': sha, 'verdict': verdict, 'results': results}

def main():
    if len(sys.argv) < 2:
        print('[threat] usage: threat_check.sh \'{"action":"file","path":"..."}\''); sys.exit(1)
    try:
        a = json.loads(sys.argv[1])
    except Exception:
        print('[threat] request 须为合法 JSON'); sys.exit(1)
    act = a.get('action', '')
    conf = load_conf()
    if act == 'file':
        p = a.get('path', '')
        if not os.path.isfile(p):
            print('[threat] 文件不存在: %s' % p); sys.exit(2)
        sha = sha256_file(p)
        res = check_hash(sha, conf)
        res['file'] = p
        res['size'] = os.path.getsize(p)
    elif act == 'hash':
        sha = a.get('sha256', '')
        if len(sha) != 64:
            print('[threat] sha256 须为64位十六进制'); sys.exit(1)
        res = check_hash(sha, conf)
    elif act == 'url':
        u = a.get('url', '')
        key = conf.get('ABUSE_AUTH_KEY', '')
        if not key or key.startswith('<'):
            res = {'url': u, 'verdict': 'no_key', 'note': '未配置 ABUSE_AUTH_KEY'}
        else:
            try:
                d = _post(UH + 'url/', {'url': u}, key)
                qs = d.get('query_status')
                if qs == 'ok':
                    res = {'url': u, 'verdict': 'malicious', 'threat': d.get('threat'),
                           'url_status': d.get('url_status'), 'tags': d.get('tags')}
                else:
                    res = {'url': u, 'verdict': 'clean_unknown', 'status': qs}
            except Exception as e:
                res = {'url': u, 'verdict': 'unknown', 'error': str(e)[:80]}
    else:
        print('[threat] 未知 action: %s（可用 file/hash/url）' % act); sys.exit(1)
    print('[threat] ' + json.dumps(res, ensure_ascii=False))

if __name__ == '__main__':
    main()
