#!/data/data/com.termux/files/usr/bin/python3
# 小柠檬 safe门面 v1.5.0.1 · 261117
# 透明安全代理: 监听8793 -> 转发8792( live v154 不改 ), 叠加 风险注解/确认门/路径保护/审计/语义检索
# 协议: MCP 2025-06-18 (回退2025-03-26). 仅绑定127.0.0.1.
import json, os, re, time, hashlib, sqlite3, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request

STAGE='/data/lemonbrain/work/v160_stage'
UPSTREAM='http://127.0.0.1:8792/'
TOKEN='Bearer QO3DH2pUTXPKKoT0VgIXyfL3MvWe9eB8bUiFVJYTUpqiq84V'
PORT=8793
AUDIT=f'{STAGE}/audit.jsonl'
REG=json.load(open(f'{STAGE}/risk_registry.json',encoding='utf-8'))['tools']
GUARD=json.load(open(f'{STAGE}/guard_paths.json',encoding='utf-8'))
PROT=GUARD['protected_prefixes']
TID2NAME={c['tid']:n for n,c in REG.items()}
LOCK=threading.Lock()

RES_CACHE={}
FACADE_RO={'tool_find','tool_get','tool_search','file_cat','file_read','task_status','task_result','forum_hot','forum_read','forum_search'}
FACADE_DEST={'file_write_text','tool_call','task_submit'}
def resolve(tid_or_name):
    if not isinstance(tid_or_name,str): return str(tid_or_name)
    s=tid_or_name.strip()
    if s in TID2NAME: return TID2NAME[s]
    if s.startswith('T-'):
        if s in RES_CACHE: return RES_CACHE[s]
        try:
            r=upstream('tools/call',{'name':'tool_get','arguments':{'id':s}})
            nm=json.loads(r['result']['content'][0]['text']).get('name')
            if nm:
                nm=nm.replace('[MT] ','').strip(); RES_CACHE[s]=nm; return nm
        except Exception: pass
        return s
    return s.replace('[MT] ','').strip()

DEST_SUB=['rm','delete','shred','truncate','kill','install','build','patch','edit','write','append','create','move','copy','rename','update','extract','transfer','clear','reset','remove','add','grant','reboot','shutdown','stop','start','push','upload','download','cancel','set','signal','pause','resume','mount','umount','remount','format','wipe','purge','exec','run','script','shell','sleep','wait','nice','affinity','oom','fork','proxy','svc','battery','power','net_if','mac','chmod','chown','touch','link','mkdir','rmdir','disable','enable','inject','hook','spawn','attach','detach','compile','flash','mkfs','fdisk']
READ_SUB=['list','read','get','stat','search','info','outline','xref','check','test','probe','ls','cat','dump','find','glob','tree','count','size','status','version','help','meta','env','whoami','date','uuid','rand','echo','ping','lookup','connection','port','ifconfig','ip_','arp','route','cpuinfo','meminfo','loadavg','vmstat','slabinfo','interrupt','binder','users','thermal','charging','disk_free','disk_usage','block_list','sm_volumes','lsblk','proc_','mem_read','analyze','disassemble','inspect','pseudocode','classes','strings','stats','schema','tables','query']
def heuristic(name):
    n=name.lower()
    if any(x in n for x in DEST_SUB): return {'readOnlyHint':False,'destructiveHint':True,'idempotentHint':False,'openWorldHint':False,'risk':'medium'}
    if any(x in n for x in READ_SUB): return {'readOnlyHint':True,'destructiveHint':False,'idempotentHint':True,'openWorldHint':False,'risk':'low'}
    return {'readOnlyHint':False,'destructiveHint':True,'idempotentHint':False,'openWorldHint':False,'risk':'medium','unknown':True}
def risk_of(name):
    if name in FACADE_RO: return {'readOnlyHint':True,'destructiveHint':False,'idempotentHint':True,'openWorldHint':False,'risk':'low'}
    if name in FACADE_DEST: return {'readOnlyHint':False,'destructiveHint':True,'idempotentHint':False,'openWorldHint':False,'risk':'medium'}
    return REG.get(name) or heuristic(name)

