# 官方MCP注册表检索（发现可接入的MCP服务）
import argparse, urllib.parse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean, trunc

p = argparse.ArgumentParser()
p.add_argument('--q'); p.add_argument('--limit', default='10')
a = p.parse_args()
q = clean(a.q, ''); limit = int(clean(a.limit, '10'))
url = 'https://registry.modelcontextprotocol.io/v0/servers?limit=100'
if q: url += '&search=' + urllib.parse.quote(q)
try:
    r = json.loads(http(url, timeout=30))
except Exception as e:
    die('MCP注册表查询失败: %s' % e)
servers = r.get('servers') or r.get('data') or []
items = []
for s in servers:
    meta = s.get('server') or s
    name = meta.get('name', '')
    desc = meta.get('description', '')
    if q and q.lower() not in (name + desc).lower(): continue
    items.append({"name": name, "desc": trunc(desc, 120)})
    if len(items) >= limit: break
out({"query": q or '(全部)', "shown": len(items), "servers": items})