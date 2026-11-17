# webhook.site 临时收件箱：创建token / 查看收到的请求
import argparse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean, trunc

p = argparse.ArgumentParser()
p.add_argument('--action', default='create'); p.add_argument('--token'); p.add_argument('--limit', default='5')
a = p.parse_args()
action = clean(a.action, 'create')
try:
    if action == 'create':
        r = json.loads(http('https://webhook.site/token', data='{}', headers={'Content-Type': 'application/json'}, timeout=20, method='POST'))
        out({"uuid": r.get('uuid'), "inbox_url": 'https://webhook.site/' + str(r.get('uuid')),
             "note": "把此URL配到任意回调方，再用 action=list + token 查看收到的请求"})
    elif action == 'list':
        token = clean(a.token)
        if not token: die('list 需要 token 参数')
        r = json.loads(http('https://webhook.site/token/' + token + '/requests?per_page=' + str(int(clean(a.limit, '5'))), timeout=20))
        reqs = [{"method": x.get('method'), "ip": x.get('ip'), "time": x.get('created_at'),
                 "content": trunc(x.get('content', ''), 200)} for x in (r.get('data') or [])]
        out({"token": token, "count": len(reqs), "requests": reqs})
    else:
        die('action 可选: create/list')
except Exception as e:
    die('webhook.site 失败: %s' % e)