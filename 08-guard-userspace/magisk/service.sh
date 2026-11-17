#!/system/bin/sh
# Magisk late_start 自启用户态防护(需Termux python)
PY=/data/data/com.termux/files/usr/bin/python3
PF=/data/lemonbrain/logs/guard_us.pid
( sleep 30
  if [ -f "$PF" ] && kill -0 "$(cat $PF)" 2>/dev/null; then exit 0; fi
  nohup $PY /data/lemonbrain/maintenance/guard_userspace.py >> /data/lemonbrain/logs/guard_us.log 2>&1 &
  echo $! > "$PF"
) &
