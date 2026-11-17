# Semantic Scholar 学术检索（含429退避重试）
import argparse, urllib.parse, sys, os, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean, trunc

p = argparse.ArgumentParser()
p.add_argument('--q'); p.add_argument('--limit', default='5')
a = p.parse_args()
q = clean(a.q)
if not q: die('缺少 q 参数')
url = ('https://api.semanticscholar.org/graph/v1/paper/search?query=' + urllib.parse.quote(q)
       + '&limit=' + str(int(clean(a.limit, '5')))
       + '&fields=title,year,authors,citationCount,externalIds')
data = None
for i in range(3):
    try:
        data = json.loads(http(url, timeout=30)); break
    except urllib.error.HTTPError as e:
        if e.code == 429 and i < 2: time.sleep(3 * (i + 1)); continue
        die('Semantic Scholar 限流或出错: HTTP %s（免费公共池拥挤，稍后再试）' % e.code)
    except Exception as e:
        die('查询失败: %s' % e)
papers = [{"title": trunc(x.get('title', ''), 120), "year": x.get('year'),
           "authors": [au.get('name', '') for au in (x.get('authors') or [])][:3],
           "citations": x.get('citationCount'),
           "doi": (x.get('externalIds') or {}).get('DOI')} for x in (data.get('data') or [])]
out({"query": q, "total": data.get('total'), "papers": papers})