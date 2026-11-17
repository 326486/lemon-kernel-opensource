#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""web_fetch.py — 小柠檬内核网页正文抓取 v1.0（261115）
仅 http/https；禁内网/环回/链路本地/保留地址（SSRF 防护）；纯文本输出 ≤60000 字符。
"""
import sys, re, socket, ipaddress, urllib.request, urllib.parse
from html.parser import HTMLParser

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
TIMEOUT = 15
MAX_CHARS = 60000
CGNAT = ipaddress.ip_network('100.64.0.0/10')

class TextExtract(HTMLParser):
    SKIP = {'script', 'style', 'noscript', 'svg', 'head'}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0
        self.title = ''
        self.in_title = False
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        if tag == 'title':
            self.in_title = True
        if tag in ('p','div','br','li','h1','h2','h3','h4','tr','section','article'):
            self.parts.append('\n')
    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip > 0:
            self.skip -= 1
        if tag == 'title':
            self.in_title = False
    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self.skip == 0:
            self.parts.append(data)

def guard(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ('http', 'https'):
        raise ValueError('only http/https allowed')
    if not p.hostname:
        raise ValueError('no host')
    infos = socket.getaddrinfo(p.hostname, p.port or (443 if p.scheme == 'https' else 80), proto=socket.IPPROTO_TCP)
    for _, _, _, _, sa in infos:
        ip = ipaddress.ip_address(sa[0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved
                or ip.is_unspecified or ip in CGNAT):
            raise ValueError('internal address blocked: %s' % sa[0])

def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print('[web_fetch] usage: web_fetch.sh <url>')
        sys.exit(1)
    url = sys.argv[1].strip()
    try:
        guard(url)
        req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'zh-CN,zh;q=0.9'})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read(3000000)
            ctype = r.headers.get('Content-Type', '')
        if not any(x in ctype for x in ('text/html', 'application/xhtml', 'text/plain')):
            print('[web_fetch] non-text content (%s), %d bytes — not extracted' % (ctype, len(raw)))
            return
        html = raw.decode('utf-8', 'ignore')
        # 预清洗：整块移除 script/style/注释（含未闭合残块），防 CSS/JS 泄漏进正文
        html = re.sub(r'<script\b[^>]*>.*?</script\s*>', '', html, flags=re.S | re.I)
        html = re.sub(r'<style\b[^>]*>.*?</style\s*>', '', html, flags=re.S | re.I)
        html = re.sub(r'<!--.*?-->', '', html, flags=re.S)
        if re.search(r'<style\b', html, re.I):
            html = re.sub(r'<style\b[^>]*>.*', '', html, flags=re.S | re.I)
        if re.search(r'<script\b', html, re.I):
            html = re.sub(r'<script\b[^>]*>.*', '', html, flags=re.S | re.I)
        p = TextExtract()
        p.feed(html)
        text = ''.join(p.parts)
        text = re.sub(r'<[^>\n]{0,300}>', '', text)
        # 清洗转义实体还原出的 CSS 规则块（selector{...}），两轮处理嵌套
        text = re.sub(r'[^{}\n]{0,2000}\{[^{}]{0,3000}\}', ' ', text)
        text = re.sub(r'[^{}\n]{0,2000}\{[^{}]{0,3000}\}', ' ', text)
        # 丢弃残留的 CSS 选择器行（.class/#id/@media 开头或长选择器链）
        _lines = []
        for _l in text.split('\n'):
            if re.match(r'^\s*[.#@]', _l):
                continue
            if re.search(r'[.#][a-zA-Z][\w-]*(\s+[.#][a-zA-Z][\w-]*){2,}', _l):
                continue
            _lines.append(_l)
        text = '\n'.join(_lines)
        text = re.sub(r'[ \t]+', ' ', text)
        text = re.sub(r'\n\s*\n+', '\n\n', text).strip()
        print('[web_fetch] url=%s title=%s chars=%d' % (url, p.title.strip()[:100], len(text)))
        print(text[:MAX_CHARS])
        if len(text) > MAX_CHARS:
            print('\n[web_fetch] truncated at %d chars' % MAX_CHARS)
    except ValueError as e:
        print('[web_fetch] BLOCKED: %s' % e)
        sys.exit(3)
    except Exception as e:
        print('[web_fetch] ERROR: %s' % str(e)[:120])
        sys.exit(2)

if __name__ == '__main__':
    main()
