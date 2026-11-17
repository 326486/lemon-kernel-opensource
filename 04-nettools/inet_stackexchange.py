# Stack Exchange 技术问答检索
import argparse, urllib.parse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean, trunc

p = argparse.ArgumentParser()
p.add_argument('--q'); p.add_argument('--site', default='stackoverflow'); p.add_argument('--limit', default='5')
a = p.parse_args()
q = clean(a.q)
if not q: die('缺少 q 参数')
url = ('https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q='
       + urllib.parse.quote(q) + '&site=' + clean(a.site, 'stackoverflow')
       + '&pagesize=' + str(int(clean(a.limit, '5'))))
try:
    r = json.loads(http(url, timeout=30))
except Exception as e:
    die('StackExchange 查询失败: %s' % e)
items = [{"title": trunc(x.get('title', ''), 120), "link": x.get('link'),
          "score": x.get('score'), "answers": x.get('answer_count'),
          "answered": x.get('is_answered')} for x in (r.get('items') or [])]
out({"query": q, "quota_remaining": r.get('quota_remaining'), "results": items})