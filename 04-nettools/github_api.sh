#!/system/bin/sh
# github_api.sh — GitHub 直连入口（小柠檬内核 v1.0）
PY=/data/data/com.termux/files/usr/bin/python3
[ -x "$PY" ] || { echo '[github] python3 unavailable'; exit 4; }
exec "$PY" /data/lemonbrain/nettools/github_api.py "$@"