def path_violations(args):
    hits=[]
    def walk(v):
        if isinstance(v,str):
            if v.startswith('/'):
                for p in PROT:
                    if v==p.rstrip('/') or v.startswith(p if p.endswith('/') else p+'/') or v==p:
                        hits.append(v)
        elif isinstance(v,dict):
            for x in v.values(): walk(x)
        elif isinstance(v,list):
            for x in v: walk(x)
    walk(args)
    return hits

def audit(entry):
    entry['ts']=time.strftime('%F %T')
    with LOCK:
        with open(AUDIT,'a',encoding='utf-8') as f:
            f.write(json.dumps(entry,ensure_ascii=False)+'\n')

def search(q,kind=None,k=8):
    con=sqlite3.connect(f'{STAGE}/search.db')
    q=q.strip(); rows=[]
    if len(q)>=3:
        try:
            rows=con.execute("SELECT i.kind,i.key,i.title FROM items_fts f JOIN items i ON i.id=f.rowid WHERE items_fts MATCH ? ORDER BY f.rank LIMIT ?",(q,k)).fetchall()
        except Exception: rows=[]
    if not rows:
        like=f'%{q}%'
        rows=con.execute("SELECT kind,key,title FROM items WHERE title LIKE ? OR body LIKE ? LIMIT ?",(like,like,k)).fetchall()
    con.close()
    if kind: rows=[r for r in rows if r[0]==kind]
    return [{'kind':r[0],'key':r[1],'title':r[2]} for r in rows]

