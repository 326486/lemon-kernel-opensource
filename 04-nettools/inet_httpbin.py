# httpbin HTTP 请求回显测试
import argparse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean

p = argparse.ArgumentParser()
p.add_argument('--mode', default='get'); p.add_argument('--data')
a = p.parse_args()
mode = clean(a.mode, 'get')
if mode not in ('get', 'headers', 'ip', 'post', 'user-agent'): die('mode 可选: get/headers/ip/post/user-agent')
try:
    if mode == 'post':
        body = clean(a.data, '{"test":1}')
        r = http('https://httpbin.org/post', data=body, headers={'Content-Type': 'application/json'}, timeout=20, method='POST')
    else:
        r = http('https://httpbin.org/' + mode, timeout=20)
    out(json.loads(r))
except Exception as e:
    die('httpbin 请求失败: %s' % e)