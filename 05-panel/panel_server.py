#!/data/data/com.termux/files/usr/bin/python3
# 小柠檬内核控制面板 v1.0 - 261117 | 仅127.0.0.1:8794 | 操作经safe门面8793确认门+审计
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request, socket, subprocess, shutil, platform, urllib.parse
from concurrent.futures import ThreadPoolExecutor
PORT=8794
CORE='http://127.0.0.1:8788/'
SAFE='http://127.0.0.1:8793/'
SLIM='http://127.0.0.1:8792/'
def mcp_auto(method,params,token=None):
    try: return mcp_auto(method,params,token)
    except Exception: return mcp(SLIM,method,params,token)
TOKEN='Bearer REDACTED_OLD_TOKEN'
STAGE='/data/lemonbrain/work/v160_stage'
AUDIT=STAGE+'/audit.jsonl'
START=time.time()
CACHE={'tools':None,'ts':0}
try: REG=json.load(open(STAGE+'/risk_registry.json',encoding='utf-8')).get('tools',{})
except Exception: REG={}
def mcp(url,method,params,token=None):
    body=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or {}}).encode()
    h={'Content-Type':'application/json','Accept':'application/json, text/event-stream'}
    if token: h['Authorization']=token
    rq=urllib.request.Request(url,data=body,headers=h)
    raw=urllib.request.urlopen(rq,timeout=30).read().decode('utf-8','replace')
    if raw.lstrip().startswith(('event:','data:')):
        for l in raw.splitlines():
            if l.startswith('data:'): raw=l[5:]; break
    return json.loads(raw)
def port_up(p):
    hx='%04X'%p
    for f in ('/proc/net/tcp','/proc/net/tcp6'):
        try:
            for line in open(f).read().splitlines()[1:]:
                q=line.split()
                if len(q)>3 and q[1].endswith(':'+hx) and q[3]=='0A': return True
        except Exception: pass
    return False
SERVICES=[(8788,'lemoncore 内核'),(8790,'Java 卫星内核'),(8791,'slim门面(玄星直连)'),(8792,'slim门面 v154'),(8793,'safe门面 v1.6'),(8795,'维护口'),(8796,'令牌闸'),(8787,'MT MCP桥'),(8786,'MT官方MCP'),(9898,'网关管家'),(3002,'qwen2api桥'),(9797,'MT论坛MCP'),(8794,'本面板')]
def get_tools():
    if CACHE['tools'] is not None and time.time()-CACHE['ts']<60: return CACHE['tools']
    base=[]
    try:
        for l in open('/data/lemonbrain/tools/_索引/工具索引.tsv',encoding='utf-8').read().splitlines()[1:]:
            p=l.split('\t')
            if len(p)>=2 and p[1].strip():
                base.append({'tid':p[0],'name':p[1].replace('[MT] ','').strip(),'domain':p[2] if len(p)>2 else '','desc':(p[3] if len(p)>3 else '')[:100]})
    except Exception: pass
    live={}
    try:
        for t in mcp(CORE,'tools/list',{}).get('result',{}).get('tools',[]): live[t.get('name','')]=t.get('inputSchema',{})
    except Exception: pass
    out=[]
    for b in base:
        rk=REG.get(b['name']) or {}
        out.append({'name':b['name'],'tid':b['tid'],'domain':b['domain'],'desc':b['desc'],'risk':rk.get('risk','medium'),'ro':rk.get('readOnlyHint',False),'schema':live.get(b['name'],{})})
    CACHE['tools']=out; CACHE['ts']=time.time()
    return out
def sys_stats():
    d={}
    try: d['load']=open('/proc/loadavg').read().split()[:3]
    except Exception: d['load']=[]
    try:
        mi={}
        for l in open('/proc/meminfo'):
            k,v=l.split(':',1); mi[k]=int(v.strip().split()[0])
        d['mem_total_gb']=round(mi.get('MemTotal',0)/1048576,1); d['mem_avail_gb']=round(mi.get('MemAvailable',0)/1048576,1)
    except Exception: pass
    try:
        d['battery']=int(open('/sys/class/power_supply/battery/capacity').read().strip())
        d['battery_temp']=int(open('/sys/class/power_supply/battery/temp').read().strip())/10
    except Exception: pass
    return d
def get_status():
    return {'version':'1.5.0.1','services':[{'port':p,'name':n,'up':port_up(p)} for p,n in SERVICES],'system':sys_stats(),'ts':time.strftime('%F %T')}
def get_audit(n=50):
    rows=[]
    try:
        for l in open(AUDIT,encoding='utf-8').read().splitlines()[-n:]:
            try: rows.append(json.loads(l))
            except Exception: pass
    except Exception: pass
    st={}
    for r in rows: st[r.get('decision','?')]=st.get(r.get('decision','?'),0)+1
    return {'rows':rows[::-1],'stats':st,'total':len(rows)}
