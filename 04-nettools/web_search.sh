#!/system/bin/sh
# web_search.sh — 联网搜索入口（小柠檬内核 v1.0）
PY=/data/data/com.termux/files/usr/bin/python3
[ -x "$PY" ] || { echo '[web_search] python3 unavailable'; exit 4; }
exec "$PY" /data/lemonbrain/nettools/web_search.py "$@"
