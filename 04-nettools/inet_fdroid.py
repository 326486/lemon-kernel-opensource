# IzzyOnDroid 开源APK仓库检索（index-v1.json新格式，兼容旧index.xml）
import argparse, sys, os, io, zipfile, time, json, xml.etree.ElementTree as ET
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http_raw, out, die, clean, trunc

CACHE = '/data/lemonbrain/nettools/izzy_index.json'
URL = 'https://apt.izzysoft.de/fdroid/repo/index-v1.jar'
TTL = 7 * 86400

p = argparse.ArgumentParser()
p.add_argument('--q'); p.add_argument('--limit', default='10'); p.add_argument('--refresh', default='0')
a = p.parse_args()
q = clean(a.q)
if not q: die('缺少 q 参数')
limit = int(clean(a.limit, '10'))
try:
    if clean(a.refresh, '0') == '1' or not os.path.exists(CACHE) or time.time() - os.path.getmtime(CACHE) > TTL:
        raw = http_raw(URL, timeout=150)
        with zipfile.ZipFile(io.BytesIO(raw)) as z:
            names = z.namelist()
            if 'index-v1.json' in names:
                data = z.read('index-v1.json')
            elif 'index.xml' in names:
                data = z.read('index.xml')
            else:
                die('索引包内无可用索引文件: %s' % names)
        with open(CACHE, 'wb') as f: f.write(data)
    blob = open(CACHE, 'rb').read()
    apps = []
    if blob.lstrip()[:1] in (b'{', b'['):
        d = json.loads(blob)
        raw_apps = d.get('apps', [])
        if isinstance(raw_apps, dict): raw_apps = list(raw_apps.values())
        for ap in raw_apps:
            loc = ap.get('localized', {}) or {}
            en = loc.get('en-US') or loc.get('en') or (next(iter(loc.values())) if loc else {})
            apps.append({"package": ap.get('packageName', ''), "name": en.get('name', '') or ap.get('name', ''),
                         "summary": en.get('summary', '') or ap.get('summary', '') or ''})
    else:
        root = ET.fromstring(blob)
        for ap in root.findall('application'):
            apps.append({"package": ap.get('id', ''), "name": ap.findtext('name', ''),
                         "summary": ap.findtext('summary', '') or ''})
except Exception as e:
    die('索引下载/解析失败: %s' % e)
ql = q.lower(); hits = []
for ap in apps:
    if ql in ap['name'].lower() or ql in ap['summary'].lower() or ql in ap['package'].lower():
        hits.append({"package": ap['package'], "name": ap['name'], "summary": trunc(ap['summary'], 130)})
        if len(hits) >= limit: break
out({"query": q, "repo": "IzzyOnDroid", "total_apps": len(apps), "shown": len(hits), "apps": hits,
     "note": "APK: https://apt.izzysoft.de/fdroid/repo/<package>_<version>.apk"})