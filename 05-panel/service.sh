#!/system/bin/sh
# 小柠檬面板后端开机自启(幂等,不碰现有开机链)
PY=${LEMON_PY:-/data/data/com.termux/files/usr/bin/python3}
PANEL=/data/lemonbrain/work/panel/panel_server.py
LOG=/data/lemonbrain/work/panel/boot.log
(
  i=0
  while [ $i -lt 30 ]; do [ -x "$PY" ] && break; sleep 2; i=$((i+1)); done
  HEX=$(printf '%X' 8794)
  if ! awk -v h=":$HEX" '$2 ~ h"$" && $4=="0A"{f=1} END{exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    nohup "$PY" "$PANEL" >> "$LOG" 2>&1 &
    echo "$(date '+%F %T') panel autostart pid=$!" >> "$LOG"
  else
    echo "$(date '+%F %T') panel already up, skip" >> "$LOG"
  fi
) &
