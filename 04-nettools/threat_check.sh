#!/system/bin/sh
# threat_check.sh — 威胁情报哈希信誉入口（小柠檬内核 v1.0）
PY=/data/data/com.termux/files/usr/bin/python3
[ -x "$PY" ] || { echo '[threat] python3 unavailable'; exit 4; }
exec "$PY" /data/lemonbrain/nettools/threat_check.py "$@"
