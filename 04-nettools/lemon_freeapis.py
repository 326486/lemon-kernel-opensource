import sys,json,urllib.request,urllib.parse
T=8
def g(L,i,d):
    return L[i] if i<len(L) and L[i] else d
def get(u):
    r=urllib.request.urlopen(urllib.request.Request(u,headers={'User-Agent':'lemon-kernel/1.5'}),timeout=T)
    return json.loads(r.read().decode('utf-8','replace'))
def fx_frankfurter(L): return get('https://api.frankfurter.app/latest?amount=%s&from=%s&to=%s'%(g(L,2,'1'),g(L,0,'USD'),g(L,1,'CNY')))
def fx_erapi(L): return get('https://open.er-api.com/v6/latest/'+g(L,0,'USD'))
def crypto_coingecko(L): return get('https://api.coingecko.com/api/v3/simple/price?ids=%s&vs_currencies=%s'%(g(L,0,'bitcoin'),g(L,1,'usd')))
def crypto_binance(L): return get('https://api.binance.com/api/v3/ticker/price?symbol='+g(L,0,'BTCUSDT'))
def wiki_summary(L): return get('https://en.wikipedia.org/api/rest_v1/page/summary/'+urllib.parse.quote(g(L,0,'Python')))
def dict_define(L): return get('https://api.dictionaryapi.dev/api/v2/entries/en/'+urllib.parse.quote(g(L,0,'hello')))
def qr_generate(L):
    return {'ok':True,'url':'https://api.qrserver.com/v1/create-qr-code/?size=%s&data=%s'%(g(L,1,'128x128'),urllib.parse.quote(g(L,0,'hello')))}
def hn_top(L): return {'ok':True,'ids':get('https://hacker-news.firebaseio.com/v0/topstories.json')[:int(g(L,0,'5'))]}
def github_repo(L): return get('https://api.github.com/repos/'+g(L,0,'torvalds/linux'))
def weather_openmeteo(L): return get('https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current=temperature_2m,wind_speed_10m,weather_code'%(g(L,0,'30'),g(L,1,'120')))
def ip_geo(L): return get('http://ip-api.com/json/'+g(L,0,''))
CMDS={'fx_frankfurter':fx_frankfurter,'fx_erapi':fx_erapi,'crypto_coingecko':crypto_coingecko,'crypto_binance':crypto_binance,'wiki_summary':wiki_summary,'dict_define':dict_define,'qr_generate':qr_generate,'hn_top':hn_top,'github_repo':github_repo,'weather_openmeteo':weather_openmeteo,'ip_geo':ip_geo}
def main():
    if len(sys.argv)<2: print(json.dumps({'ok':False,'error':'usage <cmd> [p1 p2 p3]'}));return
    c=sys.argv[1]; L=sys.argv[2:]
    if c=='selftest':
        print(json.dumps({n:(lambda f: (f([]) and True) if False else _t(f))(f) for n,f in CMDS.items()}));return
    try:
        d=CMDS[c](L)
        print(json.dumps(d if isinstance(d,dict) and 'ok' in d else {'ok':True,'data':d},ensure_ascii=False))
    except Exception as e:
        print(json.dumps({'ok':False,'error':str(e)[:120]},ensure_ascii=False))
def _t(f):
    try: f([]);return True
    except Exception: return False
if __name__=='__main__': main()
