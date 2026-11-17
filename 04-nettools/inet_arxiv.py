# arXiv 论文检索
import argparse, urllib.parse, sys, os, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean, trunc

p = argparse.ArgumentParser()
p.add_argument('--q'); p.add_argument('--limit', default='5')
a = p.parse_args()
q = clean(a.q)
if not q: die('缺少 q 参数')
ns = {'a': 'http://www.w3.org/2005/Atom'}
url = 'https://export.arxiv.org/api/query?search_query=' + urllib.parse.quote('all:' + q) + '&max_results=' + str(int(clean(a.limit, '5')))
try:
    root = ET.fromstring(http(url, timeout=30))
except Exception as e:
    die('arXiv 查询失败: %s' % e)
items = []
for e in root.findall('a:entry', ns):
    items.append({
        "title": trunc(e.findtext('a:title', '', ns), 120),
        "authors": [x.findtext('a:name', '', ns) for x in e.findall('a:author', ns)][:3],
        "published": e.findtext('a:published', '', ns)[:10],
        "link": e.findtext('a:id', '', ns),
        "summary": trunc(e.findtext('a:summary', '', ns), 180)})
out({"query": q, "count": len(items), "papers": items})