#!/system/bin/sh
# web_fetch.sh — 网页正文抓取入口（小柠檬内核 v1.0）
PY=/data/data/com.termux/files/usr/bin/python3
[ -x "$PY" ] || { echo '[web_fetch] python3 unavailable'; exit 4; }
exec "$PY" /data/lemonbrain/nettools/web_fetch.py "$@"
