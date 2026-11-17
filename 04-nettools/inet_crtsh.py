# crt.sh 证书透明度子域名发现
import argparse, urllib.parse, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean

p = argparse.ArgumentParser()
p.add_argument('--domain'); p.add_argument('--limit', default='50')
a = p.parse_args()
domain = clean(a.domain)
if not domain: die('缺少 domain 参数')
limit = int(clean(a.limit, '50'))
url = 'https://crt.sh/?q=' + urllib.parse.quote('%.' + domain) + '&output=json'
try:
    import json
    data = json.loads(http(url, timeout=60))
except Exception as e:
    die('crt.sh 查询失败(该站响应较慢): %s' % e)
names = set()
for row in data:
    for field in ('common_name', 'name_value'):
        for n in str(row.get(field, '')).split('\n'):
            n = n.strip().lstrip('*.').lower()
            if n and (n == domain or n.endswith('.' + domain)):
                names.add(n)
result = sorted(names)[:limit]
out({"domain": domain, "total_found": len(names), "shown": len(result), "subdomains": result})