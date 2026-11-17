# ip-api IP/域名归属地查询（免key，45次/分钟）
import argparse, urllib.parse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean

p = argparse.ArgumentParser()
p.add_argument('--target')
a = p.parse_args()
target = clean(a.target)
if not target: die('缺少 target 参数(IP或域名)')
url = 'http://ip-api.com/json/' + urllib.parse.quote(target) + '?lang=zh-CN&fields=status,message,country,regionName,city,isp,org,as,query'
try:
    r = json.loads(http(url, timeout=15))
except Exception as e:
    die('ip-api 查询失败: %s' % e)
if r.get('status') != 'success': die('查询失败: %s' % r.get('message', '未知'))
out(r)