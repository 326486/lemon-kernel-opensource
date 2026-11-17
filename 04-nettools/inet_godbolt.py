# Compiler Explorer 在线编译/看汇编
import argparse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean, trunc

p = argparse.ArgumentParser()
p.add_argument('--action', default='compilers'); p.add_argument('--lang', default='c++')
p.add_argument('--source'); p.add_argument('--compiler'); p.add_argument('--flags', default='-O2')
a = p.parse_args()
action = clean(a.action, 'compilers'); lang = clean(a.lang, 'c++')
try:
    if action == 'compilers':
        r = json.loads(http('https://godbolt.org/api/compilers', headers={'Accept': 'application/json'}, timeout=30))
        match = [{"id": c.get('id'), "name": trunc(c.get('name', ''), 60)} for c in r if c.get('lang') == lang][:15]
        out({"lang": lang, "count": len(match), "compilers": match})
    elif action == 'compile':
        source = clean(a.source)
        if not source: die('compile 需要 source 参数')
        cid = clean(a.compiler)
        if not cid:
            r = json.loads(http('https://godbolt.org/api/compilers', headers={'Accept': 'application/json'}, timeout=30))
            objs = [c for c in r if c.get('lang') == lang]
            if not objs: die('未找到语言 %s 的编译器' % lang)
            def _score(c):
                nm = c.get('name', '').lower(); s = 0
                if 'x86-64' in nm or 'x86_64' in nm: s += 2
                if 'gcc' in nm or 'g++' in nm or 'clang' in nm: s += 1
                return -s
            objs.sort(key=_score)
            cid = objs[0].get('id')
        body = json.dumps({"source": source, "options": {"userArguments": clean(a.flags, '-O2'),
              "filters": {"binary": False, "execute": False, "intel": True, "demangle": True, "trim": True}}})
        r = json.loads(http('https://godbolt.org/api/compiler/' + cid + '/compile', data=body,
              headers={'Content-Type': 'application/json', 'Accept': 'application/json'}, timeout=60, method='POST'))
        asm = '\n'.join(x.get('text', '') for x in (r.get('asm') or []))
        out({"compiler": cid, "code": r.get('code'),
             "stderr": trunc('\n'.join(x.get('text', '') for x in (r.get('stderr') or [])), 400),
             "asm": trunc(asm, 2200)})
    else:
        die('action 可选: compilers/compile')
except Exception as e:
    die('godbolt 失败: %s' % e)