def upstream(method,params):
    body=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or {}}).encode()
    rq=urllib.request.Request(UPSTREAM,data=body,headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream','Authorization':TOKEN})
    raw=urllib.request.urlopen(rq,timeout=300).read().decode('utf-8','replace')
    if raw.lstrip().startswith(('event:','data:')):
        for line in raw.splitlines():
            if line.startswith('data:'): raw=line[5:]; break
    return json.loads(raw)

CORE='http://127.0.0.1:8788/'
def core_upstream(method,params):
    body=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params or {}}).encode()
    rq=urllib.request.Request(CORE,data=body,headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
    raw=urllib.request.urlopen(rq,timeout=120).read().decode('utf-8','replace')
    if raw.lstrip().startswith(('event:','data:')):
        for line in raw.splitlines():
            if line.startswith('data:'): raw=line[5:]; break
    return json.loads(raw)
FORUM_TOOLS=[
 {'name':'forum_hot','description':'[MT论坛] 导读最新帖子列表(bbs.binmt.cc,自动过WAF)','inputSchema':{'type':'object','properties':{}}},
 {'name':'forum_read','description':'[MT论坛] 读取帖子标题与正文','inputSchema':{'type':'object','properties':{'tid':{'type':'string','description':'帖子ID'}},'required':['tid']}},
 {'name':'forum_search','description':'[MT论坛] 搜索论坛帖子(需登录态,当前LOGIN_REQUIRED)','inputSchema':{'type':'object','properties':{'keyword':{'type':'string','description':'搜索词'}},'required':['keyword']}}
]
SEARCH_TOOL={'name':'tool_search','description':'[语义检索] FTS5 trigram+LIKE 混合检索 工具/记忆中心/学习中心。说人话即可找工具或历史经验。','inputSchema':{'type':'object','properties':{'query':{'type':'string','description':'检索词(中英文均可)'},'kind':{'type':'string','enum':['tool','memory','learn'],'description':'可选过滤'},'limit':{'type':'integer','description':'返回条数,默认8'}},'required':['query']}}

def gate(name,args):
    # returns (decision, target, eff_args, risk, violations)
    if name=='tool_call':
        target=resolve(args.get('id')); eff=args.get('arguments') or {}
    elif name=='task_submit':
        target=resolve(args.get('tool')); eff=args.get('arguments') or {}
    else:
        target=resolve(name); eff=args
    r=risk_of(target)
    viol=path_violations(eff) if r['destructiveHint'] else []
    if name=='file_write_text':
        viol=path_violations({'path':args.get('path')})
    confirm=str(args.get('confirm',''))=='1' or str(eff.get('confirm',''))=='1'
    unlock=str(args.get('unlock_token',''))==GUARD.get('unlock_token','__none__') and GUARD.get('unlock_token')
    if r['destructiveHint'] and not confirm:
        return 'CONFIRM_REQUIRED',target,eff,r,viol
    if viol and not unlock:
        return 'PATH_PROTECTED',target,eff,r,viol
    return 'ALLOW',target,eff,r,viol

class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _send(self,obj,code=200):
        b=json.dumps(obj,ensure_ascii=False).encode()
        self.send_response(code); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        try:
            n=int(self.headers.get('Content-Length',0)); req=json.loads(self.rfile.read(n) or b'{}')
        except Exception:
            return self._send({'jsonrpc':'2.0','id':None,'error':{'code':-32700,'message':'parse error'}},400)
        mid=req.get('id'); method=req.get('method'); params=req.get('params') or {}
        if method=='initialize':
            try: upstream('initialize',params)
            except Exception: pass
            pv=params.get('protocolVersion','2025-03-26')
            neg='2025-06-18' if pv>='2025-06-18' else '2025-03-26'
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':neg,'capabilities':{'tools':{}},'serverInfo':{'name':'小柠檬内核·safe门面','version':'1.5.0.1'}}})
        if method=='tools/list':
            try: up=upstream('tools/list',{})
            except Exception as e: return self._send({'jsonrpc':'2.0','id':mid,'error':{'code':-32000,'message':f'upstream: {e}'}})
            tools=up.get('result',{}).get('tools',[])
            for t in tools:
                nm=resolve(t.get('name','')); r=risk_of(nm)
                t['annotations']={'readOnlyHint':r['readOnlyHint'],'destructiveHint':r['destructiveHint'],'idempotentHint':r['idempotentHint'],'openWorldHint':r['openWorldHint']}
            tools.append(SEARCH_TOOL)
            tools.extend(FORUM_TOOLS)
            return self._send({'jsonrpc':'2.0','id':mid,'result':{'tools':tools}})
        if method=='tools/call':
            name=params.get('name'); args=params.get('arguments') or {}
            if name=='tool_search':
                res=search(args.get('query',''),args.get('kind'),int(args.get('limit',8)))
                txt=json.dumps({'ok':True,'data':{'results':res,'count':len(res)}},ensure_ascii=False)
                return self._send({'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':txt}],'structuredContent':{'ok':True,'results':res}}})
            if name in ('forum_hot','forum_read','forum_search'):
                try: up=core_upstream('tools/call',{'name':name,'arguments':args})
                except Exception as e: return self._send({'jsonrpc':'2.0','id':mid,'error':{'code':-32000,'message':f'core: {e}'}})
                return self._send({'jsonrpc':'2.0','id':mid,'result':up.get('result',{})})
            decision,target,eff,r,viol=gate(name,args)
            ah=hashlib.sha256(json.dumps(args,ensure_ascii=False,sort_keys=True).encode()).hexdigest()[:16]
            audit({'client':self.client_address[0],'entry':name,'target':target,'args_hash':ah,'risk':r['risk'],'decision':decision,'violations':viol})
            if decision!='ALLOW':
                txt=json.dumps({'ok':False,'error':{'code':decision,'message':'破坏性操作需 confirm=1 确认' if decision=='CONFIRM_REQUIRED' else '命中保护路径, 需解锁令牌','target':target,'risk':r['risk'],'violations':viol}},ensure_ascii=False)
                return self._send({'jsonrpc':'2.0','id':mid,'result':{'content':[{'type':'text','text':txt}],'isError':False}})
            try: up=upstream('tools/call',params)
            except Exception as e: return self._send({'jsonrpc':'2.0','id':mid,'error':{'code':-32000,'message':f'upstream: {e}'}})
            return self._send({'jsonrpc':'2.0','id':mid,'result':up.get('result',{})})
        try: up=upstream(method,params)
        except Exception as e: return self._send({'jsonrpc':'2.0','id':mid,'error':{'code':-32000,'message':f'upstream: {e}'}})
        return self._send({'jsonrpc':'2.0','id':mid,'result':up.get('result',{})})

if __name__=='__main__':
    try: upstream('initialize',{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'safe-warm','version':'1.0'}})
    except Exception: pass
    srv=ThreadingHTTPServer(('127.0.0.1',PORT),H)
    print(f'safe门面 v1.5.0.1 listening 127.0.0.1:{PORT} -> {UPSTREAM}',flush=True)
    srv.serve_forever()
