#!/data/data/com.termux/files/usr/bin/python3
# MT论坛 knowledge client v1.1 - 261117 (方向A; WAF走内核waf_acw_solver)
import sys, os, re, json, time, html, gzip, zlib, urllib.request, urllib.parse, urllib.error, hashlib
BASE='https://bbs.binmt.cc'
CACHE='/data/lemonbrain/nettools/forum_cache'
KERNEL='http://127.0.0.1:8788/'
os.makedirs(CACHE, exist_ok=True)
UA='Mozilla/5.0 (Linux; Android 16; PLQ110) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36'
LAST=[0.0]; ACW=[None]
def cookies():
    return ''  # 应用cookie为加密blob,登录态复用暂缓;公开内容走访客
def kernel_solve(h):
    tmp=f'{CACHE}/challenge.html'
    open(tmp,'w',encoding='utf-8').write(h)
    body=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"waf_acw_solver","arguments":{"file":tmp}}}).encode()
    rq=urllib.request.Request(KERNEL,data=body,headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
    try:
        r=json.loads(urllib.request.urlopen(rq,timeout=30).read().decode('utf-8','replace'))
        txt=re.sub(r'^\[exit=\d+\]\s*','',r['result']['content'][0]['text'])
        j=json.loads(txt)
        return j.get('cookie') if j.get('ok') else None
    except Exception:
        return None
def fetch(url, use_cache=True):
    dt=time.time()-LAST[0]
    if dt<2: time.sleep(2-dt)
    LAST[0]=time.time()
    key=hashlib.sha256(url.encode()).hexdigest()[:16]
    cf=f'{CACHE}/{key}.html'
    if use_cache and os.path.exists(cf) and time.time()-os.path.getmtime(cf)<86400:
        return open(cf,encoding='utf-8',errors='replace').read()
    raw=''
    for attempt in range(3):
        ck=('acw_sc__v2='+ACW[0]) if ACW[0] else ''
        rq=urllib.request.Request(url, headers={'User-Agent':UA,'Cookie':ck,'Accept':'text/html,application/json','Accept-Encoding':'gzip'})
        try:
            resp=urllib.request.urlopen(rq,timeout=25); data=resp.read(); enc=resp.headers.get('Content-Encoding','')
        except urllib.error.HTTPError as e:
            data=e.read(); enc=e.headers.get('Content-Encoding','') if e.headers else ''
        if enc=='gzip': data=gzip.decompress(data)
        elif enc=='deflate': data=zlib.decompress(data)
        elif enc=='br':
            try:
                import brotli; data=brotli.decompress(data)
            except Exception: pass
        raw=data.decode('utf-8','replace')
        if attempt<2 and 'arg1' in raw:
            cv=kernel_solve(raw)
            if cv: ACW[0]=cv; continue
        break
    open(cf,'w',encoding='utf-8').write(raw)
    return raw
def clean(s):
    s=re.sub(r'<script.*?</script>','',s,flags=re.S)
    s=re.sub(r'<style.*?</style>','',s,flags=re.S)
    s=re.sub(r'<[^>]+>',' ',s)
    return html.unescape(re.sub(r'\s+',' ',s)).strip()
def threads(h):
    items=[]; seen=set()
    for pat in (r'href="([^"]*?thread-(\d+)-\d+-\d+\.html[^"]*)"[^>]*>(.*?)</a>',
                r'href="([^"]*mod=viewthread[^"]*tid=(\d+)[^"]*)"[^>]*>(.*?)</a>'):
        for m in re.finditer(pat, h, flags=re.S):
            title=clean(m.group(3)); tid=m.group(2)
            if title and len(title)>3 and tid not in seen:
                seen.add(tid); items.append({'tid':tid,'title':title[:80]})
    return items
def hot():
    h=fetch(f'{BASE}/forum.php?mod=guide&view=newthread')
    if 'arg1' in h and 'thread-' not in h: return {'ok':False,'error':'WAF_CHALLENGE'}
    it=threads(h)
    return {'ok':True,'data':{'count':len(it),'threads':it[:20]}}
def search(kw):
    h=fetch(f'{BASE}/search.php?mod=forum&srchtxt={urllib.parse.quote(kw)}&searchsubmit=true')
    if 'arg1' in h and 'thread-' not in h: return {'ok':False,'error':'WAF_CHALLENGE'}
    it=threads(h)
    if not it and ('action=login' in h or '登录' in h[:1500]):
        return {'ok':False,'error':'LOGIN_REQUIRED','hint':'论坛搜索需登录态;应用cookie加密,登录复用待P4'}
    return {'ok':True,'data':{'query':kw,'count':len(it),'results':it[:15]}}
def read(tid):
    h=fetch(f'{BASE}/forum.php?mod=viewthread&tid={tid}')
    if 'arg1' in h and 'comiis' not in h and 'postmessage' not in h: return {'ok':False,'error':'WAF_CHALLENGE'}
    tm=re.search(r'<title>(.*?)</title>',h,flags=re.S)
    title=clean(tm.group(1)) if tm else ''
    body=''
    pm=re.search(r'id="postmessage_\d+"[^>]*>(.*?)</(?:td|div)>',h,flags=re.S)
    if pm: body=clean(pm.group(1))
    else:
        i=h.find('comiis_messages')
        if i>=0:
            j=h.find('>',i); body=clean(h[j+1:j+6000])
    return {'ok':True,'data':{'tid':tid,'title':title,'content':body[:4000]}}
def main():
    if len(sys.argv)<2:
        print(json.dumps({'ok':False,'error':'usage: hot|search <kw>|read <tid>'},ensure_ascii=False)); return
    c=sys.argv[1]
    if c=='hot': r=hot()
    elif c=='search': r=search(sys.argv[2] if len(sys.argv)>2 else '')
    elif c=='read': r=read(sys.argv[2] if len(sys.argv)>2 else '')
    else: r={'ok':False,'error':'unknown cmd'}
    print(json.dumps(r,ensure_ascii=False))
if __name__=='__main__': main()
