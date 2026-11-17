#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web_search.py — 小柠檬内核联网搜索 v2.0（261115）
主引擎：小浣熊上游 AI 搜索（raccoon2api 网关 enable_search=true，实时联网+来源）
备用链：baidu → sogou → so360 → cn.bing（HTML 解析，网关不可用时兜底）
配置：同目录 search.conf（RACCOON_URL/KEY/MODEL），环境变量可覆盖（测试用）。
"""
import sys, os, re, json, urllib.request, urllib.parse

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
TIMEOUT = 12
AI_TIMEOUT = 45
MAX_RESULTS = 8
HERE = os.path.dirname(os.path.abspath(__file__))

def clean(s):
    s = re.sub(r'<[^>]+>', '', s)
    for a, b in (('&amp;','&'),('&lt;','<'),('&gt;','>'),('&quot;','"'),('&#39;',"'"),('&nbsp;',' ')):
        s = s.replace(a, b)
    return re.sub(r'\s+', ' ', s).strip()

def load_conf():
    conf = {}
    try:
        for line in open(os.path.join(HERE, 'search.conf'), encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                conf[k.strip()] = v.strip()
    except OSError:
        pass
    for k in ('RACCOON_URL', 'RACCOON_KEY', 'RACCOON_MODEL'):
        if os.environ.get(k):
            conf[k] = os.environ[k]
    return conf

def ai_search(q, conf):
    prompt = ("请联网搜索「%s」。把搜索到的结果整理成列表，最多8条，每条严格一行，格式：\n"
              "[N] 标题 ||| URL ||| 一句话摘要\n"
              "URL 必须是搜索结果里真实存在的链接，禁止编造；没有真实URL的结果丢弃。只输出列表。" % q)
    body = json.dumps({
        'model': conf.get('RACCOON_MODEL', 'sn-sensenova-6-8-flash'),
        'messages': [{'role': 'user', 'content': prompt}],
        'max_tokens': 2048,
        'enable_search': True,
    }).encode()
    req = urllib.request.Request(
        conf['RACCOON_URL'].rstrip('/') + '/chat/completions',
        data=body,
        headers={'Authorization': 'Bearer ' + conf['RACCOON_KEY'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=AI_TIMEOUT) as r:
        d = json.loads(r.read())
    # 优先用上游返回的结构化引用（如有）
    cits = d.get('citations') or d.get('search_results') or d['choices'][0]['message'].get('citations')
    if isinstance(cits, list) and cits:
        out = []
        for c in cits[:MAX_RESULTS]:
            if isinstance(c, dict):
                u = c.get('url') or c.get('link') or ''
                t = c.get('title') or c.get('name') or u
                s = c.get('snippet') or c.get('content') or c.get('text') or ''
                if u.startswith('http'):
                    out.append((clean(str(t)), u, clean(str(s))[:200]))
        if out:
            return out
    content = d['choices'][0]['message'].get('content', '') or ''
    out = []
    for line in content.split('\n'):
        m = re.match(r'\s*\[?\d+\]?\s*(.+?)\s*\|\|\|\s*(https?://\S+?)\s*\|\|\|\s*(.*)', line)
        if m:
            out.append((clean(m.group(1)), m.group(2).rstrip('。,，'), clean(m.group(3))[:200]))
    if not out:
        for line in content.split('\n'):
            m = re.search(r'(https?://[^\s|）)>\]]+)', line)
            if m:
                title = clean(line[:m.start()]) or m.group(1)
                out.append((title[:80], m.group(1).rstrip('。,，'), ''))
    return out[:MAX_RESULTS]

def http_get(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read(2000000).decode('utf-8', 'ignore')

def parse_bing(html):
    out = []
    for b in re.split(r'<li class="b_algo"', html)[1:]:
        m = re.search(r'<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', b, re.S)
        if not m:
            continue
        url, title = m.group(1), clean(m.group(2))
        sn = re.search(r'<p[^>]*>(.*?)</p>', b, re.S)
        snippet = clean(sn.group(1)) if sn else ''
        if url.startswith('http'):
            out.append((title, url, snippet))
    return out

def parse_baidu(html):
    out = []
    for b in re.split(r'<div[^>]*class="result c-container[^"]*"', html)[1:]:
        m = re.search(r'<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', b, re.S)
        if not m:
            continue
        url, title = m.group(1), clean(m.group(2))
        sn = re.search(r'<span[^>]*class="content-right_[^"]*"[^>]*>(.*?)</span>', b, re.S)
        snippet = clean(sn.group(1)) if sn else ''
        if url.startswith('http'):
            out.append((title, url, snippet))
    return out

def parse_sogou(html):
    out = []
    for b in re.split(r'<div[^>]*class="vrwrap"', html)[1:]:
        m = re.search(r'<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', b, re.S)
        if not m:
            continue
        url, title = m.group(1), clean(m.group(2))
        if url.startswith('/'):
            url = 'https://www.sogou.com' + url
        sn = re.search(r'<div[^>]*class="text-layout"[^>]*>(.*?)</div>', b, re.S)
        snippet = clean(sn.group(1)) if sn else ''
        if url.startswith('http'):
            out.append((title, url, snippet))
    return out

def parse_so(html):
    out = []
    for m in re.finditer(r'<h3[^>]*class="res-title[^"]*"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', html, re.S):
        url, title = m.group(1), clean(m.group(2))
        if url.startswith('/'):
            url = 'https://www.so.com' + url
        if url.startswith('http') and title:
            out.append((title, url, ''))
    return out

def generic_parse(html):
    out = []
    for m in re.finditer(r'<h[23][^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', html, re.S):
        url, title = m.group(1), clean(m.group(2))
        if url.startswith('http') and title:
            out.append((title, url, ''))
    return out

ENGINES = [
    ('baidu', 'https://www.baidu.com/s?wd={q}&rn=10', parse_baidu),
    ('sogou', 'https://www.sogou.com/web?query={q}', parse_sogou),
    ('so360', 'https://www.so.com/s?q={q}', parse_so),
    ('cn.bing', 'https://cn.bing.com/search?q={q}&count=10', parse_bing),
]

def emit(name, q, results, fb=''):
    print('[web_search] engine=%s query=%s results=%d%s' % (name, q, len(results), fb))
    for i, (t, u, s) in enumerate(results, 1):
        print('[%d] %s' % (i, t))
        print('    %s' % u)
        if s:
            print('    %s' % s[:200])

def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print('[web_search] usage: web_search.sh <query>')
        sys.exit(1)
    q = sys.argv[1].strip()
    conf = load_conf()
    errors = []
    if conf.get('RACCOON_URL') and conf.get('RACCOON_KEY'):
        try:
            results = ai_search(q, conf)
            if results:
                emit('raccoon-ai', q, results)
                return
            errors.append('raccoon:0')
        except Exception:
            errors.append('raccoon:err')
    enc = urllib.parse.quote(q)
    for name, tpl, parser in ENGINES:
        try:
            html = http_get(tpl.format(q=enc))
            results = parser(html)[:MAX_RESULTS]
            if not results:
                results = generic_parse(html)[:MAX_RESULTS]
            if results:
                fb = (' fallback=' + ','.join(errors)) if errors else ''
                emit(name, q, results, fb)
                return
            errors.append('%s:0' % name)
        except Exception:
            errors.append('%s:err' % name)
    print('[web_search] all engines failed: %s' % '; '.join(errors))
    sys.exit(2)

if __name__ == '__main__':
    main()
