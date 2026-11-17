#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot 开机自启用户态防护
termux-wake-lock
PF=/data/lemonbrain/logs/guard_us.pid
if [ -f "$PF" ] && kill -0 "$(cat $PF)" 2>/dev/null; then exit 0; fi
nohup /data/data/com.termux/files/usr/bin/python3 /data/lemonbrain/maintenance/guard_userspace.py >> /data/lemonbrain/logs/guard_us.log 2>&1 &
echo $! > "$PF"
