# wttr.in 免key天气（当前+3天预报）
import argparse, urllib.parse, sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from netcommon import http, out, die, clean

p = argparse.ArgumentParser()
p.add_argument('--city', default='Changsha')
a = p.parse_args()
city = clean(a.city, 'Changsha')
try:
    r = json.loads(http('https://wttr.in/' + urllib.parse.quote(city) + '?format=j1&lang=zh', timeout=25))
except Exception as e:
    die('wttr 查询失败: %s' % e)
cur = (r.get('current_condition') or [{}])[0]
desc = cur.get('lang_zh') or cur.get('weatherDesc') or [{}]
days = [{"date": d.get('date'), "max": d.get('maxtempC'), "min": d.get('mintempC'),
         "desc": ((d.get('hourly') or [{}])[4].get('lang_zh') or (d.get('hourly') or [{}])[4].get('weatherDesc') or [{}])[0].get('value', '')}
        for d in (r.get('weather') or [])[:3]]
out({"city": city, "now": {"temp_C": cur.get('temp_C'), "feels_C": cur.get('FeelsLikeC'),
     "desc": desc[0].get('value', ''), "humidity": cur.get('humidity'),
     "wind_kmph": cur.get('windspeedKmph'), "wind_dir": cur.get('winddir16Point')}, "forecast": days})