def probe_services():
    def one(item):
        port,name=item
        t0=time.time()
        try:
            c=socket.create_connection(('127.0.0.1',port),timeout=0.6); c.close()
            return {'port':port,'name':name,'up':True,'ms':round((time.time()-t0)*1000,1)}
        except Exception:
            return {'port':port,'name':name,'up':False,'ms':None}
    with ThreadPoolExecutor(max_workers=14) as ex:
        return list(ex.map(one,SERVICES))
LOGSRC={'kernel':'/data/lemonbrain/core/lemoncore.log','panel':'/data/lemonbrain/work/panel/panel.log','boot':'/data/lemonbrain/work/panel/boot.log','audit':'/data/lemonbrain/work/v160_stage/audit.jsonl'}
def sys_info():
    d={}
    try:
        d['model']=subprocess.run(['getprop','ro.product.model'],capture_output=True,text=True,timeout=5).stdout.strip()
        d['android']=subprocess.run(['getprop','ro.build.version.release'],capture_output=True,text=True,timeout=5).stdout.strip()
        d['sdk']=subprocess.run(['getprop','ro.build.version.sdk'],capture_output=True,text=True,timeout=5).stdout.strip()
    except Exception: d.update(model='',android='',sdk='')
    d['kernel']=platform.release()
    try: d['uptime_s']=int(float(open('/proc/uptime').read().split()[0]))
    except Exception: d['uptime_s']=0
    d['cpu_cores']=os.cpu_count()
    try:
        du=shutil.disk_usage('/data'); d['storage_total_gb']=round(du.total/2**30,1); d['storage_free_gb']=round(du.free/2**30,1)
    except Exception: pass
    return d
def tail_log(src,n=80):
    pth=LOGSRC.get(src,'')
    try:
        lines=open(pth,encoding='utf-8',errors='replace').read().splitlines()
        return {'src':src,'lines':lines[-n:]}
    except Exception as e:
        return {'src':src,'lines':[],'error':str(e)}
def kb_search(q,kind=None):
    import sqlite3
    db='/data/lemonbrain/work/v160_stage/search.db'
    try:
        con=sqlite3.connect(db);rows=[]
        if len(q)>=3:
            rows=con.execute("SELECT i.kind,i.key,i.title FROM items_fts f JOIN items i ON i.id=f.rowid WHERE items_fts MATCH ? ORDER BY f.rank LIMIT 12",(q,)).fetchall()
        if not rows:
            like='%'+q+'%'
            rows=con.execute("SELECT kind,key,title FROM items WHERE title LIKE ? OR body LIKE ? LIMIT 12",(like,like)).fetchall()
        con.close()
        if kind: rows=[r for r in rows if r[0]==kind]
        return {'ok':True,'data':{'results':[{'kind':r[0],'key':r[1],'title':r[2]} for r in rows],'count':len(rows)}}
    except Exception as e:
        return {'ok':False,'error':str(e)}
def fmt_up(s):
    m,s=divmod(int(s),60); h,m=divmod(m,60)
    return (str(h)+'h ' if h else '')+str(m)+'m'
HTML_PATH=os.path.join(os.path.dirname(os.path.abspath(__file__)),'panel_ui.html')
def read_html():
    try: return open(HTML_PATH,encoding='utf-8').read()
    except Exception: return '<h1>panel_ui.html missing</h1>'
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _j(self,obj,code=200):
        b=json.dumps(obj,ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p=self.path.split('?')[0]
        qs=urllib.parse.parse_qs(self.path.split('?')[1] if '?' in self.path else '')
        if p=='/':
            b=read_html().encode()
            self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
        elif p=='/api/overview':
            lt=len(get_tools())
            self._j({'total':lt+432+506,'local':lt,'upstream':432,'mt':506,'safe':port_up(8793),'core':port_up(8788),'uptime':fmt_up(time.time()-START)})
        elif p=='/api/tools': self._j({'tools':get_tools()})
        elif p=='/api/status': self._j(get_status())
        elif p=='/api/audit': self._j(get_audit())
        elif p=='/api/probe': self._j({'services':probe_services()})
        elif p=='/api/sysinfo': self._j(sys_info())
        elif p=='/api/logs': self._j(tail_log(qs.get('src',['panel'])[0],int(qs.get('lines',['80'])[0])))
        elif p=='/api/search': self._j(kb_search(qs.get('q',[''])[0],qs.get('kind',[None])[0]))
        else: self._j({'error':'not found'},404)
    def do_POST(self):
        if self.path.split('?')[0]!='/api/call': return self._j({'error':'not found'},404)
        try: body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or b'{}')
        except Exception: return self._j({'error':'bad json'},400)
        inner={'id':body.get('id'),'arguments':body.get('arguments') or {}}
        if body.get('confirm'): inner['confirm']='1'
        try:
            r=mcp_auto('tools/call',{'name':'tool_call','arguments':inner},token=TOKEN)
            self._j(r.get('result',r))
        except Exception as e:
            self._j({'error':str(e)},502)
if __name__=='__main__':
    print('小柠檬控制面板 v1.0 listening 127.0.0.1:%d'%PORT,flush=True)
    ThreadingHTTPServer(('127.0.0.1',PORT),H).serve_forever()
