import os,sys,json,time,shutil
PROTECT=['/data/adb/modules','/data/lemonbrain/core','/sdcard/小柠檬工作室']
BASE='/data/lemonbrain/guard_us_baseline.json'
ALERT='/data/lemonbrain/logs/guard_us_alert.log'
SNAP='/data/lemonbrain/snapshots'
def scan():
    h={}
    for d in PROTECT:
        for root,dirs,files in os.walk(d):
            dirs[:]=[x for x in dirs if x!='.git']
            for f in files:
                p=os.path.join(root,f)
                try:
                    st=os.stat(p); h[p]=[st.st_mtime_ns,st.st_size]
                except Exception: pass
    return h
def alert(m):
    os.makedirs(os.path.dirname(ALERT),exist_ok=True)
    open(ALERT,'a').write(time.strftime('%F %T')+' '+m+'\n')
def main():
    restore='--restore' in sys.argv
    if not os.path.exists(BASE):
        json.dump(scan(),open(BASE,'w')); alert('baseline created')
    base=json.load(open(BASE))
    while True:
        cur=scan()
        added=[p for p in cur if p not in base]
        removed=[p for p in base if p not in cur]
        changed=[p for p in cur if p in base and cur[p]!=base[p]]
        if added or removed or changed:
            alert('CHANGE added=%d removed=%d changed=%d'%(len(added),len(removed),len(changed)))
            for p in (added+removed+changed)[:20]: alert('  '+p)
            if restore:
                for p in changed+removed:
                    src=os.path.join(SNAP,os.path.relpath(p,'/'))
                    if os.path.isfile(src):
                        try: shutil.copy2(src,p); alert('restored '+p)
                        except Exception: alert('restore fail '+p)
            base=cur; json.dump(base,open(BASE,'w'))
        time.sleep(10)
if __name__=='__main__': main()
